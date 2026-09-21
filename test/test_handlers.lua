-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0

--[[
  Tests for the DSC11 handlers: report routing, what refresh puts on the wire,
  per-endpoint reset, and configuration.

  Run from the repo root:
      lua test/test_handlers.lua

  The two behaviours worth the most attention here:

    * a METER report on channel 3 belongs to outlet 1. Routing it through the
      component map instead -- which every SmartThings default handler would
      do -- attributes outlet 1's power to outlet 3.
    * refresh must ask the meter endpoints for WATTS. The stock subdriver asks
      only for kWh and kVAh, which is why per-outlet power never populates
      there. That is the defect this driver exists to fix, so it gets a test.
]]

local here = (arg and arg[0] or "test/test_handlers.lua"):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/../src/?.lua;src/?.lua;test/?.lua;" .. package.path

local stubs = require "stubs"
local handlers = require "handlers"
local configuration = require "configuration"

local passed, failed = 0, 0

local function check(name, actual, expected)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("FAIL  %s\n        expected %s, got %s",
      name, tostring(expected), tostring(actual)))
  end
end

local function fail(name, detail)
  failed = failed + 1
  print(string.format("FAIL  %s\n        %s", name, detail))
end

local SCALE_KWH, SCALE_KVAH, SCALE_WATTS = 0, 1, 2

local function meter_report(channel, scale, value)
  return { src_channel = channel, args = { scale = scale, meter_value = value } }
end

local function switch_report(channel, value)
  return { src_channel = channel, args = { value = value } }
end

-------------------------------------------------------------------------------
-- meter report routing: the crux
-------------------------------------------------------------------------------

-- Meter endpoints 3..6 map onto outlets 1..4.
for _, case in ipairs({
  { channel = 3, component = "switch1" },
  { channel = 4, component = "switch2" },
  { channel = 5, component = "switch3" },
  { channel = 6, component = "switch4" },
}) do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(case.channel, SCALE_WATTS, 40))
  check(string.format("meter WATTS on channel %d -> %s (emit count)",
    case.channel, case.component), #device.emitted, 1)
  if #device.emitted == 1 then
    check(string.format("meter WATTS on channel %d -> %s",
      case.channel, case.component), device.emitted[1].component, case.component)
    check(string.format("channel %d emits powerMeter", case.channel),
      device.emitted[1].event.cap, "powerMeter")
  end
end

-- The specific misattribution a single component map would cause.
do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(3, SCALE_WATTS, 930))
  check("channel 3 is NOT attributed to switch3",
    device.emitted[1] and device.emitted[1].component ~= "switch3", true)
end

-- Channel 0 is the whole strip.
do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(0, SCALE_WATTS, 93))
  check("meter on channel 0 -> main", device.emitted[1].component, "main")
  check("meter on channel 0 value", device.emitted[1].event.value, 93)
end

-- Channels 1 and 2 are the two ALWAYS-ON sockets. Confirmed on hardware: the
-- strip meters all six sockets, the always-on pair first, which is exactly
-- why the switchable four are offset by two.
for _, case in ipairs({
  { channel = 1, component = "alwaysOn1" },
  { channel = 2, component = "alwaysOn2" },
}) do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(case.channel, SCALE_WATTS, 86))
  check(string.format("meter WATTS on channel %d -> %s",
    case.channel, case.component), device.emitted[1].component, case.component)
  check(string.format("channel %d is not dropped", case.channel), #stubs.warnings, 0)
  check(string.format("channel %d carries its reading", case.channel),
    device.emitted[1].event.value, 86)
end

-- An always-on socket is metered but NOT switchable, so a switch report from
-- one of those channels is still the outlet, not the always-on socket. The
-- two conventions overlap here and only the command class separates them.
do
  local device = stubs.new_device()
  handlers.switch_report(nil, device, switch_report(1, 0xFF))
  check("switch channel 1 is still outlet 1, not an always-on socket",
    device.emitted[1].component, "switch1")
end

-- Channel 7 and beyond belong to nothing.
do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(7, SCALE_WATTS, 5))
  check("meter on channel 7 emits nothing", #device.emitted, 0)
  check("meter on channel 7 is logged", #stubs.warnings, 1)
end

-- Energy scales, and rounding.
do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 12.3456))
  check("kWh -> energyMeter", device.emitted[1].event.cap, "energyMeter")
  check("kWh unit", device.emitted[1].event.unit, "kWh")
  check("kWh rounded to 3dp", device.emitted[1].event.value, 12.346)
end
do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(4, SCALE_KVAH, 8.014))
  check("kVAh handled if volunteered", device.emitted[1].event.unit, "kVAh")
  check("kVAh -> switch2", device.emitted[1].component, "switch2")
end
do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(5, SCALE_WATTS, 50.6))
  check("watts rounded to whole", device.emitted[1].event.value, 51)
  check("watts unit", device.emitted[1].event.unit, "W")
end

-- A SMALL READING MUST SURVIVE THE ROUNDING. An always-on socket drawing a
-- couple of watts sits under 0.005 kWh for most of an hour; at 2dp it reports
-- 0.0, the attribute never gets a value, and the app says the device has not
-- finished updating. The device sends 3 decimal places, so keep them.
do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(2, SCALE_KWH, 0.001))
  check("a 1 Wh reading is not flattened to zero",
    device.emitted[1].event.value, 0.001)
  check("and lands on the always-on socket",
    device.emitted[1].component, "alwaysOn2")
end

-- An unknown scale must not emit a nil-valued event.
do
  local device = stubs.new_device()
  handlers.meter_report(nil, device, meter_report(3, 4, 120))
  check("unhandled scale emits nothing", #device.emitted, 0)
  check("unhandled scale is logged", #stubs.warnings, 1)
end

-------------------------------------------------------------------------------
-- switch report routing
-------------------------------------------------------------------------------

-- Switch endpoints are 1..4, no offset.
for channel = 1, 4 do
  local device = stubs.new_device()
  handlers.switch_report(nil, device, switch_report(channel, 0xFF))
  check(string.format("switch report on channel %d -> switch%d", channel, channel),
    device.emitted[1].component, string.format("switch%d", channel))
  check(string.format("channel %d value on", channel), device.emitted[1].event.value, "on")
end

do
  local device = stubs.new_device()
  handlers.switch_report(nil, device, switch_report(2, 0x00))
  check("switch report value 0 -> off", device.emitted[1].event.value, "off")
end

-- A device-wide switch report says nothing about the individual outlets, so it
-- must NOT be fanned out to all four. Doing that is what makes every outlet
-- mirror main and look healthy when per-outlet reporting is dead.
do
  local device = stubs.new_device()
  handlers.switch_report(nil, device, switch_report(0, 0xFF))
  check("switch report on channel 0 emits once only", #device.emitted, 1)
  check("switch report on channel 0 -> main", device.emitted[1].component, "main")
end

-- SwitchBinary v2 reports carry current_value rather than value.
do
  local device = stubs.new_device()
  handlers.switch_report(nil, device, { src_channel = 1, args = { current_value = 0x00 } })
  check("current_value honoured", device.emitted[1].event.value, "off")
end

do
  local device = stubs.new_device()
  handlers.switch_report(nil, device, { src_channel = 1, args = {} })
  check("valueless report emits nothing", #device.emitted, 0)
end

do
  local device = stubs.new_device()
  handlers.switch_report(nil, device, switch_report(5, 0xFF))
  check("switch report on channel 5 emits nothing", #device.emitted, 0)
  check("switch report on channel 5 logged", #stubs.warnings, 1)
end

-------------------------------------------------------------------------------
-- refresh: per-outlet WATTS is the whole point
-------------------------------------------------------------------------------

do
  local device = stubs.new_device()
  handlers.refresh(nil, device, { component = "main" })

  -- WATTS must be requested from every meter endpoint.
  local watt_channels = {}
  for _, cmd in ipairs(stubs.sent_matching(device, "Meter", "Get")) do
    if cmd.args.scale == SCALE_WATTS then
      watt_channels[stubs.channel_of(cmd)] = true
    end
  end
  for _, channel in ipairs({ 3, 4, 5, 6 }) do
    check(string.format("refresh requests WATTS from meter endpoint %d", channel),
      watt_channels[channel], true)
  end
  check("refresh requests WATTS from the strip too", watt_channels[0], true)
  -- The always-on sockets: 86 W was sitting on one of these, invisible.
  check("refresh requests WATTS from always-on endpoint 1", watt_channels[1], true)
  check("refresh requests WATTS from always-on endpoint 2", watt_channels[2], true)

  -- ...and kWh as well.
  local kwh_channels = {}
  for _, cmd in ipairs(stubs.sent_matching(device, "Meter", "Get")) do
    if cmd.args.scale == SCALE_KWH then
      kwh_channels[stubs.channel_of(cmd)] = true
    end
  end
  for _, channel in ipairs({ 0, 1, 2, 3, 4, 5, 6 }) do
    check(string.format("refresh requests kWh from endpoint %d", channel),
      kwh_channels[channel], true)
  end

  -- kVAh is deliberately never requested.
  local asked_kvah = false
  for _, cmd in ipairs(stubs.sent_matching(device, "Meter", "Get")) do
    if cmd.args.scale == SCALE_KVAH then asked_kvah = true end
  end
  check("refresh never requests kVAh", asked_kvah, false)

  -- Switch state comes from the switch endpoints, not the meter ones.
  local switch_channels = {}
  for _, cmd in ipairs(stubs.sent_matching(device, "SwitchBinary", "Get")) do
    switch_channels[stubs.channel_of(cmd)] = true
  end
  for _, channel in ipairs({ 0, 1, 2, 3, 4 }) do
    check(string.format("refresh reads switch state on endpoint %d", channel),
      switch_channels[channel], true)
  end
  check("refresh does not read switch state on endpoint 5", switch_channels[5], nil)
  check("refresh does not read switch state on endpoint 6", switch_channels[6], nil)
end

-- Refreshing one outlet touches only that outlet's two endpoints.
do
  local device = stubs.new_device()
  handlers.refresh(nil, device, { component = "switch1" })
  local meters = stubs.sent_matching(device, "Meter", "Get")
  check("outlet refresh sends two meter gets", #meters, 2)
  for _, cmd in ipairs(meters) do
    if stubs.channel_of(cmd) ~= 3 then
      fail("outlet 1 refresh meters endpoint 3",
        "got channel " .. stubs.channel_of(cmd))
    else
      passed = passed + 1
    end
  end
  local switches = stubs.sent_matching(device, "SwitchBinary", "Get")
  check("outlet refresh reads one switch endpoint", #switches, 1)
  check("outlet 1 switch endpoint is 1", stubs.channel_of(switches[1]), 1)
end

do
  local device = stubs.new_device()
  handlers.refresh(nil, device, { component = "switch9" })
  check("refresh on a non-existent outlet sends nothing", #device.sent, 0)
  check("refresh on a non-existent outlet is logged", #stubs.warnings, 1)
end

-------------------------------------------------------------------------------
-- switching
-------------------------------------------------------------------------------

do
  local device = stubs.new_device()
  handlers.switch_on(nil, device, { component = "switch1" })

  local sets = stubs.sent_matching(device, "Basic", "Set")
  check("outlet on sends one Basic:Set", #sets, 1)
  check("outlet 1 set goes to switch endpoint 1", stubs.channel_of(sets[1]), 1)
  check("on sends 0xFF", sets[1].args.value, 0xFF)

  local meters = stubs.sent_matching(device, "Meter", "Get")
  check("outlet on re-reads power", #meters, 1)
  check("power re-read uses meter endpoint 3", stubs.channel_of(meters[1]), 3)
end

do
  local device = stubs.new_device()
  handlers.switch_off(nil, device, { component = "switch4" })
  local sets = stubs.sent_matching(device, "Basic", "Set")
  check("off sends 0x00", sets[1].args.value, 0x00)
  check("outlet 4 set goes to switch endpoint 4", stubs.channel_of(sets[1]), 4)
  local meters = stubs.sent_matching(device, "Meter", "Get")
  check("outlet 4 power re-read uses meter endpoint 6", stubs.channel_of(meters[1]), 6)
end

-- Switching main must then ask each outlet what it really did.
do
  local device = stubs.new_device()
  handlers.switch_on(nil, device, { component = "main" })
  local sets = stubs.sent_matching(device, "Basic", "Set")
  check("main on sends one Basic:Set", #sets, 1)
  check("main set is addressed to the root", stubs.channel_of(sets[1]), 0)

  local queried = {}
  for _, cmd in ipairs(stubs.sent_matching(device, "SwitchBinary", "Get")) do
    queried[stubs.channel_of(cmd)] = true
  end
  for _, channel in ipairs({ 0, 1, 2, 3, 4 }) do
    check(string.format("main on re-reads switch endpoint %d", channel),
      queried[channel], true)
  end
end

do
  local device = stubs.new_device()
  handlers.switch_on(nil, device, { component = "bogus" })
  check("switch on unknown component sends nothing", #device.sent, 0)
  check("switch on unknown component is logged", #stubs.warnings, 1)
end

-------------------------------------------------------------------------------
-- energy reset
-------------------------------------------------------------------------------

do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "switch1" })
  local resets = stubs.sent_matching(device, "Meter", "Reset")
  check("outlet reset sends one Meter:Reset", #resets, 1)
  check("outlet 1 reset targets meter endpoint 3", stubs.channel_of(resets[1]), 3)
  local gets = stubs.sent_matching(device, "Meter", "Get")
  check("outlet reset re-reads energy", #gets, 1)
  check("outlet reset re-read is kWh", gets[1].args.scale, SCALE_KWH)
  check("outlet reset re-read targets endpoint 3", stubs.channel_of(gets[1]), 3)
end

do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "switch3" })
  local resets = stubs.sent_matching(device, "Meter", "Reset")
  check("outlet 3 reset targets meter endpoint 5", stubs.channel_of(resets[1]), 5)
end

-- The always-on sockets render a reset button too, because SmartThings
-- generates one for every component declaring energyMeter. If the handler
-- does not understand them, that button silently does nothing.
do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "alwaysOn1" })
  local resets = stubs.sent_matching(device, "Meter", "Reset")
  check("an always-on socket can be reset", #resets, 1)
  check("alwaysOn1 resets meter endpoint 1", stubs.channel_of(resets[1]), 1)
  local gets = stubs.sent_matching(device, "Meter", "Get")
  check("and is re-read", #gets, 1)
  check("the re-read targets endpoint 1", stubs.channel_of(gets[1]), 1)
  check("nothing is logged as unknown", #stubs.warnings, 0)
end

do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "alwaysOn2" })
  check("alwaysOn2 resets meter endpoint 2",
    stubs.channel_of(stubs.sent_matching(device, "Meter", "Reset")[1]), 2)
end

do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "alwaysOn9" })
  check("an out-of-range always-on component sends nothing", #device.sent, 0)
  check("and is logged", #stubs.warnings, 1)
end

-- A reset must SAY it happened. The button wipes a lifetime register and the
-- energy figure only changes once the strip answers, so without this the tap
-- appears to do nothing at all.
do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "switch3" })
  local notes = {}
  for _, e in ipairs(device.emitted) do
    if e.event.cap == handlers.RESET_ENERGY_CAPABILITY then notes[#notes + 1] = e end
  end
  check("a per-component reset records when it happened", #notes, 1)
  check("against the component that was reset", notes[1].component, "switch3")
  check("with a timestamp, not an empty value",
    type(notes[1].event.value) == "string" and #notes[1].event.value > 0, true)
end

do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "alwaysOn1" })
  local notes = {}
  for _, e in ipairs(device.emitted) do
    if e.event.cap == handlers.RESET_ENERGY_CAPABILITY then notes[#notes + 1] = e end
  end
  check("an always-on reset records it too", #notes, 1)
  check("on the right component", notes[1].component, "alwaysOn1")
end

-- main clears all seven registers, so all seven must show it.
do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "main" })
  local seen = {}
  for _, e in ipairs(device.emitted) do
    if e.event.cap == handlers.RESET_ENERGY_CAPABILITY then seen[e.component] = true end
  end
  for _, c in ipairs({ "main", "switch1", "switch2", "switch3", "switch4",
                       "alwaysOn1", "alwaysOn2" }) do
    check("reset-all records " .. c, seen[c], true)
  end
end

-- main resets the strip register and every outlet register.
do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "main" })
  local reset_channels = {}
  for _, cmd in ipairs(stubs.sent_matching(device, "Meter", "Reset")) do
    reset_channels[stubs.channel_of(cmd)] = true
  end
  -- All SEVEN: the root, the four outlets, and the two always-on sockets.
  -- Leaving the always-on pair out would make "reset all" mean "reset most",
  -- and on the measured unit they held most of the strip's energy.
  for _, channel in ipairs({ 0, 1, 2, 3, 4, 5, 6 }) do
    check(string.format("main reset clears endpoint %d", channel),
      reset_channels[channel], true)
  end
  check("main reset sends seven resets",
    #stubs.sent_matching(device, "Meter", "Reset"), 7)
  check("main reset re-reads seven registers",
    #stubs.sent_matching(device, "Meter", "Get"), 7)

  -- Every reset must precede every re-read, or the re-read returns the old value.
  local last_reset, first_get = 0, math.huge
  for i, cmd in ipairs(device.sent) do
    if cmd.cc == "Meter" and cmd.cmd == "Reset" then last_reset = i end
    if cmd.cc == "Meter" and cmd.cmd == "Get" and i < first_get then first_get = i end
  end
  check("all resets precede all re-reads", last_reset < first_get, true)
end

-------------------------------------------------------------------------------
-- configuration
-------------------------------------------------------------------------------

do
  local device = stubs.new_device()
  handlers.configure(nil, device)

  local sets = stubs.sent_matching(device, "Configuration", "Set")
  check("configure sends every parameter", #sets, #configuration.PARAMETERS)

  local by_number = {}
  for _, cmd in ipairs(sets) do by_number[cmd.args.parameter_number] = cmd.args end

  -- Spot-check the report groups, which are the ones that decide whether
  -- per-outlet data arrives at all.
  check("param 101 value", by_number[101] and by_number[101].configuration_value, 1)
  check("param 102 value (0x7900)", by_number[102] and by_number[102].configuration_value, 30976)
  check("param 102 size", by_number[102] and by_number[102].size, 4)
  check("param 111 interval", by_number[111] and by_number[111].configuration_value, 900)
  check("param 112 interval", by_number[112] and by_number[112].configuration_value, 90)

  local gets = stubs.sent_matching(device, "Configuration", "Get")
  check("configure reads the report groups back", #gets, #configuration.READ_BACK)

  -- NOT marked configured here: everything has been sent, which is not the
  -- same as anything having been received. See the read-back tests below.
  check("configure alone does not mark the device configured",
    device.fields[handlers.CONFIGURED_FIELD], nil)

  -- A configure ends by refreshing, so per-outlet values populate immediately.
  check("configure ends with a refresh",
    #stubs.sent_matching(device, "Meter", "Get") > 0, true)
end

-- init configures a device that has never been configured...
do
  local device = stubs.new_device()
  handlers.device_init(nil, device)
  check("init configures an unconfigured device",
    #stubs.sent_matching(device, "Configuration", "Set"), #configuration.PARAMETERS)
end

-- ...and leaves an already-configured one alone.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.device_init(nil, device)
  check("init skips an already-configured device",
    #stubs.sent_matching(device, "Configuration", "Set"), 0)
end

-- driverSwitched always reconfigures: it is the path this device arrives by.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.driver_switched(nil, device)
  check("driverSwitched reconfigures regardless",
    #stubs.sent_matching(device, "Configuration", "Set"), #configuration.PARAMETERS)
end

-- Edge fires both init and driverSwitched on a driver switch -- the path this
-- device actually arrives by -- and CONFIGURED_FIELD is not set until the
-- sequence finishes, so it cannot gate the second call. An in-flight guard
-- must, or the strip gets two interleaved sequences and the read-back logs
-- values that the other sequence is still overwriting.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURING_FIELD] = true
  handlers.configure(nil, device)
  check("configure in flight sends nothing", #device.sent, 0)
  check("duplicate configure is logged", #stubs.infos, 1)
end

do
  local device = stubs.new_device()
  handlers.configure(nil, device)
  check("configure clears the in-flight flag when done",
    device.fields[handlers.CONFIGURING_FIELD], nil)
  -- ...so a later legitimate reconfigure is not permanently blocked.
  local before = #device.sent
  handlers.configure(nil, device)
  check("a later configure still runs", #device.sent > before, true)
end

-- init then driverSwitched, with init's sequence still in flight.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURING_FIELD] = true
  handlers.device_init(nil, device)
  handlers.driver_switched(nil, device)
  check("init + driverSwitched mid-configure sends nothing extra", #device.sent, 0)
end

-- The read-back must complain when a parameter did not take.
do
  local device = stubs.new_device()
  handlers.configuration_report(nil, device,
    { args = { parameter_number = 102, configuration_value = 0 } })
  check("mismatched read-back warns", #stubs.warnings, 1)
end
do
  local device = stubs.new_device()
  handlers.configuration_report(nil, device,
    { args = { parameter_number = 102, configuration_value = 30976 } })
  check("matching read-back does not warn", #stubs.warnings, 0)
end

-------------------------------------------------------------------------------
-- "configured" means the strip said so
--
-- A Configuration:Set is unacknowledged. If finishing the sequence were taken
-- as success, a strip that was asleep or out of range throughout would be
-- marked configured forever and init would skip it on every restart -- which
-- looks identical to a strip that was configured correctly and is reporting
-- nothing per-outlet.
-------------------------------------------------------------------------------

--- Feed the read-back the value it expects for one parameter.
local function confirm(device, number)
  handlers.configuration_report(nil, device, { args = {
    parameter_number = number,
    configuration_value = configuration.expected_value(device, number),
  } })
end

do
  local device = stubs.new_device()
  handlers.configure(nil, device)
  for _, number in ipairs(configuration.READ_BACK) do
    confirm(device, number)
  end
  check("confirming every read-back parameter marks the device configured",
    device.fields[handlers.CONFIGURED_FIELD], true)
  check("and says so once", #stubs.infos > 0, true)
end

do
  local device = stubs.new_device()
  handlers.configure(nil, device)
  for i = 1, #configuration.READ_BACK - 1 do
    confirm(device, configuration.READ_BACK[i])
  end
  check("a partial confirmation is not enough",
    device.fields[handlers.CONFIGURED_FIELD], nil)
end

-- A parameter outside READ_BACK must not complete the set.
do
  local device = stubs.new_device()
  handlers.configure(nil, device)
  handlers.configuration_report(nil, device,
    { args = { parameter_number = 4, configuration_value = 1 } })
  check("an untracked parameter does not mark it configured",
    device.fields[handlers.CONFIGURED_FIELD], nil)
end

-- A strip that never answers stays unconfigured...
do
  local device = stubs.new_device()
  handlers.configure(nil, device)
  check("a silent strip is never marked configured",
    device.fields[handlers.CONFIGURED_FIELD], nil)
end

-- ...which is precisely what makes the next driver start try again.
do
  local device = stubs.new_device()
  handlers.device_init(nil, device)
  check("init reconfigures a device that never confirmed",
    #stubs.sent_matching(device, "Configuration", "Set"), #configuration.PARAMETERS)
end

-- A read-back that comes back wrong revokes the record.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.configuration_report(nil, device,
    { args = { parameter_number = 102, configuration_value = 0 } })
  check("a failed read-back clears the configured record",
    device.fields[handlers.CONFIGURED_FIELD], false)
end

-- ...and a revoked record means the next start reconfigures, which is the
-- only way back that does not need somebody to notice.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = false
  handlers.device_init(nil, device)
  check("init reconfigures after a revoked record",
    #stubs.sent_matching(device, "Configuration", "Set"), #configuration.PARAMETERS)
end

-- What the strip acknowledged last time says nothing about this time.
do
  local device = stubs.new_device()
  handlers.configure(nil, device)
  for i = 1, #configuration.READ_BACK - 1 do
    confirm(device, configuration.READ_BACK[i])
  end

  device.fields[handlers.CONFIGURING_FIELD] = nil
  handlers.configure(nil, device)
  confirm(device, configuration.READ_BACK[#configuration.READ_BACK])

  check("confirmations do not carry across configures",
    device.fields[handlers.CONFIGURED_FIELD], nil)
end

-------------------------------------------------------------------------------
-- there is no `added` handler
--
-- init runs first, a freshly added device has no record of being configured,
-- so init always starts a configure -- and configure ends with a refresh. An
-- `added` refresh would add nothing but 15 commands interleaved with the 34
-- configure is already sending. Since the poll arrived there are already
-- three things that refresh.
-------------------------------------------------------------------------------

check("no added handler exists", handlers.device_added, nil)

-------------------------------------------------------------------------------
-- the strip's own state follows its outlets
-------------------------------------------------------------------------------

-- Nothing is derived from a partial picture.
do
  local device = stubs.new_device()
  handlers.switch_report(nil, device, switch_report(1, 0xFF))
  check("one outlet does not derive a strip state",
    device:get_latest_state("main", "switch", "switch"), nil)
  check("only the outlet is emitted", #device.emitted, 1)
end

do
  local device = stubs.new_device()
  for channel = 1, 3 do
    handlers.switch_report(nil, device, switch_report(channel, 0xFF))
  end
  check("three outlets are still not enough",
    device:get_latest_state("main", "switch", "switch"), nil)
end

-- Once all four are known, the strip follows them.
do
  local device = stubs.new_device()
  for channel = 1, 4 do
    handlers.switch_report(nil, device, switch_report(channel, 0xFF))
  end
  check("four outlets on derives the strip on",
    device:get_latest_state("main", "switch", "switch"), "on")
  check("the strip event went to main",
    device.emitted[#device.emitted].component, "main")
end

-- THE BUG: turning outlets off one at a time used to leave the strip
-- showing "on" forever.
do
  local device = stubs.new_device()
  for channel = 1, 4 do
    handlers.switch_report(nil, device, switch_report(channel, 0xFF))
  end
  for channel = 1, 3 do
    handlers.switch_report(nil, device, switch_report(channel, 0x00))
  end
  check("the strip stays on while any outlet is on",
    device:get_latest_state("main", "switch", "switch"), "on")

  handlers.switch_report(nil, device, switch_report(4, 0x00))
  check("turning off the last outlet turns the strip off",
    device:get_latest_state("main", "switch", "switch"), "off")
end

-- Turning one back on brings the strip with it.
do
  local device = stubs.new_device()
  for channel = 1, 4 do
    handlers.switch_report(nil, device, switch_report(channel, 0x00))
  end
  check("four outlets off derives the strip off",
    device:get_latest_state("main", "switch", "switch"), "off")
  handlers.switch_report(nil, device, switch_report(2, 0xFF))
  check("one outlet back on brings the strip back on",
    device:get_latest_state("main", "switch", "switch"), "on")
end

-- An unchanged strip state is not re-emitted on every outlet report.
do
  local device = stubs.new_device()
  for channel = 1, 4 do
    handlers.switch_report(nil, device, switch_report(channel, 0xFF))
  end
  local before = #device.emitted
  handlers.switch_report(nil, device, switch_report(1, 0xFF))
  check("only the outlet is emitted when the strip is unchanged",
    #device.emitted, before + 1)
end

-- The forbidden direction stays forbidden: a strip-level report still says
-- nothing about the individual outlets.
do
  local device = stubs.new_device()
  handlers.switch_report(nil, device, switch_report(0, 0xFF))
  check("a strip report is still not fanned out", #device.emitted, 1)
  check("and still goes only to main", device.emitted[1].component, "main")
end

-------------------------------------------------------------------------------
-- staggering
--
-- Commands are paced roughly a second apart, never bursted: 2012 hardware on
-- a non-secure link. The stub runs each step immediately but records the
-- delay it was asked for, because otherwise setting COMMAND_INTERVAL to zero
-- -- which would burst every sequence in the driver -- passes the whole
-- suite.
-------------------------------------------------------------------------------

do
  local device = stubs.new_device()
  handlers.refresh(nil, device, { component = "main" })

  -- 19 commands: 3 for the strip, 3 per switchable outlet, and 2 per
  -- always-on socket (power and energy, but no switch state -- they cannot
  -- be switched).
  check("a main refresh is 19 commands", #device.sent, 19)

  -- The queue is self-clocking: it sends one command, then schedules itself
  -- one interval later. So every delay is the SAME -- the interval itself --
  -- rather than an increasing offset, and there is one per step including
  -- the closing one that releases the guard.
  check("one scheduled wake per step", #device.delays, 20)
  check("the interval is not zero", handlers.COMMAND_INTERVAL > 0, true)

  local all_one_interval = true
  for _, d in ipairs(device.delays) do
    if d ~= handlers.COMMAND_INTERVAL then all_one_interval = false end
  end
  check("every command waits exactly one interval", all_one_interval, true)

  -- Which is what actually matters: the whole sequence takes one interval per
  -- command, so nothing is ever sent at once.
  local total = 0
  for _, d in ipairs(device.delays) do total = total + d end
  check("the sequence spans one interval per step",
    total, handlers.COMMAND_INTERVAL * 20)
end

-- The same rule applies to the other sequences, not just refresh.
do
  local device = stubs.new_device()
  handlers.reset_energy_meter(nil, device, { component = "main" })
  check("a main reset is 14 commands", #device.sent, 14)
  check("a main reset is staggered", #device.delays, 14)
end

do
  local device = stubs.new_device()
  handlers.switch_on(nil, device, { component = "main" })
  check("switching main is staggered", #device.delays, #device.sent)
end

-------------------------------------------------------------------------------
-- the command queue
--
-- Every sequence goes through one device-wide queue. Scheduling each one
-- independently meant a switch, reset, preference change or configure landing
-- mid-refresh laid its commands on top of the ones already scheduled -- two a
-- second on hardware that is meant to see one.
-------------------------------------------------------------------------------

-- The stub drains the queue synchronously, so a sequence started from inside
-- another lands behind it rather than interleaving. This asserts ordering,
-- which is the property that matters.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.device_init(nil, device)

  -- Background work first...
  stubs.fire_schedule(device)
  local background_commands = #device.sent
  check("the poll queues a full refresh", background_commands, 19)
end

-- A user action must not wait behind background work. The queue puts it in
-- front of anything still queued at background priority.
do
  local device = stubs.new_device()
  local order = {}
  -- Queue background work, then user work, and record the order they run.
  handlers.send_sequence_for_test(device, {
    function() order[#order + 1] = "bg1" end,
    function() order[#order + 1] = "bg2" end,
    function() order[#order + 1] = "bg3" end,
  }, "background", function()
    -- While bg1 is being sent, the user taps something.
    handlers.send_sequence_for_test(device, {
      function() order[#order + 1] = "user" end,
    }, "user")
  end)

  check("a user command jumps the background queue", order[2], "user")
  check("and background work resumes behind it", order[3], "bg2")
  check("nothing is lost", #order, 4)
end

-- Two user actions, arriving while background work is still queued, must run
-- in the order they were made. Inserting each at the very front would run
-- them backwards, and only a queue that still holds background items can
-- tell the difference.
do
  local device = stubs.new_device()
  local order = {}
  handlers.send_sequence_for_test(device, {
    function() order[#order + 1] = "bg1" end,
    function() order[#order + 1] = "bg2" end,
    function() order[#order + 1] = "bg3" end,
  }, "background", function()
    handlers.send_sequence_for_test(device, {
      function() order[#order + 1] = "userX" end,
    }, "user")
    handlers.send_sequence_for_test(device, {
      function() order[#order + 1] = "userY" end,
    }, "user")
  end)

  check("the first user command jumps the queue", order[2], "userX")
  check("the second follows it, not precedes it", order[3], "userY")
  check("then background work resumes", order[4], "bg2")
  check("and finishes", order[5], "bg3")
end

-- CONFIGURE IS BACKGROUND WORK. Thirty-five commands, and a switch tapped
-- while it drains must not wait for all of them.
do
  local device = stubs.new_device(nil, { defer = true })
  handlers.configure(nil, device)
  handlers.switch_on(nil, device, { component = "switch1" })
  stubs.drain(device)

  local set_at
  for i, cmd in ipairs(device.sent) do
    if cmd.cc == "Basic" and cmd.cmd == "Set" then set_at = i break end
  end
  check("a switch during configure is sent", set_at ~= nil, true)
  check("and does not wait for the whole configure",
    set_at ~= nil and set_at <= 4, true)
  check("while configure still sends everything",
    #stubs.sent_matching(device, "Configuration", "Set"), #configuration.PARAMETERS)
end

-- THE POLL IS BACKGROUND WORK TOO.
do
  local device = stubs.new_device(nil, { defer = true })
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.device_init(nil, device)
  stubs.fire_schedule(device)
  handlers.switch_on(nil, device, { component = "switch2" })
  stubs.drain(device)

  local set_at
  for i, cmd in ipairs(device.sent) do
    if cmd.cc == "Basic" and cmd.cmd == "Set" then set_at = i break end
  end
  check("a switch during the poll is sent", set_at ~= nil, true)
  check("and jumps ahead of the remaining poll commands",
    set_at ~= nil and set_at <= 4, true)
end

-- An empty or absent sequence must not start the pump, wedge it, or error.
for _, empty in ipairs({ "table", "nil" }) do
  local device = stubs.new_device()
  handlers.send_sequence_for_test(device, empty == "table" and {} or nil, "user")
  check("an empty (" .. empty .. ") sequence sends nothing", #device.sent, 0)
  handlers.refresh(nil, device, { component = "main" })
  check("and the queue still works afterwards (" .. empty .. ")", #device.sent, 19)
end

-------------------------------------------------------------------------------
-- capability probes: asking the device instead of assuming
-------------------------------------------------------------------------------

do
  local device = stubs.new_device()
  handlers.configure(nil, device)

  local supported = stubs.sent_matching(device, "Meter", "SupportedGet")
  check("configure asks what the meter supports", #supported, 1)
  check("the supported query goes to the root", stubs.channel_of(supported[1]), 0)

  local versions = stubs.sent_matching(device, "Version", "CommandClassGet")
  check("configure asks which METER version the device speaks", #versions, 1)
  check("the version query names METER",
    versions[1].args.requested_command_class, handlers.cc.METER)

  -- The always-on sockets are no longer probed here. They answered on
  -- on hardware, they have components of their own, and the refresh covers
  -- them like any other meter -- which is asserted in the refresh tests.
  local probed = {}
  for _, cmd in ipairs(stubs.sent_matching(device, "Meter", "Get")) do
    probed[stubs.channel_of(cmd)] = true
  end
  check("configure's closing refresh still reaches always-on endpoint 1",
    probed[1], true)
  check("configure's closing refresh still reaches always-on endpoint 2",
    probed[2], true)
end

-- The always-on sockets are metered but not switchable, so a refresh asks
-- them for readings and never for switch state.
do
  local device = stubs.new_device()
  handlers.refresh(nil, device, { component = "main" })

  local switch_channels = {}
  for _, cmd in ipairs(stubs.sent_matching(device, "SwitchBinary", "Get")) do
    switch_channels[stubs.channel_of(cmd)] = true
  end
  -- Channels 1 and 2 DO appear here, but as switch endpoints for outlets 1
  -- and 2 -- the overlap that makes this device what it is. What must not
  -- happen is a switch Get aimed at an always-on socket as such, and there is
  -- no such thing: the always-on sockets have no switch endpoint at all.
  check("refresh reads four outlet switch endpoints plus the strip",
    (switch_channels[0] and switch_channels[1] and switch_channels[2]
      and switch_channels[3] and switch_channels[4]) == true, true)
  check("and nothing beyond them", switch_channels[5], nil)

  local always_on_meters = 0
  for _, cmd in ipairs(stubs.sent_matching(device, "Meter", "Get")) do
    local ch = stubs.channel_of(cmd)
    if ch == 1 or ch == 2 then always_on_meters = always_on_meters + 1 end
  end
  check("each always-on socket is asked for power and energy",
    always_on_meters, 4)
end

-- scale_supported is a BITMASK, not a list. Reading it as anything else is
-- the failure this decoding exists to avoid.
do
  local device = stubs.new_device()
  -- kWh (bit 0) + WATTS (bit 2)
  handlers.meter_supported_report(nil, device,
    { args = { scale_supported = 0x05, meter_type = 1, meter_reset = true } })
  check("the mask is recorded", device.fields[handlers.METER_SCALES_FIELD], 0x05)
  check("supported scales are logged", #stubs.infos, 1)
  check("WATTS present means no warning", #stubs.warnings, 0)
  local logged = stubs.infos[1] or ""
  check("the log names kWh", logged:find("kWh", 1, true) ~= nil, true)
  check("the log names W", logged:find("W", 1, true) ~= nil, true)
end

-- The case that would mean this driver's whole purpose cannot be served.
do
  local device = stubs.new_device()
  -- kWh + kVAh only: exactly what upstream asks for, and no watts.
  handlers.meter_supported_report(nil, device, { args = { scale_supported = 0x03 } })
  check("a meter with no WATTS warns loudly", #stubs.warnings, 1)
end

-- Volts and amps would make voltageMeasurement / currentMeasurement free.
do
  local device = stubs.new_device()
  -- WATTS (2) + VOLTS (4) + AMPERES (5)
  handlers.meter_supported_report(nil, device, { args = { scale_supported = 0x34 } })
  local logged = stubs.infos[1] or ""
  check("volts and amps are reported when present",
    logged:find("W, V, A", 1, true) ~= nil, true)
end

do
  local device = stubs.new_device()
  handlers.meter_supported_report(nil, device, { args = {} })
  check("an empty report does not error", #stubs.infos, 1)
  check("an empty report warns about WATTS", #stubs.warnings, 1)
end

-- Meter:Get's scale argument is a v2+ concept. On a v1 meter the driver's
-- scale-specific requests are meaningless, which would be a silent cause of
-- per-outlet power never arriving.
do
  local device = stubs.new_device()
  handlers.version_command_class_report(nil, device,
    { args = { requested_command_class = handlers.cc.METER, command_class_version = 3 } })
  check("the meter version is recorded", device.fields[handlers.METER_VERSION_FIELD], 3)
  check("v3 does not warn", #stubs.warnings, 0)
end

do
  local device = stubs.new_device()
  handlers.version_command_class_report(nil, device,
    { args = { requested_command_class = handlers.cc.METER, command_class_version = 1 } })
  check("a v1 meter warns that scales may be ignored", #stubs.warnings, 1)
  check("the v1 version is still recorded", device.fields[handlers.METER_VERSION_FIELD], 1)
end

do
  local device = stubs.new_device()
  handlers.version_command_class_report(nil, device,
    { args = { requested_command_class = 0x25, command_class_version = 1 } })
  check("another command class does not touch the meter field",
    device.fields[handlers.METER_VERSION_FIELD], nil)
  check("another command class is still logged", #stubs.infos, 1)
end

-------------------------------------------------------------------------------
-- powerConsumptionReport
--
-- SmartThings Energy reads this, not energyMeter. Time is controlled here
-- because every assertion is about a window.
-------------------------------------------------------------------------------

local real_os_time = os.time
local now = 0
os.time = function() return now end

local function pcr_events(device)
  local out = {}
  for _, emitted in ipairs(device.emitted) do
    if emitted.event.cap == "powerConsumptionReport" then
      out[#out + 1] = emitted
    end
  end
  return out
end

local GATE = handlers.PCR_MINIMUM_INTERVAL

-- The first reading has no window to measure against.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1.0))
  check("the first kWh emits energy only", #device.emitted, 1)
  check("the first kWh emits no consumption report", #pcr_events(device), 0)
  check("but it does open a window",
    device.fields[handlers.PCR_LAST_TIME_FIELD .. "switch1"], 1000)
end

-- Inside the window, nothing is emitted.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1.0))
  now = 1000 + 60
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1.1))
  check("no consumption report inside the window", #pcr_events(device), 0)
  check("energy is still emitted every time", #device.emitted, 2)
end

-- Past the gate, a report with the window laid end to end.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1.0))
  now = 1000 + GATE
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1.024))

  local reports = pcr_events(device)
  check("a consumption report is emitted past the gate", #reports, 1)
  check("on the outlet the meter endpoint belongs to", reports[1].component, "switch1")
  check("energy is converted to watt-hours", reports[1].event.energy, 1024)
  -- THE FIRST WINDOW IS REAL CONSUMPTION, not zero. It is measured against
  -- the reading that opened the window, because there is no previous report
  -- to measure against; without that baseline the first nine minutes of
  -- every component -- on install, and after every reset -- are silently
  -- thrown away.
  check("the first window carries its actual consumption",
    reports[1].event.deltaEnergy, 24)
  check("the window starts where the previous one ended",
    reports[1].event.start, os.date("!%Y-%m-%dT%TZ", 1000))
  check("and ends a second short of now, so windows cannot overlap",
    reports[1].event["end"], os.date("!%Y-%m-%dT%TZ", 1000 + GATE - 1))
end

-- A component whose very first reading is already a large lifetime total
-- must not report that total as consumption -- the baseline is the reading
-- itself, so the first window measures only what accrued after it.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1500.000))
  now = 1000 + GATE
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1500.020))

  local reports = pcr_events(device)
  check("a large lifetime total is not reported as consumption",
    reports[1].event.deltaEnergy, 20)
  check("while the running total is still the truth",
    reports[1].event.energy, 1500020)
  check("and nothing is logged as a discontinuity", #stubs.warnings, 0)
end

-- The delta is the difference between consecutive reports. Values here are
-- physically realistic on purpose -- 20 Wh over nine minutes is about 130 W,
-- which is what a PC on one outlet actually looks like. Unrealistic numbers
-- would trip the discontinuity clamp below and prove nothing.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1.000))
  now = 1000 + GATE
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1.010))
  now = 1000 + GATE * 2
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1.030))

  local reports = pcr_events(device)
  check("two consumption reports", #reports, 2)
  check("the second carries the running total", reports[2].event.energy, 1030)
  check("and a delta of the difference", reports[2].event.deltaEnergy, 20)
  check("the second window starts where the first ended",
    reports[2].event.start, os.date("!%Y-%m-%dT%TZ", 1000 + GATE))
end

-------------------------------------------------------------------------------
-- the discontinuity clamp
--
-- Observed on hardware: a strip reported a near-zero lifetime figure and then
-- its true accumulated total, thousands of kWh higher, between two readings.
-- Without a clamp the next window claims all of it as nine minutes of
-- consumption, which is what an energy-spike alarm downstream would fire on.
-------------------------------------------------------------------------------

do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 0.280))
  now = 1000 + GATE
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 0.280))
  now = 1000 + GATE * 2
  -- A jump of the shape actually seen on hardware.
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 2500.000))

  local reports = pcr_events(device)
  check("the window is still reported", #reports, 2)
  check("with the true running total", reports[2].event.energy, 2500000)
  check("but NOT as consumption", reports[2].event.deltaEnergy, 0.0)
  check("and the discontinuity is logged", #stubs.warnings, 1)
end

-- A delta inside what the hardware could physically draw is left alone.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 1.000))
  now = 1000 + GATE
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 1.000))
  now = 1000 + GATE * 2
  -- 1875 W for GATE seconds is the ceiling; stay just under it.
  local ceiling_kwh = 1.0 + (1875 * GATE / 3600) / 1000
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, ceiling_kwh - 0.001))

  local reports = pcr_events(device)
  check("a plausible delta passes through",
    reports[2].event.deltaEnergy > 0, true)
  check("and nothing is logged", #stubs.warnings, 0)
end

-- A fixed ceiling would pass every test above, because the spike it has to
-- catch is enormous. This is the case that separates them: 1 kWh in nine
-- minutes is 6.7 kW, impossible through a 1875 W strip, but well under the
-- strip's rating taken as a flat number. Only a time-scaled ceiling rejects
-- it.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 1.000))
  now = 1000 + GATE
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 1.000))
  now = 1000 + GATE * 2
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 2.000))

  local reports = pcr_events(device)
  check("an impossible rate is clamped even when the total looks modest",
    reports[2].event.deltaEnergy, 0.0)
  check("and logged as a discontinuity", #stubs.warnings, 1)
end

-- The clamp must not swallow a genuine reading just because the window is
-- short: the ceiling scales with elapsed time, it is not a fixed number.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 1.000))
  now = 1000 + GATE * 10
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 1.000))
  now = 1000 + GATE * 20
  -- 90 minutes at ~500 W is 750 Wh -- far above the nine-minute ceiling of
  -- 281 Wh, and entirely legitimate over this window.
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 1.750))

  local reports = pcr_events(device)
  check("a long window allows a proportionally larger delta",
    reports[2].event.deltaEnergy, 750)
  check("and is not logged as a discontinuity", #stubs.warnings, 0)
end

-- resetEnergyMeter sends the running total backwards. A negative delta would
-- be read as generation.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 5.0))
  now = 1000 + GATE
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 5.0))
  now = 1000 + GATE * 2
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 0.0))

  local reports = pcr_events(device)
  check("a reset does not produce a negative delta", reports[2].event.deltaEnergy, 0.0)
  check("and reports the reset total", reports[2].event.energy, 0)
end

-- Each component keeps its own window; one outlet reporting must not gate
-- another.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 1.0))
  handlers.meter_report(nil, device, meter_report(0, SCALE_KWH, 9.0))
  check("outlet 1 has its own window",
    device.fields[handlers.PCR_LAST_TIME_FIELD .. "switch1"], 1000)
  check("the strip has its own window",
    device.fields[handlers.PCR_LAST_TIME_FIELD .. "main"], 1000)

  now = 1000 + GATE
  handlers.meter_report(nil, device, meter_report(3, SCALE_KWH, 2.0))
  local reports = pcr_events(device)
  check("only the component that reported emits", #reports, 1)
  check("and it is the right one", reports[1].component, "switch1")
end

-- Only real energy drives this. Watts are instantaneous and kVAh is apparent
-- energy, which is not what the platform totals.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(3, SCALE_WATTS, 40))
  now = 1000 + GATE * 2
  handlers.meter_report(nil, device, meter_report(3, SCALE_WATTS, 45))
  check("watts never produce a consumption report", #pcr_events(device), 0)
end

do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(4, SCALE_KVAH, 3.0))
  now = 1000 + GATE * 2
  handlers.meter_report(nil, device, meter_report(4, SCALE_KVAH, 4.0))
  check("kVAh never produces a consumption report", #pcr_events(device), 0)
end

-- A dropped meter report must not open a window for a component that is not
-- going to receive one.
do
  local device = stubs.new_device()
  now = 1000
  handlers.meter_report(nil, device, meter_report(1, SCALE_KWH, 1.0))
  check("a dropped report opens no window",
    device.fields[handlers.PCR_LAST_TIME_FIELD .. "main"], nil)
end

os.time = real_os_time

-------------------------------------------------------------------------------
-- preferences
-------------------------------------------------------------------------------

local function changed_from(old)
  return { old_st_store = { preferences = old or {} } }
end

do
  local device = stubs.new_device({ group2Time = 30 })
  handlers.info_changed(nil, device, nil, changed_from({ group2Time = 90 }))

  local sets = stubs.sent_matching(device, "Configuration", "Set")
  check("a changed preference is sent", #sets, 1)
  check("to the parameter it maps to", sets[1].args.parameter_number, 112)
  check("with the new value", sets[1].args.configuration_value, 30)
  check("with the parameter's size", sets[1].args.size, 4)

  local gets = stubs.sent_matching(device, "Configuration", "Get")
  check("and read back, as configure does", #gets, 1)
  check("reading back the same parameter", gets[1].args.parameter_number, 112)
end

do
  local device = stubs.new_device({ group2Time = 90 })
  handlers.info_changed(nil, device, nil, changed_from({ group2Time = 90 }))
  check("an unchanged preference sends nothing", #device.sent, 0)
end

-- One threshold preference drives its whole group, because which parameter
-- governs which outlet has never been established.
do
  local device = stubs.new_device({ absoluteThreshold = 20 })
  handlers.info_changed(nil, device, nil, changed_from({ absoluteThreshold = 5 }))

  local sets = stubs.sent_matching(device, "Configuration", "Set")
  check("a threshold change sets all five parameters", #sets, 5)
  local values = {}
  for _, cmd in ipairs(sets) do
    values[cmd.args.parameter_number] = cmd.args.configuration_value
  end
  for _, number in ipairs({ 5, 8, 9, 10, 11 }) do
    check("parameter " .. number .. " takes the new threshold", values[number], 20)
  end
  check("and all five are read back",
    #stubs.sent_matching(device, "Configuration", "Get"), 5)
  check("a preference change is staggered like everything else",
    #device.delays, #device.sent)
end

-- Every Set must precede every read-back, or the read-back returns the old
-- value and reports a failure that did not happen.
do
  local device = stubs.new_device({ absoluteThreshold = 20 })
  handlers.info_changed(nil, device, nil, changed_from({ absoluteThreshold = 5 }))
  local last_set, first_get = 0, math.huge
  for i, cmd in ipairs(device.sent) do
    if cmd.cmd == "Set" then last_set = i end
    if cmd.cmd == "Get" and i < first_get then first_get = i end
  end
  check("all sets precede all read-backs", last_set < first_get, true)
end

-- Configure reads the preferences itself, so a change arriving mid-configure
-- must not start a second interleaved sequence.
do
  local device = stubs.new_device({ group2Time = 30 })
  device.fields[handlers.CONFIGURING_FIELD] = true
  handlers.info_changed(nil, device, nil, changed_from({ group2Time = 90 }))
  check("a preference change during configure sends nothing", #device.sent, 0)
  check("and says why", #stubs.infos, 1)
end

do
  local device = stubs.new_device({ group2Time = "never" })
  handlers.info_changed(nil, device, nil, changed_from({ group2Time = 90 }))
  check("an unusable preference sends nothing", #device.sent, 0)
  check("an unusable preference warns", #stubs.warnings, 1)
end

do
  local device = stubs.new_device({})
  handlers.info_changed(nil, device, nil, changed_from({}))
  check("no preferences at all sends nothing", #device.sent, 0)
end

-- THE ONE THAT MATTERS: a driver switch must not silently revert tuning.
-- configure() re-sends every parameter, so if it used the shipped defaults it
-- would undo the user's settings every time the driver was switched.
do
  local device = stubs.new_device({ group2Time = 45, absoluteThreshold = 12 })
  handlers.configure(nil, device)

  local values = {}
  for _, cmd in ipairs(stubs.sent_matching(device, "Configuration", "Set")) do
    values[cmd.args.parameter_number] = cmd.args.configuration_value
  end
  check("configure sends the preference for 112", values[112], 45)
  check("configure sends the preference for 8", values[8], 12)
  check("configure leaves untunable parameters alone", values[102], 30976)
  check("configure still sends every parameter",
    #stubs.sent_matching(device, "Configuration", "Set"), #configuration.PARAMETERS)
end

-- ...and the read-back must expect the tuned value, or it warns "did not
-- take" on every parameter the user set.
do
  local device = stubs.new_device({ group2Time = 45 })
  handlers.configuration_report(nil, device,
    { args = { parameter_number = 112, configuration_value = 45 } })
  check("a read-back matching the preference does not warn", #stubs.warnings, 0)
end

do
  local device = stubs.new_device({ group2Time = 45 })
  handlers.configuration_report(nil, device,
    { args = { parameter_number = 112, configuration_value = 90 } })
  check("a read-back still showing the old default warns", #stubs.warnings, 1)
end

-------------------------------------------------------------------------------
-- poll fallback
-------------------------------------------------------------------------------

do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.device_init(nil, device)

  check("init schedules a poll", #device.schedules, 1)
  check("at the poll interval", device.schedules[1].interval, handlers.POLL_INTERVAL)
  check("and keeps the timer", device.fields[handlers.POLL_TIMER_FIELD],
    device.schedules[1])
  check("scheduling alone sends nothing", #device.sent, 0)
end

do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.device_init(nil, device)
  stubs.fire_schedule(device)

  check("a poll tick refreshes everything", #device.sent, 19)
  local watt_channels = {}
  for _, cmd in ipairs(stubs.sent_matching(device, "Meter", "Get")) do
    if cmd.args.scale == SCALE_WATTS then
      watt_channels[stubs.channel_of(cmd)] = true
    end
  end
  for _, channel in ipairs({ 0, 3, 4, 5, 6 }) do
    check("the poll asks endpoint " .. channel .. " for watts",
      watt_channels[channel], true)
  end
end

-- init runs on every driver start. Creating a second interval without
-- cancelling the first would double the traffic each time.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.device_init(nil, device)
  local first = device.schedules[1]
  handlers.device_init(nil, device)

  check("a second init cancels the first timer", #device.cancelled, 1)
  check("cancelling the one it created", device.cancelled[1], first)
  check("two timers were created", #device.schedules, 2)
  check("but only the newest is kept",
    device.fields[handlers.POLL_TIMER_FIELD], device.schedules[2])
end

-------------------------------------------------------------------------------
-- refreshes do not interleave
--
-- A main refresh is 15 commands over ~14 s, and there are four ways to start
-- one: the app, an automation, a per-outlet refresh button, and the poll. Two
-- at once puts two commands a second on the strip, which is the thing the
-- stagger exists to prevent.
-------------------------------------------------------------------------------

do
  local device = stubs.new_device()
  device.fields[handlers.REFRESHING_FIELD] = true
  handlers.refresh(nil, device, { component = "main" })
  check("a refresh during a refresh sends nothing", #device.sent, 0)
  check("and is queued rather than dropped",
    device.fields[handlers.REFRESH_PENDING_FIELD], true)
  check("and says so", #stubs.infos, 1)
end

-- A refresh must not interleave with configure either -- 35 commands is the
-- worst case to land in the middle of.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURING_FIELD] = true
  handlers.refresh(nil, device, { component = "main" })
  check("a refresh during configure sends nothing", #device.sent, 0)
  check("and is queued", device.fields[handlers.REFRESH_PENDING_FIELD], true)
end

-- Per-outlet refreshes are guarded too: the profile declares the capability
-- on all five components, so there are four more ways in than there were.
do
  local device = stubs.new_device()
  device.fields[handlers.REFRESHING_FIELD] = true
  handlers.refresh(nil, device, { component = "switch2" })
  check("a per-outlet refresh during a refresh sends nothing", #device.sent, 0)
  check("and is queued", device.fields[handlers.REFRESH_PENDING_FIELD], true)
end

-- The guard is released when the sequence finishes, so the next one runs.
do
  local device = stubs.new_device()
  handlers.refresh(nil, device, { component = "main" })
  check("the guard is released when the sequence ends",
    device.fields[handlers.REFRESHING_FIELD], nil)
  local first = #device.sent
  handlers.refresh(nil, device, { component = "main" })
  check("so a later refresh still runs", #device.sent, first * 2)
end

-- A queued request is honoured, not forgotten. The stub runs every step
-- immediately, so the closing step sees the flag set here and repeats.
do
  local device = stubs.new_device()
  device.fields[handlers.REFRESH_PENDING_FIELD] = true
  handlers.refresh(nil, device, { component = "switch1" })
  check("a queued request is satisfied by a full refresh", #device.sent, 3 + 19)
  check("and the queue is cleared",
    device.fields[handlers.REFRESH_PENDING_FIELD], nil)
end

-- A full refresh answers every outstanding request, so it clears the queue on
-- the way in rather than repeating itself afterwards.
do
  local device = stubs.new_device()
  device.fields[handlers.REFRESH_PENDING_FIELD] = true
  handlers.refresh(nil, device, { component = "main" })
  check("a full refresh does not repeat itself", #device.sent, 19)
  check("and clears the queue",
    device.fields[handlers.REFRESH_PENDING_FIELD], nil)
end

-- The poll stands down rather than queueing: it is a backfill, and if
-- something else is talking to the strip there is nothing to back-fill.
do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.device_init(nil, device)
  device.fields[handlers.REFRESHING_FIELD] = true
  stubs.fire_schedule(device)
  check("a poll during a refresh sends nothing", #device.sent, 0)
  check("and does not queue a redundant one",
    device.fields[handlers.REFRESH_PENDING_FIELD], nil)
end

do
  local device = stubs.new_device()
  device.fields[handlers.CONFIGURED_FIELD] = true
  handlers.device_init(nil, device)
  device.fields[handlers.CONFIGURING_FIELD] = true
  stubs.fire_schedule(device)
  check("a poll during configure sends nothing", #device.sent, 0)
end

-- configure's own closing refresh must not be blocked by the guard it sets:
-- it clears CONFIGURING_FIELD before calling refresh.
do
  local device = stubs.new_device()
  handlers.configure(nil, device)
  check("configure still ends with a refresh",
    #stubs.sent_matching(device, "Meter", "Get") > 0, true)
  check("and leaves nothing queued",
    device.fields[handlers.REFRESH_PENDING_FIELD], nil)
end

-- The poll exists to backfill when unsolicited reports are dead, so it must
-- arrive in time to keep SmartThings Energy fed. A report is only emitted on
-- the first reading past the gate, so the gate has to be shorter than the
-- poll period or the effective cadence doubles.
check("the consumption gate is shorter than the poll period",
  handlers.PCR_MINIMUM_INTERVAL < handlers.POLL_INTERVAL, true)
check("so poll-driven reports stay inside SmartThings' 15 minute window",
  handlers.POLL_INTERVAL <= 15 * 60, true)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
