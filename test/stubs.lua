-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0

--[[
  Minimal stand-ins for the SmartThings Lua libraries, so handlers.lua can be
  exercised without a hub.

  Command constructors return a plain descriptor instead of an encoded frame,
  which is what makes assertions here readable: a test can say "a Meter:Get for
  WATTS went to dst_channels {3}" directly.

  device.thread:call_with_delay runs its function immediately but RECORDS the
  delay it was given. send_sequence schedules step i at (i-1) * interval and
  is iterated in order, so running each one on the spot preserves ordering
  while removing the waiting -- and keeping the delays lets a test assert that
  commands are actually staggered, which is otherwise invisible here.

  call_on_schedule, by contrast, does not run its callback at all: it is
  periodic, and a test that wants a tick asks for one via stubs.fire_schedule.
]]

local stubs = {}

stubs.warnings = {}
stubs.infos = {}

local function reset_logs()
  stubs.warnings = {}
  stubs.infos = {}
end

-- log ------------------------------------------------------------------------
package.loaded["log"] = {
  warn = function(msg) stubs.warnings[#stubs.warnings + 1] = tostring(msg) end,
  info = function(msg) stubs.infos[#stubs.infos + 1] = tostring(msg) end,
  debug = function() end,
  error = function() end,
  trace = function() end,
}

-- st.utils -------------------------------------------------------------------
package.loaded["st.utils"] = {
  round = function(v)
    if v >= 0 then return math.floor(v + 0.5) end
    return -math.floor(-v + 0.5)
  end,
}

-- st.capabilities ------------------------------------------------------------
-- `state_value` is what the real device:get_latest_state returns: the
-- attribute's VALUE, not the event. For a simple attribute that is the number
-- or string; for a composite one like powerConsumption it is the whole table.
-- Recorded separately from the flattened fields, which exist only to keep
-- assertions readable.
local function attribute_event(cap, attr)
  return function(arg)
    if type(arg) == "table" then
      return { cap = cap, attr = attr, value = arg.value, unit = arg.unit,
               state_value = arg.value }
    end
    return { cap = cap, attr = attr, value = arg, state_value = arg }
  end
end

package.loaded["st.capabilities"] = {
  switch = {
    ID = "switch",
    switch = {
      NAME = "switch",
      on = function()
        return { cap = "switch", attr = "switch", value = "on", state_value = "on" }
      end,
      off = function()
        return { cap = "switch", attr = "switch", value = "off", state_value = "off" }
      end,
    },
    commands = {
      on = { NAME = "on" },
      off = { NAME = "off" },
    },
  },
  powerMeter = {
    ID = "powerMeter",
    power = attribute_event("powerMeter", "power"),
  },
  energyMeter = {
    ID = "energyMeter",
    energy = attribute_event("energyMeter", "energy"),
    commands = { resetEnergyMeter = { NAME = "resetEnergyMeter" } },
  },
  powerConsumptionReport = {
    ID = "powerConsumptionReport",
    -- Callable AND indexable: handlers.lua both calls this to build an event
    -- and reads `.NAME` off it to look up the previous report in device
    -- state. A plain function cannot carry a field in Lua.
    powerConsumption = setmetatable({ NAME = "powerConsumption" }, {
      __call = function(_, arg)
        local value = {
          start = arg.start,
          ["end"] = arg["end"],
          energy = arg.energy,
          deltaEnergy = arg.deltaEnergy,
        }
        return {
          cap = "powerConsumptionReport",
          attr = "powerConsumption",
          state_value = value,
          start = value.start,
          ["end"] = value["end"],
          energy = value.energy,
          deltaEnergy = value.deltaEnergy,
        }
      end,
    }),
  },
  refresh = {
    ID = "refresh",
    commands = { refresh = { NAME = "refresh" } },
  },
}

-- Custom capabilities are addressed by "namespace.id" and created on demand,
-- the way st.capabilities resolves them on a hub.
setmetatable(package.loaded["st.capabilities"], {
  __index = function(t, id)
    if type(id) ~= "string" or not id:find("%.") then return nil end
    local cap = {
      ID = id,
      lastReset = setmetatable({ NAME = "lastReset" }, {
        __call = function(_, value)
          return { cap = id, attr = "lastReset", value = value, state_value = value }
        end,
      }),
    }
    rawset(t, id, cap)
    return cap
  end,
})

-- st.zwave command classes ---------------------------------------------------
package.loaded["st.zwave.CommandClass"] = {
  BASIC = 0x20,
  SWITCH_BINARY = 0x25,
  METER = 0x32,
  CONFIGURATION = 0x70,
  VERSION = 0x86,
}

--- Build a command-class module whose constructors return descriptors.
local function command_class(name, commands, extra)
  local class = { REPORT = name .. ":Report" }
  for _, command in ipairs(commands) do
    class[command] = function(_, args, opts)
      return { cc = name, cmd = command, args = args or {}, opts = opts }
    end
  end
  for k, v in pairs(extra or {}) do class[k] = v end
  return function() return class end
end

package.loaded["st.zwave.CommandClass.Basic"] = command_class("Basic", { "Set", "Get" }, {
  SET = 0x01, GET = 0x02, REPORT = 0x03,
})
package.loaded["st.zwave.CommandClass.SwitchBinary"] = command_class("SwitchBinary", { "Set", "Get" }, {
  SET = 0x01, GET = 0x02, REPORT = 0x03,
})
package.loaded["st.zwave.CommandClass.Configuration"] = command_class("Configuration", { "Set", "Get" }, {
  SET = 0x04, GET = 0x05, REPORT = 0x06,
})

-- Command ids match the real library (st/zwave/generated/*/init.lua), because
-- test_template.lua asserts the driver registers handlers against them.
package.loaded["st.zwave.CommandClass.Meter"] = command_class("Meter", { "Get", "Reset", "SupportedGet" }, {
  GET = 0x01,
  REPORT = 0x02,
  SUPPORTED_GET = 0x03,
  SUPPORTED_REPORT = 0x04,
  RESET = 0x05,
  scale = {
    electric_meter = {
      KILOWATT_HOURS = 0,
      KILOVOLT_AMPERE_HOURS = 1,
      WATTS = 2,
      PULSE_COUNT = 3,
      VOLTS = 4,
      AMPERES = 5,
      POWER_FACTOR = 6,
    },
  },
})
package.loaded["st.zwave.CommandClass.Version"] = command_class("Version", { "Get", "CommandClassGet" }, {
  GET = 0x11,
  REPORT = 0x12,
  COMMAND_CLASS_GET = 0x13,
  COMMAND_CLASS_REPORT = 0x14,
})

-- device ---------------------------------------------------------------------

--- A fake device that records everything sent and emitted.
--- @param preferences table|nil initial device preferences
--- @param opts table|nil { defer = true } to hold scheduled callbacks instead
---        of running them, so a test can observe a queue that still has items
---        in it -- which is the only way to see command PRIORITY at work.
function stubs.new_device(preferences, opts)
  local components = {}
  for _, id in ipairs({ "main", "switch1", "switch2", "switch3", "switch4",
                        "alwaysOn1", "alwaysOn2" }) do
    components[id] = { id = id }
  end

  local device = {
    profile = { components = components },
    preferences = preferences or {},
    sent = {},
    emitted = {},
    fields = {},
    -- Latest emitted event per component, keyed "<capability>.<attribute>",
    -- so get_latest_state can answer the way the platform would.
    state = {},
    -- Every delay send_sequence asked for, in the order it asked. Recorded
    -- rather than discarded so a test can assert that commands are staggered
    -- and not bursted -- one of this driver's two load-bearing design rules.
    delays = {},
    -- Periodic timers created and cancelled, for the poll fallback.
    schedules = {},
    cancelled = {},
    -- Scheduled callbacks held rather than run, when opts.defer is set.
    defer = opts and opts.defer or false,
    deferred = {},
  }

  device.thread = {
    -- Runs the function on the spot, but remembers the delay. send_sequence
    -- schedules step i at (i-1) * interval and is iterated in order, so
    -- running each immediately preserves ordering while removing the waiting.
    call_with_delay = function(_, delay, fn)
      device.delays[#device.delays + 1] = delay
      if device.defer then
        device.deferred[#device.deferred + 1] = fn
      else
        fn()
      end
    end,
    -- Does NOT run the callback: it is periodic, and a test that wants a tick
    -- invokes it through stubs.fire_schedule.
    call_on_schedule = function(_, interval, fn, name)
      local timer = { interval = interval, fn = fn, name = name }
      device.schedules[#device.schedules + 1] = timer
      return timer
    end,
    cancel_timer = function(_, timer)
      device.cancelled[#device.cancelled + 1] = timer
    end,
  }

  function device:send(cmd)
    self.sent[#self.sent + 1] = cmd
  end

  function device:emit_component_event(component, event)
    self.emitted[#self.emitted + 1] = { component = component.id, event = event }
    if event.cap and event.attr then
      local by_component = self.state[component.id]
      if by_component == nil then
        by_component = {}
        self.state[component.id] = by_component
      end
      by_component[event.cap .. "." .. event.attr] = event
    end
  end

  --- Returns the attribute's VALUE, as the real device:get_latest_state does
  --- -- not the event it came from.
  function device:get_latest_state(component_id, capability_id, attribute_name)
    local by_component = self.state[component_id]
    if by_component == nil then
      return nil
    end
    local event = by_component[capability_id .. "." .. attribute_name]
    if event == nil then
      return nil
    end
    return event.state_value
  end

  function device:set_field(name, value)
    self.fields[name] = value
  end

  function device:get_field(name)
    return self.fields[name]
  end

  function device:set_component_to_endpoint_fn() end
  function device:set_endpoint_to_component_fn() end

  reset_logs()
  return device
end

--- Run every held callback, including ones scheduled while draining -- which
--- is how the command queue advances, one pump scheduling the next.
function stubs.drain(device)
  local guard = 0
  while #device.deferred > 0 do
    guard = guard + 1
    if guard > 1000 then error("drain did not terminate") end
    local fn = table.remove(device.deferred, 1)
    fn()
  end
end

--- Run one tick of a periodic timer created via call_on_schedule.
function stubs.fire_schedule(device, index)
  local timer = device.schedules[index or 1]
  if timer == nil then
    error("no scheduled timer at index " .. tostring(index or 1))
  end
  timer.fn()
end

--- Sent commands narrowed to one command class / command name.
function stubs.sent_matching(device, cc_name, cmd_name)
  local out = {}
  for _, cmd in ipairs(device.sent) do
    if cmd.cc == cc_name and (cmd_name == nil or cmd.cmd == cmd_name) then
      out[#out + 1] = cmd
    end
  end
  return out
end

--- The single dst_channel a command was addressed to, or 0 for the root.
function stubs.channel_of(cmd)
  if cmd.opts == nil or cmd.opts.dst_channels == nil or #cmd.opts.dst_channels == 0 then
    return 0
  end
  return cmd.opts.dst_channels[1]
end

return stubs
