-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0

--[[
  Tests for the DSC11 dual endpoint mapping.

  Plain Lua on purpose -- no SmartThings test harness, no mocked Z-Wave --
  because the thing most likely to be wrong in this driver is arithmetic that
  needs no hub to check. Run from the repo root:

      lua test/test_endpoints.lua

  The mapping under test:
      outlet N (1..4)   switch endpoint = N       (1..4)
                        meter  endpoint = N + 2   (3..6)
]]

-- Resolve src/ relative to this file so the test runs from anywhere.
local here = (arg and arg[0] or "test/test_endpoints.lua"):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;src/?.lua;" .. package.path

-- endpoints.lua logs on unexpected input; stub it out.
local warnings = {}
package.loaded["log"] = {
  warn = function(msg) warnings[#warnings + 1] = msg end,
  info = function() end,
  debug = function() end,
  error = function() end,
  trace = function() end,
}

local endpoints = require "endpoints"

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

local function check_list(name, actual, expected)
  local ok = type(actual) == "table" and #actual == #expected
  if ok then
    for i = 1, #expected do
      if actual[i] ~= expected[i] then ok = false break end
    end
  end
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    local function show(t)
      if type(t) ~= "table" then return tostring(t) end
      return "{" .. table.concat(t, ",") .. "}"
    end
    print(string.format("FAIL  %s\n        expected %s, got %s",
      name, show(expected), show(actual)))
  end
end

-- Switch endpoints are not offset.
for outlet = 1, 4 do
  check("switch_endpoint(" .. outlet .. ")", endpoints.switch_endpoint(outlet), outlet)
end

-- Meter endpoints are offset by two.
check("meter_endpoint(1)", endpoints.meter_endpoint(1), 3)
check("meter_endpoint(2)", endpoints.meter_endpoint(2), 4)
check("meter_endpoint(3)", endpoints.meter_endpoint(3), 5)
check("meter_endpoint(4)", endpoints.meter_endpoint(4), 6)

check("component_for_outlet(1)", endpoints.component_for_outlet(1), "switch1")
check("component_for_outlet(4)", endpoints.component_for_outlet(4), "switch4")

-- Switch reports arrive on 1..4.
for channel = 1, 4 do
  check("outlet_for_switch_channel(" .. channel .. ")",
    endpoints.outlet_for_switch_channel(channel), channel)
end
check("outlet_for_switch_channel(0)", endpoints.outlet_for_switch_channel(0), nil)
check("outlet_for_switch_channel(5)", endpoints.outlet_for_switch_channel(5), nil)
check("outlet_for_switch_channel(6)", endpoints.outlet_for_switch_channel(6), nil)

-- Meter reports arrive on 3..6. THIS IS THE REGRESSION THAT MATTERS: a meter
-- report on channel 3 belongs to outlet 1, not outlet 3. Route it through the
-- component map instead and outlet 1's power is attributed to outlet 3.
check("outlet_for_meter_channel(3) is outlet 1", endpoints.outlet_for_meter_channel(3), 1)
check("outlet_for_meter_channel(4) is outlet 2", endpoints.outlet_for_meter_channel(4), 2)
check("outlet_for_meter_channel(5) is outlet 3", endpoints.outlet_for_meter_channel(5), 3)
check("outlet_for_meter_channel(6) is outlet 4", endpoints.outlet_for_meter_channel(6), 4)

-- Channels 1 and 2 are not OUTLETS; they are the two always-on sockets.
check("outlet_for_meter_channel(1) rejected", endpoints.outlet_for_meter_channel(1), nil)
check("outlet_for_meter_channel(2) rejected", endpoints.outlet_for_meter_channel(2), nil)
check("outlet_for_meter_channel(7) rejected", endpoints.outlet_for_meter_channel(7), nil)

-- THE ALWAYS-ON SOCKETS. Confirmed on hardware: the strip meters all six
-- sockets, the always-on pair on meter endpoints 1 and 2. That is not a
-- separate quirk -- it is the reason the switchable four start at 3.
check("always_on_for_meter_channel(1) is socket 1", endpoints.always_on_for_meter_channel(1), 1)
check("always_on_for_meter_channel(2) is socket 2", endpoints.always_on_for_meter_channel(2), 2)
check("always_on_for_meter_channel(3) is not always-on", endpoints.always_on_for_meter_channel(3), nil)
check("always_on_for_meter_channel(0) rejected", endpoints.always_on_for_meter_channel(0), nil)
check("always_on_meter_endpoint(1)", endpoints.always_on_meter_endpoint(1), 1)
check("always_on_meter_endpoint(2)", endpoints.always_on_meter_endpoint(2), 2)
check("component_for_always_on(1)", endpoints.component_for_always_on(1), "alwaysOn1")
check("component_for_always_on(2)", endpoints.component_for_always_on(2), "alwaysOn2")

-- The offset IS the always-on count. If these ever disagree the mapping is
-- broken in a way no individual assertion above would catch.
check("METER_OFFSET equals the always-on socket count",
  endpoints.METER_OFFSET, endpoints.ALWAYS_ON_COUNT)

-- Every meter channel 1..6 belongs to exactly one component, and the two
-- ranges do not overlap.
for channel = 1, 6 do
  local outlet = endpoints.outlet_for_meter_channel(channel)
  local always_on = endpoints.always_on_for_meter_channel(channel)
  check(string.format("meter channel %d belongs to exactly one thing", channel),
    (outlet ~= nil) ~= (always_on ~= nil), true)
end

-- The two mappings must genuinely disagree for outlets 1 and 2, and overlap
-- on endpoints 3 and 4. That overlap is why a single map cannot work.
check("endpoint 3 is outlet 3's switch", endpoints.outlet_for_switch_channel(3), 3)
check("endpoint 3 is outlet 1's meter", endpoints.outlet_for_meter_channel(3), 1)
check("endpoint 4 is outlet 4's switch", endpoints.outlet_for_switch_channel(4), 4)
check("endpoint 4 is outlet 2's meter", endpoints.outlet_for_meter_channel(4), 2)

-- component_to_endpoint carries the SWITCH convention only.
check_list("component_to_endpoint(main) is root", endpoints.component_to_endpoint(nil, "main"), {})
check_list("component_to_endpoint(switch1)", endpoints.component_to_endpoint(nil, "switch1"), { 1 })
check_list("component_to_endpoint(switch4)", endpoints.component_to_endpoint(nil, "switch4"), { 4 })
check_list("component_to_endpoint(switch9) rejected", endpoints.component_to_endpoint(nil, "switch9"), {})
check_list("component_to_endpoint(nonsense) rejected", endpoints.component_to_endpoint(nil, "bogus"), {})

-- endpoint_to_component, also switch convention.
local fake_device = {
  profile = {
    components = {
      main = {}, switch1 = {}, switch2 = {}, switch3 = {}, switch4 = {},
      alwaysOn1 = {}, alwaysOn2 = {},
    },
  },
}
check("endpoint_to_component(0)", endpoints.endpoint_to_component(fake_device, 0), "main")
check("endpoint_to_component(1)", endpoints.endpoint_to_component(fake_device, 1), "switch1")
check("endpoint_to_component(4)", endpoints.endpoint_to_component(fake_device, 4), "switch4")
check("endpoint_to_component(5) falls back", endpoints.endpoint_to_component(fake_device, 5), "main")

-- Bad component ids should have been logged, not swallowed.
check("bad component ids logged", #warnings >= 2, true)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
