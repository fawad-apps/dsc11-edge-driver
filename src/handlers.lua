-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0 (the "License"); you may not
-- use this file except in compliance with the License. You may obtain a copy
-- of the License at: http://www.apache.org/licenses/LICENSE-2.0

--[[
  Z-Wave and capability handlers for the DSC11.

  Two rules run through all of this, both forced by the dual endpoint mapping
  described in endpoints.lua:

    1. METER commands are addressed with explicit dst_channels and METER
       reports are routed by hand. They never go through the component map.
    2. Commands are staggered, never bursted. This is 2012 hardware behind a
       non-secure Z-Wave link. The legacy DTH serialised every per-endpoint
       Get (delayBetween(..., 1000), "delay 1500") and chained its refresh
       through the report handler rather than sending four Gets at once;
       upstream's multi-metering-switch carries the same scar ("trouble with
       energy reset commands if the value is read too quickly"). A refresh
       here is up to 15 commands.
]]

local capabilities = require "st.capabilities"
local log = require "log"
--- @type st.utils
local utils = require "st.utils"
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.CommandClass.Basic
local Basic = (require "st.zwave.CommandClass.Basic")({ version = 1 })
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version = 1 })
--- @type st.zwave.CommandClass.Meter
local Meter = (require "st.zwave.CommandClass.Meter")({ version = 3 })
--- @type st.zwave.CommandClass.SwitchBinary
local SwitchBinary = (require "st.zwave.CommandClass.SwitchBinary")({ version = 1 })
--- @type st.zwave.CommandClass.Version
local Version = (require "st.zwave.CommandClass.Version")({ version = 1 })

local endpoints = require "endpoints"
local configuration = require "configuration"
local preferences = require "preferences"

local handlers = {}

-- Seconds between staggered commands.
local COMMAND_INTERVAL = 1.0

-- The custom reset capability. It exists because the app will not draw
-- energyMeter's own reset button -- see driver_template.lua -- and it carries
-- a lastReset attribute so the card shows that something happened. A button
-- that wipes a lifetime register and gives no feedback is a bad button.
local RESET_ENERGY_CAPABILITY = "autumnpepper05038.energyreset"

-- Basic:Set values. The DTH drove this strip with Basic:Set and read it back
-- with SwitchBinary:Get, so that combination is known to work on the
-- hardware; SwitchBinary:Set is not known to.
local BASIC_ON = 0xFF
local BASIC_OFF = 0x00

-- Only kWh and WATTS are ever requested. The DTH used exactly these two
-- scales; kVAh is a scale this 2012 device may not support, and asking for it
-- is what the upstream Edge subdriver does instead of asking for watts --
-- which is why per-outlet power never populates there. A kVAh report is still
-- handled below if the device volunteers one.
local SCALE_KWH = Meter.scale.electric_meter.KILOWATT_HOURS
local SCALE_KVAH = Meter.scale.electric_meter.KILOVOLT_AMPERE_HOURS
local SCALE_WATTS = Meter.scale.electric_meter.WATTS

-- Meter:SupportedReport returns `scale_supported` as a one-byte BITMASK: bit N
-- set means scale N is supported. Names for logging it; the indices are the
-- Meter electric_meter scale enum.
local SCALE_NAMES = {
  [0] = "kWh",
  [1] = "kVAh",
  [2] = "W",
  [3] = "pulse count",
  [4] = "V",
  [5] = "A",
  [6] = "power factor",
  [7] = "MST",
}

-- What the device told us it supports, from the probes below. Not persisted:
-- these are cheap to re-ask on every configure, and a stale answer cached
-- across a firmware change would be worse than no answer.
local METER_SCALES_FIELD = "dsc11_meter_scales"
local METER_VERSION_FIELD = "dsc11_meter_version"

-- Persisted: has this device CONFIRMED its configuration -- not merely been
-- sent one.
--
-- A Configuration:Set is unacknowledged. Setting this when the last command
-- goes out would mark a strip configured that was asleep, out of range, or
-- dropping frames throughout, and device_init would then skip it on every
-- subsequent driver start. The device would be stuck reporting nothing
-- per-outlet, looking exactly like one that had been configured correctly,
-- and the only way back would be another manual drivers:switch.
--
-- So it is set from configuration_report, once every READ_BACK parameter has
-- come back matching, and cleared again the moment one comes back wrong.
local CONFIGURED_FIELD = "dsc11_configured"

-- NOT persisted: which READ_BACK parameters have confirmed since the current
-- configure started. Losing this to a driver restart just means configuring
-- again, which is the safe direction.
local CONFIRMATIONS_FIELD = "dsc11_confirmations"

-- NOT persisted: is a configure sequence in flight right now. Edge fires both
-- `init` and `driverSwitched` on a driver switch, which is precisely how this
-- device arrives, and CONFIGURED_FIELD is only set once the sequence finishes
-- -- so it cannot gate the second call. Without this guard the strip gets two
-- interleaved sequences, ~68 commands, and the Configuration:Gets of one race
-- the Configuration:Sets of the other, making the read-back log stale values.
local CONFIGURING_FIELD = "dsc11_configuring"

-- NOT persisted: is a refresh sequence in flight, and was another asked for
-- while it was.
--
-- A refresh on `main` is 15 commands over ~14 seconds, and there are now four
-- ways to start one: the app's refresh button, an automation, a per-outlet
-- refresh (the profile declares the capability on all five components), and
-- the ten-minute poll. Two overlapping sequences put two commands a second on
-- a non-securely-paired 2012 device, which is exactly what the one-second
-- stagger exists to prevent -- and lengthening COMMAND_INTERVAL would make
-- each sequence longer and the overlap MORE likely, not less.
--
-- Coalesced rather than dropped: somebody who pulls to refresh should get a
-- refresh, just not a second interleaved one. A queued request is always
-- satisfied by a full `main` refresh, since that covers every component.
local REFRESHING_FIELD = "dsc11_refreshing"
local REFRESH_PENDING_FIELD = "dsc11_refresh_pending"

-- Poll fallback. Per-outlet freshness otherwise rests entirely on the
-- unsolicited reports enabled by params 101/102 and 111/112; if one silently
-- fails to take, nothing backfills and the outlet just looks idle. READ_BACK
-- catches that at configure time, this catches it at run time. A full refresh
-- is 15 staggered commands (~14 s), so a 10-minute period is about a 2% duty
-- cycle on the Z-Wave link.
local POLL_INTERVAL = 10 * 60
local POLL_TIMER_FIELD = "dsc11_poll_timer"

-- powerConsumptionReport bookkeeping, per component. SmartThings Energy drops
-- a device that has not reported within 15 minutes, and rejects a window that
-- overlaps the previous one -- so each component needs its own last-report
-- time and the windows must be laid end to end.
--
-- THE GATE MUST BE SHORTER THAN THE POLL PERIOD, not equal to it and not the
-- platform's own 15 minutes. A report is only emitted on the first energy
-- reading that arrives after the gate has elapsed, so the real cadence is
-- poll_period * ceil(gate / poll_period):
--
--     gate 15 min, poll 10 min  ->  20 min  -- too slow, dropped by ST Energy
--     gate 10 min, poll 10 min  ->  10 min, but only if no timer ever fires
--                                   early; on a tick at 9m59s it becomes 20
--     gate  9 min, poll 10 min  ->  10 min, with a minute of slack
--
-- Nine minutes it is. Under normal operation the 90-second unsolicited
-- reports drive this instead and a report lands every 9 minutes exactly;
-- either way the platform is fed well inside its window.
local PCR_LAST_TIME_FIELD = "dsc11_pcr_last_time_"
local PCR_MINIMUM_INTERVAL = 9 * 60

-- The energy reading that opened the current window, per component.
--
-- Without it the first window is reported as zero consumption: the delta is
-- measured against the previous powerConsumptionReport, and on the first
-- window there isn't one. That silently discards the first nine minutes or
-- more of every component's consumption, on install and after every energy
-- reset -- exactly when someone is most likely to be watching.
local PCR_BASELINE_FIELD = "dsc11_pcr_baseline_" 

-- The DSC11's rating, and the ceiling used to tell a real measurement from a
-- register discontinuity. Nothing plugged into this strip can draw more, so
-- any window implying more than this is arithmetic, not electricity.
local MAX_STRIP_WATTS = 1875

-------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------

--- Outlet number for a component id, or nil if it is not one of this
--- device's four outlets. Range-checked so a stray component id cannot be
--- turned into an out-of-range endpoint.
--- @return number|nil
local function outlet_from_component(component_id)
  local outlet = tonumber((component_id or ""):match("^switch(%d+)$"))
  if outlet and outlet >= 1 and outlet <= endpoints.OUTLET_COUNT then
    return outlet
  end
  return nil
end

--- Always-on socket number for a component id, or nil. The app renders a
--- reset button on these components too -- SmartThings generates one for
--- every component declaring energyMeter -- so they must be understood here
--- or that button silently does nothing.
--- @return number|nil
local function always_on_from_component(component_id)
  local socket = tonumber((component_id or ""):match("^alwaysOn(%d+)$"))
  if socket and socket >= 1 and socket <= endpoints.ALWAYS_ON_COUNT then
    return socket
  end
  return nil
end

--- Emit an event to a component id, tolerating a component that is not in the
--- profile rather than erroring inside a handler.
local function emit_for_component(device, component_id, event)
  local component = device.profile.components[component_id]
  if component == nil then
    log.warn(string.format("no component '%s' in profile; dropping event", component_id))
    return
  end
  device:emit_component_event(component, event)
end

-- DEVICE-WIDE COMMAND QUEUE.
--
-- Every sequence in this driver goes through one queue, drained one command
-- per COMMAND_INTERVAL. Scheduling each sequence independently -- which is
-- what this used to do -- meant a switch, a reset, a preference change or a
-- configure arriving mid-refresh laid its commands on top of the ones already
-- scheduled, putting two a second on a non-securely-paired 2012 device. The
-- refresh guard stopped refresh colliding with refresh; nothing stopped the
-- other four.
--
-- WHY THE QUEUE HAS PRIORITIES. A plain FIFO fixes the collision and breaks
-- the product: a switch tapped during the ten-minute poll would sit behind up
-- to twenty queued commands, so the outlet would visibly turn on twenty
-- seconds later. User-initiated work therefore jumps ahead of background
-- work, while still taking its turn in the same one-per-second drain. It
-- never preempts a command already sent -- only the queue behind it.
local QUEUE_FIELD = "dsc11_queue"
local PUMPING_FIELD = "dsc11_pumping"

local PRIORITY_USER = "user"
local PRIORITY_BACKGROUND = "background"

--- Send one queued command, then arrange to send the next.
local function pump(device)
  local queue = device:get_field(QUEUE_FIELD) or {}
  local item = table.remove(queue, 1)
  device:set_field(QUEUE_FIELD, queue)

  if item == nil then
    device:set_field(PUMPING_FIELD, nil)
    return
  end

  item.fn()
  device.thread:call_with_delay(COMMAND_INTERVAL, function() pump(device) end)
end

--- Queue a list of zero-argument functions, drained one COMMAND_INTERVAL
--- apart. `priority` defaults to user-initiated; background callers (the
--- poll, configure) must say so, and then yield to anything the user does.
local function send_sequence(device, steps, priority)
  if steps == nil or #steps == 0 then
    return
  end
  priority = priority or PRIORITY_USER

  local queue = device:get_field(QUEUE_FIELD) or {}

  -- User work goes in front of the first background item, and behind any
  -- user work already waiting, so two taps still arrive in the order tapped.
  local insert_at = #queue + 1
  if priority == PRIORITY_USER then
    for i = 1, #queue do
      if queue[i].priority == PRIORITY_BACKGROUND then
        insert_at = i
        break
      end
    end
  end

  for offset, step in ipairs(steps) do
    table.insert(queue, insert_at + offset - 1, { fn = step, priority = priority })
  end
  device:set_field(QUEUE_FIELD, queue)

  if not device:get_field(PUMPING_FIELD) then
    device:set_field(PUMPING_FIELD, true)
    pump(device)
  end
end

--- Gets for one outlet: its switch state, its power, its energy.
--- Note the two different endpoints for the same outlet.
local function outlet_query_steps(device, outlet)
  local switch_ep = endpoints.switch_endpoint(outlet)
  local meter_ep = endpoints.meter_endpoint(outlet)
  return {
    function()
      device:send(SwitchBinary:Get({}, { dst_channels = { switch_ep } }))
    end,
    function()
      device:send(Meter:Get({ scale = SCALE_WATTS }, { dst_channels = { meter_ep } }))
    end,
    function()
      device:send(Meter:Get({ scale = SCALE_KWH }, { dst_channels = { meter_ep } }))
    end,
  }
end

--- Gets for one always-on socket: power and energy, no switch state. They
--- cannot be switched, which is what makes them always-on.
local function always_on_query_steps(device, socket)
  local meter_ep = endpoints.always_on_meter_endpoint(socket)
  return {
    function()
      device:send(Meter:Get({ scale = SCALE_WATTS }, { dst_channels = { meter_ep } }))
    end,
    function()
      device:send(Meter:Get({ scale = SCALE_KWH }, { dst_channels = { meter_ep } }))
    end,
  }
end

local function append(target, items)
  for _, item in ipairs(items) do
    target[#target + 1] = item
  end
end

--- ISO-8601 in UTC, the only format powerConsumptionReport accepts.
local function iso8601(time)
  return os.date("!%Y-%m-%dT%TZ", time)
end

--- Emit powerConsumptionReport for a component from a fresh kWh reading.
---
--- SmartThings Energy reads this rather than energyMeter: it wants a windowed
--- { start, end, energy, deltaEnergy } in WATT-hours, not a running kWh
--- total. Rate-limited per component to PCR_MINIMUM_INTERVAL, which is set
--- comfortably inside the platform's 15-minute expectation -- see the
--- constant for why it is not simply 15 minutes.
local function emit_power_consumption(device, component_id, kwh)
  local now = os.time()
  local field = PCR_LAST_TIME_FIELD .. component_id
  local baseline_field = PCR_BASELINE_FIELD .. component_id
  local last = device:get_field(field)
  local energy_wh = kwh * 1000

  -- First reading for this component. Start the window here and emit nothing
  -- -- there is no window to report yet -- but REMEMBER THE READING, because
  -- it is what the first window's consumption gets measured against.
  if last == nil then
    device:set_field(field, now, { persist = true })
    device:set_field(baseline_field, energy_wh, { persist = true })
    return
  end

  if now - last < PCR_MINIMUM_INTERVAL then
    return
  end

  -- Delta defaults to zero, not to the running total: on the first report
  -- after an install there is no earlier figure to subtract, and treating the
  -- whole lifetime total as one window's consumption would put a spike into
  -- SmartThings Energy that never happened.
  local delta_wh = 0.0
  local previous = device:get_latest_state(component_id,
    capabilities.powerConsumptionReport.ID,
    capabilities.powerConsumptionReport.powerConsumption.NAME)
  -- The previous report if there is one, otherwise the reading that opened
  -- this window. Falling back to the baseline is what stops the very first
  -- window being reported as zero consumption.
  local baseline = (previous and previous.energy) or device:get_field(baseline_field)
  if baseline then
    -- max(.., 0) because resetEnergyMeter sends the running total backwards,
    -- and a negative delta would read as generation rather than a reset.
    delta_wh = math.max(energy_wh - baseline, 0.0)

    -- ...and the register can jump UP discontinuously too, which the floor
    -- above does nothing about. Observed on hardware: a strip reported a
    -- near-zero lifetime figure and then, without warning, its true
    -- accumulated total -- a jump of several thousand kWh between two
    -- readings. The next window would have claimed all of it as nine minutes
    -- of consumption. A meter swap, a firmware reload or a register restored
    -- from NVRAM all do this.
    --
    -- The test is physics. The DSC11 is rated 1875 W, so a window of N
    -- seconds cannot legitimately carry more than 1875 * N / 3600 Wh. Real
    -- readings sit orders of magnitude below that -- a 160 W load over nine
    -- minutes is 24 Wh against a 281 Wh ceiling -- so this clamp never fires
    -- on a genuine measurement, only on a discontinuity.
    --
    -- The window is still reported, with a zero delta and the true running
    -- total: the consumption is genuinely unknown, and claiming none is the
    -- only honest answer. Dropping the report instead would leave a hole in
    -- an otherwise contiguous series.
    local ceiling_wh = MAX_STRIP_WATTS * (now - last) / 3600
    if delta_wh > ceiling_wh then
      log.warn(string.format(
        "%s energy jumped %.0f Wh in %d s, over the %.0f Wh this hardware "
        .. "could physically draw -- treating as a register discontinuity, "
        .. "not consumption", component_id, delta_wh, now - last, ceiling_wh))
      delta_wh = 0.0
    end
  end

  device:set_field(field, now, { persist = true })
  device:set_field(baseline_field, energy_wh, { persist = true })
  -- Windows are laid end to end: this one starts where the last ended, and
  -- stops a second short of now so the next cannot overlap it.
  emit_for_component(device, component_id,
    capabilities.powerConsumptionReport.powerConsumption({
      start = iso8601(last),
      ["end"] = iso8601(now - 1),
      energy = energy_wh,
      deltaEnergy = delta_wh,
    }))
end

-------------------------------------------------------------------------------
-- refresh
-------------------------------------------------------------------------------

--- True while a sequence that a refresh must not interleave with is running.
--- configure is included: it is 35 commands, and a refresh landing in the
--- middle of it is the worst case of all. configure's own closing refresh is
--- safe because it clears CONFIGURING_FIELD before calling this.
local function refresh_blocked(device)
  return device:get_field(REFRESHING_FIELD) or device:get_field(CONFIGURING_FIELD)
end

--- refresh. On `main` this queries the strip AND all four outlets -- both
--- power and energy. The profile declares refresh on all five components, so
--- the per-component branch is reachable from the app as well as from
--- automations; a per-outlet refresh is 3 commands rather than 15.
function handlers.refresh(driver, device, command)
  local component = (command and command.component) or "main"

  if refresh_blocked(device) then
    device:set_field(REFRESH_PENDING_FIELD, true)
    log.info("refresh already in flight; one more will follow it")
    return
  end

  -- A full refresh answers every outstanding request, so clear the queue
  -- before starting. Anything arriving from here on sets it again and is
  -- honoured by the closing step below.
  if component == "main" then
    device:set_field(REFRESH_PENDING_FIELD, nil)
  end

  local steps
  if component ~= "main" then
    local outlet = outlet_from_component(component)
    if not outlet then
      log.warn(string.format("refresh for unknown component '%s'", component))
      return
    end
    steps = outlet_query_steps(device, outlet)
  else
    steps = {
      function() device:send(SwitchBinary:Get({})) end,
      function() device:send(Meter:Get({ scale = SCALE_WATTS })) end,
      function() device:send(Meter:Get({ scale = SCALE_KWH })) end,
    }
    for outlet = 1, endpoints.OUTLET_COUNT do
      append(steps, outlet_query_steps(device, outlet))
    end
    -- The two always-on sockets. No switch state to ask for -- that is the
    -- whole point of them -- but they are metered, and a standing load on one
    -- of them is invisible to every other component.
    for socket = 1, endpoints.ALWAYS_ON_COUNT do
      append(steps, always_on_query_steps(device, socket))
    end
  end

  steps[#steps + 1] = function()
    device:set_field(REFRESHING_FIELD, nil)
    if device:get_field(REFRESH_PENDING_FIELD) then
      device:set_field(REFRESH_PENDING_FIELD, nil)
      -- Always a full refresh: whichever component asked, this covers it.
      handlers.refresh(driver, device, { component = "main" })
    end
  end

  -- Set before sending: send_sequence runs its first step immediately.
  device:set_field(REFRESHING_FIELD, true)
  send_sequence(device, steps,
    (command and command.background) and PRIORITY_BACKGROUND or PRIORITY_USER)
end

-------------------------------------------------------------------------------
-- switch
-------------------------------------------------------------------------------

local function set_switch(device, command, value)
  local component = command.component or "main"

  if component == "main" then
    -- The strip's master switch. Afterwards ask every outlet what it actually
    -- did, rather than assuming all four followed: a device-wide report says
    -- nothing about the individual outlets, and assuming otherwise is what
    -- makes all four components mirror main and look healthy when per-outlet
    -- reporting is in fact dead.
    local steps = {
      function() device:send(Basic:Set({ value = value })) end,
      function() device:send(SwitchBinary:Get({})) end,
    }
    for outlet = 1, endpoints.OUTLET_COUNT do
      local switch_ep = endpoints.switch_endpoint(outlet)
      steps[#steps + 1] = function()
        device:send(SwitchBinary:Get({}, { dst_channels = { switch_ep } }))
      end
    end
    send_sequence(device, steps)
    return
  end

  local outlet = outlet_from_component(component)
  if not outlet then
    log.warn(string.format("switch command for unknown component '%s'", component))
    return
  end

  local switch_ep = endpoints.switch_endpoint(outlet)
  local meter_ep = endpoints.meter_endpoint(outlet)
  send_sequence(device, {
    function() device:send(Basic:Set({ value = value }, { dst_channels = { switch_ep } })) end,
    function() device:send(SwitchBinary:Get({}, { dst_channels = { switch_ep } })) end,
    -- Power will have changed; ask the meter endpoint, not the switch one.
    function() device:send(Meter:Get({ scale = SCALE_WATTS }, { dst_channels = { meter_ep } })) end,
  })
end

function handlers.switch_on(driver, device, command)
  set_switch(device, command, BASIC_ON)
end

function handlers.switch_off(driver, device, command)
  set_switch(device, command, BASIC_OFF)
end

-------------------------------------------------------------------------------
-- energy reset
-------------------------------------------------------------------------------

--- Record that a component's meter was just reset, so the app can show it.
--- Best-effort: if the custom capability is unavailable the reset itself must
--- still go ahead, because clearing the register is the part that matters.
local function note_reset(device, component_id)
  local cap = capabilities[RESET_ENERGY_CAPABILITY]
  if cap == nil or cap.lastReset == nil then
    return
  end
  emit_for_component(device, component_id, cap.lastReset(os.date("!%Y-%m-%d %H:%M UTC")))
end

--- resetEnergyMeter. On a single outlet this resets that outlet's register
--- only. On `main` it resets the strip register and every outlet register,
--- because whether a root Meter:Reset clears the per-outlet registers on this
--- device is not known -- doing both is idempotent, and a reset that quietly
--- does less than asked is as bad as one that does more.
function handlers.reset_energy_meter(driver, device, command)
  local component = command.component or "main"

  if component == "main" then
    -- EVERY meter endpoint, all six sockets plus the root. Leaving the
    -- always-on pair out would make "reset all" quietly mean "reset most",
    -- and on the measured unit the always-on sockets held most of the
    -- strip's accumulated energy.
    local endpoints_to_clear = {}
    for socket = 1, endpoints.ALWAYS_ON_COUNT do
      endpoints_to_clear[#endpoints_to_clear + 1] = endpoints.always_on_meter_endpoint(socket)
    end
    for outlet = 1, endpoints.OUTLET_COUNT do
      endpoints_to_clear[#endpoints_to_clear + 1] = endpoints.meter_endpoint(outlet)
    end

    local steps = {
      function() device:send(Meter:Reset({})) end,
    }
    for _, meter_ep in ipairs(endpoints_to_clear) do
      steps[#steps + 1] = function()
        device:send(Meter:Reset({}, { dst_channels = { meter_ep } }))
      end
    end
    -- Re-read only after every reset has gone out.
    steps[#steps + 1] = function()
      note_reset(device, "main")
      for outlet = 1, endpoints.OUTLET_COUNT do
        note_reset(device, endpoints.component_for_outlet(outlet))
      end
      for socket = 1, endpoints.ALWAYS_ON_COUNT do
        note_reset(device, endpoints.component_for_always_on(socket))
      end
      device:send(Meter:Get({ scale = SCALE_KWH }))
    end
    for _, meter_ep in ipairs(endpoints_to_clear) do
      steps[#steps + 1] = function()
        device:send(Meter:Get({ scale = SCALE_KWH }, { dst_channels = { meter_ep } }))
      end
    end
    send_sequence(device, steps)
    return
  end

  -- A single component: an outlet, or one of the always-on sockets. The app
  -- renders a reset button on those too, because SmartThings generates one
  -- for every component declaring energyMeter -- so they have to work here.
  local meter_ep
  local outlet = outlet_from_component(component)
  if outlet then
    meter_ep = endpoints.meter_endpoint(outlet)
  else
    local socket = always_on_from_component(component)
    if not socket then
      log.warn(string.format("resetEnergyMeter for unknown component '%s'", component))
      return
    end
    meter_ep = endpoints.always_on_meter_endpoint(socket)
  end

  send_sequence(device, {
    function() device:send(Meter:Reset({}, { dst_channels = { meter_ep } })) end,
    function()
      note_reset(device, component)
      device:send(Meter:Get({ scale = SCALE_KWH }, { dst_channels = { meter_ep } }))
    end,
  })
end

-------------------------------------------------------------------------------
-- z-wave reports
-------------------------------------------------------------------------------

--- Recompute the strip's own switch state from the four outlets.
---
--- This is the SAFE direction, and the opposite of the one this driver
--- refuses to take. Fanning a strip-level report out to the four outlets
--- invents four states from one report that says nothing about them -- which
--- is what makes every outlet look healthy while per-outlet reporting is
--- dead. Deriving main from the outlets invents nothing: every value read
--- here arrived as that outlet's own report.
---
--- The strip counts as on when any outlet is on. A strip showing "off" while
--- something plugged into it is drawing power would be the worse error, and
--- it is the aggregate, not the master relay, that decides whether anything
--- on the strip is actually running.
---
--- Does nothing until all four outlets have reported at least once: a
--- strip-level state derived from a partial picture would be a guess, and a
--- guess is what this is avoiding.
local function update_strip_from_outlets(device)
  local any_on = false
  for outlet = 1, endpoints.OUTLET_COUNT do
    local state = device:get_latest_state(
      endpoints.component_for_outlet(outlet),
      capabilities.switch.ID,
      capabilities.switch.switch.NAME)
    if state == nil then
      return
    end
    if state == "on" then
      any_on = true
    end
  end

  local derived = any_on and "on" or "off"
  if device:get_latest_state("main", capabilities.switch.ID,
      capabilities.switch.switch.NAME) == derived then
    return
  end

  emit_for_component(device, "main",
    any_on and capabilities.switch.switch.on() or capabilities.switch.switch.off())
end

--- Basic:Report and SwitchBinary:Report. These arrive on the SWITCH
--- endpoints, 1..4, with no offset.
function handlers.switch_report(driver, device, cmd)
  -- 0 is truthy in Lua, so this chain is safe for an explicit "off".
  local value = cmd.args.value or cmd.args.current_value or cmd.args.target_value
  if value == nil then
    log.warn("switch report with no value")
    return
  end

  local event = value == 0 and capabilities.switch.switch.off()
    or capabilities.switch.switch.on()

  if cmd.src_channel == 0 then
    emit_for_component(device, "main", event)
    return
  end

  local outlet = endpoints.outlet_for_switch_channel(cmd.src_channel)
  if not outlet then
    log.warn(string.format(
      "switch report on channel %d; DSC11 switches on channels 1..%d, dropping",
      cmd.src_channel, endpoints.OUTLET_COUNT))
    return
  end

  emit_for_component(device, endpoints.component_for_outlet(outlet), event)

  -- An outlet changed, so the strip's own state may have too: turning off the
  -- last outlet that was on leaves the strip showing "on" forever otherwise.
  update_strip_from_outlets(device)
end

--- Meter:Report. These arrive on the METER endpoints, 3..6, for outlets 1..4.
--- Routed by hand: passing src_channel through the component map would
--- attribute outlet 1's power to outlet 3.
function handlers.meter_report(driver, device, cmd)
  local scale = cmd.args.scale
  local event

  -- Energy to 3dp, power to whole watts.
  --
  -- UPSTREAM ROUNDS ENERGY TO 2dp AND THAT IS TOO COARSE HERE. The device
  -- reports precision=3, and an always-on socket drawing a couple of watts
  -- sits below 0.005 kWh for the best part of an hour -- so 2dp reports it as
  -- 0.000 and the reading never becomes a value at all. Observed
  -- observed on hardware, a socket answering 0.001 kWh was published as 0.0,
  -- left its attribute unset, and the app showed "this device hasn't updated
  -- all of its status information yet" indefinitely.
  --
  -- 3dp is what the device actually sends, so nothing is invented by keeping
  -- it, and 1 Wh resolution is the difference between a low-draw socket
  -- reading zero forever and reading the truth. powerConsumptionReport is
  -- unaffected -- it works from the raw value in watt-hours.
  if scale == SCALE_KWH then
    event = capabilities.energyMeter.energy({
      value = utils.round(cmd.args.meter_value * 1000) / 1000, unit = "kWh" })
  elseif scale == SCALE_KVAH then
    event = capabilities.energyMeter.energy({
      value = utils.round(cmd.args.meter_value * 1000) / 1000, unit = "kVAh" })
  elseif scale == SCALE_WATTS then
    event = capabilities.powerMeter.power({
      value = utils.round(cmd.args.meter_value), unit = "W" })
  else
    log.warn(string.format("meter report with unhandled scale %s", tostring(scale)))
    return
  end

  local component_id
  if cmd.src_channel == 0 then
    component_id = "main"
  else
    local outlet = endpoints.outlet_for_meter_channel(cmd.src_channel)
    if outlet then
      component_id = endpoints.component_for_outlet(outlet)
    else
      -- Channels 1 and 2 are the two ALWAYS-ON sockets. They cannot be
      -- switched, but they ARE metered -- and on the unit this was
      -- established against, one of them carried a substantial standing load
      -- that no other component could account for.
      local always_on = endpoints.always_on_for_meter_channel(cmd.src_channel)
      if not always_on then
        log.warn(string.format(
          "meter report on channel %d; DSC11 meters channels %d..%d, dropping",
          cmd.src_channel,
          endpoints.always_on_meter_endpoint(1),
          endpoints.meter_endpoint(endpoints.OUTLET_COUNT)))
        return
      end
      component_id = endpoints.component_for_always_on(always_on)
    end
  end

  emit_for_component(device, component_id, event)

  -- SmartThings Energy reads powerConsumptionReport rather than energyMeter.
  -- Driven from the kWh reading only: kVAh is apparent energy, which is not
  -- what the platform totals, and watts are instantaneous.
  if scale == SCALE_KWH then
    emit_power_consumption(device, component_id, cmd.args.meter_value)
  end
end

--- Record that a parameter read back correctly, and mark the device
--- configured once every parameter in READ_BACK has.
---
--- READ_BACK is the set that decides whether per-outlet data arrives at all,
--- so those are the ones "configured" is allowed to mean. A confirmation for
--- anything else is recorded but does not complete the set.
local function note_confirmation(device, number)
  local confirmations = device:get_field(CONFIRMATIONS_FIELD) or {}
  confirmations[number] = true
  device:set_field(CONFIRMATIONS_FIELD, confirmations)

  for _, required in ipairs(configuration.READ_BACK) do
    if not confirmations[required] then
      return
    end
  end

  if not device:get_field(CONFIGURED_FIELD) then
    log.info("configuration confirmed by the device")
  end
  device:set_field(CONFIGURED_FIELD, true, { persist = true })
end

--- Configuration:Report -- the read-back. Logged with the expected value
--- beside it so a parameter that did not take is visible in logcat instead of
--- being assumed fine.
function handlers.configuration_report(driver, device, cmd)
  local number = cmd.args.parameter_number
  local actual = cmd.args.configuration_value
  -- Compared against the EFFECTIVE value, so a parameter the user has tuned
  -- through preferences is not reported as having failed to take.
  local expected = configuration.expected_value(device, number)

  if expected == nil then
    log.info(string.format("config param %s = %s", tostring(number), tostring(actual)))
    return
  end

  if actual ~= expected then
    log.warn(string.format("config param %s = %s but %s was set -- did not take",
      tostring(number), tostring(actual), tostring(expected)))
    -- The strip is not in the state this driver believes it to be, so the
    -- record saying otherwise is wrong. Clearing it makes the next driver
    -- start reconfigure, which is the only way back that does not need
    -- somebody to notice and run drivers:switch by hand.
    device:set_field(CONFIGURED_FIELD, false, { persist = true })
    return
  end

  log.info(string.format("config param %s = %s (as set)", tostring(number), tostring(actual)))
  note_confirmation(device, number)
end

--- Meter:SupportedReport -- the answer to "what can this meter actually do".
---
--- The driver asks for kWh and WATTS on the strength of what the legacy DTH
--- did. This is the device's own answer, and it settles three things that
--- were previously assumed:
---
---   * whether WATTS is supported at all -- the scale this driver exists to
---     request, and the one upstream never asks for;
---   * whether VOLTS and AMPERES are available, which would make SmartThings'
---     voltageMeasurement and currentMeasurement capabilities free to add;
---   * whether the meter can be reset, which is what per-outlet
---     resetEnergyMeter depends on and has never been confirmed on hardware.
---
--- Log-only. Nothing branches on it yet -- acting on it before it has been
--- seen once on real hardware would be guessing again, just with more steps.
function handlers.meter_supported_report(driver, device, cmd)
  local mask = cmd.args.scale_supported or 0
  local supported = {}
  for bit = 0, 7 do
    if (mask >> bit) & 1 == 1 then
      supported[#supported + 1] = SCALE_NAMES[bit] or string.format("scale %d", bit)
    end
  end

  device:set_field(METER_SCALES_FIELD, mask)

  log.info(string.format(
    "meter supports: %s (scale_supported = 0x%02X, meter_type = %s, resettable = %s)",
    #supported > 0 and table.concat(supported, ", ") or "nothing reported",
    mask,
    tostring(cmd.args.meter_type),
    tostring(cmd.args.meter_reset)))

  -- The one that matters for this driver's whole purpose.
  if (mask >> SCALE_WATTS) & 1 ~= 1 then
    log.warn("meter does NOT report WATTS -- per-outlet power cannot work on this device")
  end
end

--- Version:CommandClassReport -- which version of a command class the device
--- speaks. Asked for METER, because Meter:Get's scale field is a v2+ concept:
--- on a v1 meter the scale argument this driver sends has no meaning, which
--- would be a silent cause of per-outlet power never arriving.
function handlers.version_command_class_report(driver, device, cmd)
  local class = cmd.args.requested_command_class
  local version = cmd.args.command_class_version

  if class == cc.METER then
    device:set_field(METER_VERSION_FIELD, version)
    if version ~= nil and version < 2 then
      log.warn(string.format(
        "device speaks METER v%s; Meter:Get scale and Meter:SupportedGet are v2+, "
        .. "so scale-specific requests may be ignored", tostring(version)))
    else
      log.info(string.format("device speaks METER v%s", tostring(version)))
    end
    return
  end

  log.info(string.format("command class 0x%02X is v%s",
    tonumber(class) or 0, tostring(version)))
end

-------------------------------------------------------------------------------
-- lifecycle
-------------------------------------------------------------------------------

--- Push every parameter, then read the report groups back, then refresh.
function handlers.configure(driver, device)
  if device:get_field(CONFIGURING_FIELD) then
    log.info("configure already in flight; skipping duplicate")
    return
  end
  device:set_field(CONFIGURING_FIELD, true)
  -- A fresh round of confirmations: what the strip acknowledged last time
  -- says nothing about what it is acknowledging now.
  device:set_field(CONFIRMATIONS_FIELD, {})
  log.info("configuring DSC11")

  local steps = {}
  -- Effective, not shipped: a user who has tuned a preference must not have it
  -- silently reverted every time the driver is switched or reinstalled.
  for _, param in ipairs(configuration.effective_parameters(device)) do
    steps[#steps + 1] = function()
      device:send(Configuration:Set({
        parameter_number = param.parameter_number,
        size = param.size,
        configuration_value = param.configuration_value,
      }))
    end
  end
  for _, number in ipairs(configuration.READ_BACK) do
    steps[#steps + 1] = function()
      device:send(Configuration:Get({ parameter_number = number }))
    end
  end

  -- Ask the device what it can actually do, rather than continuing to infer it
  -- from what SmartThings' 2016 handler did. Answers are logged by
  -- meter_supported_report / version_command_class_report.
  steps[#steps + 1] = function()
    device:send(Version:CommandClassGet({ requested_command_class = cc.METER }))
  end
  steps[#steps + 1] = function()
    device:send(Meter:SupportedGet({}))
  end

  -- The always-on sockets used to be probed here, speculatively. They are no
  -- longer a question: they answered on hardware, they have components of
  -- their own, and the refresh below covers them like any other meter.

  steps[#steps + 1] = function()
    -- Deliberately NOT setting CONFIGURED_FIELD here. Everything has been
    -- sent, which is not the same as anything having been received; the
    -- read-back handler decides that.
    device:set_field(CONFIGURING_FIELD, nil)
    handlers.refresh(driver, device, { component = "main", background = true })
  end

  -- Background: a configure is thirty-five commands of bulk lifecycle work,
  -- and a switch tapped while it drains must not wait for all of them.
  send_sequence(device, steps, PRIORITY_BACKGROUND)
end

--- infoChanged -- a preference was changed in the app.
---
--- Without this the app accepts the new value and it never reaches the
--- device: the UI shows the setting as applied while the strip goes on using
--- the old one. That is silent, and it is the same failure shape READ_BACK
--- exists to catch -- so what is set here is read back too.
function handlers.info_changed(driver, device, event, args)
  if device:get_field(CONFIGURING_FIELD) then
    -- configure() builds its Sets from the preferences itself, so the new
    -- values are already on their way. Sending them again here would
    -- interleave two sequences on a device that cannot take the traffic --
    -- the same interleaving CONFIGURING_FIELD was added to prevent.
    log.info("preferences changed while configuring; configure will send them")
    return
  end

  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local current = device.preferences or {}

  local steps = {}
  local read_back = {}
  local changed = {}

  for _, id in ipairs(preferences.ORDER) do
    local entry = preferences.MAP[id]
    local value = current[id]
    if value ~= nil and value ~= old[id] then
      local numeric = preferences.to_numeric_value(value)
      if numeric == nil then
        log.warn(string.format(
          "preference '%s' is not a number (%s); ignoring", id, tostring(value)))
      else
        changed[#changed + 1] = string.format("%s=%s", id, tostring(numeric))
        for _, number in ipairs(entry.parameter_numbers) do
          steps[#steps + 1] = function()
            device:send(Configuration:Set({
              parameter_number = number,
              size = entry.size,
              configuration_value = numeric,
            }))
          end
          read_back[#read_back + 1] = number
        end
      end
    end
  end

  if #steps == 0 then
    return
  end

  log.info(string.format("preferences changed: %s", table.concat(changed, ", ")))

  for _, number in ipairs(read_back) do
    steps[#steps + 1] = function()
      device:send(Configuration:Get({ parameter_number = number }))
    end
  end

  send_sequence(device, steps)
end

-------------------------------------------------------------------------------
-- poll fallback
-------------------------------------------------------------------------------

--- Start the fallback poll, replacing any existing one.
---
--- Cancel-before-create matters: `init` runs on every driver start, and
--- creating a second interval without cancelling the first would double the
--- traffic each time -- on a device whose entire design constraint is not
--- sending too much at once.
---
--- THERE IS DELIBERATELY NO `removed` HANDLER cancelling this timer. On
--- removal the platform calls Device:deleted, which calls thread:close, which
--- cancels every timer on that thread. The one case where it would not is a
--- driver that sets `shared_device_thread_enabled` -- deleted skips closing a
--- shared thread -- and this driver does not set it. If that is ever added,
--- this timer starts leaking and a `removed` handler becomes necessary.
local function start_poll(device)
  local existing = device:get_field(POLL_TIMER_FIELD)
  if existing ~= nil then
    device.thread:cancel_timer(existing)
    device:set_field(POLL_TIMER_FIELD, nil)
  end

  local timer = device.thread:call_on_schedule(POLL_INTERVAL, function()
    -- Stands down rather than queueing. This is a backfill for the case where
    -- unsolicited reports have stopped; if anything else is already talking to
    -- the strip there is nothing to back-fill, and the next tick is only ten
    -- minutes away. Queueing one here would just mean a redundant 15 commands
    -- the moment the real work finished.
    if refresh_blocked(device) then
      log.info("poll skipped; the strip is already busy")
      return
    end
    -- nil driver: refresh never dereferences it. If that ever changes this is
    -- the call site that breaks, and it will break silently.
    handlers.refresh(nil, device, { component = "main", background = true })
  end, "dsc11_poll")

  device:set_field(POLL_TIMER_FIELD, timer)
end

handlers.start_poll = start_poll

function handlers.device_init(driver, device)
  device:set_component_to_endpoint_fn(endpoints.component_to_endpoint)
  device:set_endpoint_to_component_fn(endpoints.endpoint_to_component)

  start_poll(device)

  -- doConfigure fires when a device is joined or configured. This strip was
  -- joined in 2017 under a DTH and reaches this driver by being switched onto
  -- it, which is not a join -- so doConfigure may never fire for the one
  -- device this driver exists for. driverSwitched covers that path; this
  -- covers whatever both miss.
  if not device:get_field(CONFIGURED_FIELD) then
    log.info("no record of configuring this device; configuring now")
    handlers.configure(driver, device)
  end
end

-- THERE IS DELIBERATELY NO `added` HANDLER.
--
-- The obvious one refreshes, and it is redundant in every path that reaches
-- it. `init` runs before `added`, a freshly added device has no record of
-- being configured, so init always starts a configure -- and configure ends
-- with exactly that refresh. An `added` refresh therefore adds nothing except
-- 15 commands interleaved with the 34 that configure is already sending, on a
-- device whose one binding constraint is not sending too much at once.
--
-- Since the fallback poll was added there are three things that refresh:
-- configure's tail, the poll, and the user. A fourth that fires at the worst
-- possible moment is not an improvement.
function handlers.driver_switched(driver, device)
  -- The path this device actually arrives by: `smartthings edge:drivers:switch`.
  handlers.configure(driver, device)
end

--- Test seam for the command queue. The ordering guarantees -- user work
--- ahead of background work, user work among itself in the order it arrived
--- -- are the whole point of the queue and are otherwise only observable
--- through whichever handler happens to call it.
---
--- `during` runs after the first step of this sequence, which is how a test
--- stages "something else arrives while this one is draining".
--- @param priority string "user" or "background"
function handlers.send_sequence_for_test(device, steps, priority, during)
  if steps == nil then
    send_sequence(device, nil, priority)
    return
  end
  local wrapped = {}
  for i, step in ipairs(steps) do
    wrapped[i] = step
  end
  if during and wrapped[1] then
    local first = wrapped[1]
    wrapped[1] = function()
      first()
      during()
    end
  end
  send_sequence(device, wrapped, priority)
end

handlers.CONFIGURED_FIELD = CONFIGURED_FIELD
handlers.CONFIGURING_FIELD = CONFIGURING_FIELD
handlers.REFRESHING_FIELD = REFRESHING_FIELD
handlers.REFRESH_PENDING_FIELD = REFRESH_PENDING_FIELD
handlers.METER_SCALES_FIELD = METER_SCALES_FIELD
handlers.METER_VERSION_FIELD = METER_VERSION_FIELD
handlers.PCR_LAST_TIME_FIELD = PCR_LAST_TIME_FIELD
handlers.PCR_MINIMUM_INTERVAL = PCR_MINIMUM_INTERVAL
handlers.POLL_INTERVAL = POLL_INTERVAL
handlers.POLL_TIMER_FIELD = POLL_TIMER_FIELD
handlers.COMMAND_INTERVAL = COMMAND_INTERVAL
handlers.RESET_ENERGY_CAPABILITY = RESET_ENERGY_CAPABILITY
handlers.cc = cc
handlers.Basic = Basic
handlers.Configuration = Configuration
handlers.Meter = Meter
handlers.SwitchBinary = SwitchBinary
handlers.Version = Version

return handlers
