-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0

--[[
  Tests for device preferences and the effective configuration values they
  produce.

  The behaviour worth the most attention here:

    * a preference must win over the shipped default at BOTH call sites --
      what configure() sends, and what the read-back compares against. Getting
      only the first right turns the read-back into a warning on every
      parameter the user tuned, which is how a mechanism that exists to catch
      real failures becomes noise that gets ignored.

  Run from the repo root:
      lua test/test_preferences.lua
]]

local here = (arg and arg[0] or "test/test_preferences.lua"):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;src/?.lua;" .. package.path

local preferences = require "preferences"
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

--- Effective value for one parameter, pulled out of the full list.
local function effective(device, parameter_number)
  for _, param in ipairs(configuration.effective_parameters(device)) do
    if param.parameter_number == parameter_number then
      return param.configuration_value
    end
  end
  return nil
end

local function device_with(prefs)
  return { preferences = prefs }
end

-------------------------------------------------------------------------------
-- MAP and ORDER must not drift apart
-------------------------------------------------------------------------------

do
  local in_order = {}
  for _, id in ipairs(preferences.ORDER) do
    in_order[id] = true
    check("ORDER entry '" .. id .. "' exists in MAP",
      preferences.MAP[id] ~= nil, true)
  end
  for id in pairs(preferences.MAP) do
    check("MAP entry '" .. id .. "' appears in ORDER", in_order[id] == true, true)
  end
end

-- Every parameter a preference claims must actually be one the driver ships,
-- or configure() would set something that is never read back and never
-- defaulted.
do
  local shipped = {}
  for _, param in ipairs(configuration.PARAMETERS) do
    shipped[param.parameter_number] = param
  end
  for id, entry in pairs(preferences.MAP) do
    for _, number in ipairs(entry.parameter_numbers) do
      check(string.format("preference '%s' parameter %d is shipped", id, number),
        shipped[number] ~= nil, true)
      if shipped[number] then
        check(string.format("preference '%s' parameter %d size agrees", id, number),
          entry.size, shipped[number].size)
        -- The declared default must be what the driver actually ships, or the
        -- profile YAML would advertise a default the device never receives.
        check(string.format("preference '%s' default matches shipped value for %d", id, number),
          entry.default, shipped[number].configuration_value)
      end
    end
  end
end

-------------------------------------------------------------------------------
-- parameter -> preference lookup
-------------------------------------------------------------------------------

check("parameter 111 is group1Time", preferences.for_parameter(111), "group1Time")
check("parameter 112 is group2Time", preferences.for_parameter(112), "group2Time")
for _, number in ipairs({ 5, 8, 9, 10, 11 }) do
  check("parameter " .. number .. " is absoluteThreshold",
    preferences.for_parameter(number), "absoluteThreshold")
end
for _, number in ipairs({ 12, 15, 16, 17, 18 }) do
  check("parameter " .. number .. " is percentThreshold",
    preferences.for_parameter(number), "percentThreshold")
end

-- The report-group CONTENTS are not tunable: their bit meanings were never
-- verified, so exposing them would invite a value nobody can check.
check("parameter 101 is not tunable", preferences.for_parameter(101), nil)
check("parameter 102 is not tunable", preferences.for_parameter(102), nil)
check("parameter 4 is not tunable", preferences.for_parameter(4), nil)

-------------------------------------------------------------------------------
-- numeric coercion
-------------------------------------------------------------------------------

check("string coerces", preferences.to_numeric_value("90"), 90)
check("number passes through", preferences.to_numeric_value(90), 90)
check("true is 1", preferences.to_numeric_value(true), 1)
check("false is 0", preferences.to_numeric_value(false), 0)
check("nil stays nil", preferences.to_numeric_value(nil), nil)
check("garbage is nil", preferences.to_numeric_value("soon"), nil)

-------------------------------------------------------------------------------
-- effective values: no preferences set
-------------------------------------------------------------------------------

do
  local device = device_with({})
  check("default count unchanged",
    #configuration.effective_parameters(device), #configuration.PARAMETERS)
  check("112 defaults to 90", effective(device, 112), 90)
  check("111 defaults to 900", effective(device, 111), 900)
  check("8 defaults to 5", effective(device, 8), 5)
  check("15 defaults to 50", effective(device, 15), 50)
  check("102 defaults to 30976", effective(device, 102), 30976)
end

-- A device with no preferences table at all must not error.
do
  check("nil device falls back to shipped", effective(nil, 112), 90)
  check("nil device expected_value", configuration.expected_value(nil, 112), 90)
end

-------------------------------------------------------------------------------
-- effective values: preferences win
-------------------------------------------------------------------------------

do
  local device = device_with({ group2Time = 30 })
  check("preference overrides 112", effective(device, 112), 30)
  check("111 untouched by a 112 preference", effective(device, 111), 900)
  check("read-back expects the preference, not the default",
    configuration.expected_value(device, 112), 30)
end

-- Preferences arrive from the app as strings.
do
  local device = device_with({ group2Time = "45" })
  check("string preference overrides 112", effective(device, 112), 45)
  check("string preference reaches the read-back",
    configuration.expected_value(device, 112), 45)
end

-- One threshold preference drives its whole group, because which parameter
-- governs which outlet has never been established.
do
  local device = device_with({ absoluteThreshold = 25 })
  for _, number in ipairs({ 5, 8, 9, 10, 11 }) do
    check("absoluteThreshold drives parameter " .. number, effective(device, number), 25)
  end
  for _, number in ipairs({ 12, 15, 16, 17, 18 }) do
    check("absoluteThreshold leaves percentage parameter " .. number, effective(device, number), 50)
  end
end

do
  local device = device_with({ percentThreshold = 10 })
  for _, number in ipairs({ 12, 15, 16, 17, 18 }) do
    check("percentThreshold drives parameter " .. number, effective(device, number), 10)
  end
  for _, number in ipairs({ 5, 8, 9, 10, 11 }) do
    check("percentThreshold leaves absolute parameter " .. number, effective(device, number), 5)
  end
end

-- An unusable preference must not reach the device as nil or 0.
do
  local device = device_with({ group2Time = "whenever" })
  check("unusable preference falls back to the default", effective(device, 112), 90)
end

-- Report-group contents stay fixed no matter what preferences are set.
do
  local device = device_with({
    group1Time = 60, group2Time = 30,
    absoluteThreshold = 1, percentThreshold = 5,
  })
  check("101 stays fixed", effective(device, 101), 1)
  check("102 stays fixed", effective(device, 102), 30976)
  check("4 stays fixed", effective(device, 4), 1)
  check("everything still present",
    #configuration.effective_parameters(device), #configuration.PARAMETERS)
end

-- Order must match PARAMETERS, so the wire order does not change.
do
  local device = device_with({ group2Time = 30 })
  local out = configuration.effective_parameters(device)
  local ordered = true
  for i, param in ipairs(out) do
    if param.parameter_number ~= configuration.PARAMETERS[i].parameter_number then
      ordered = false
    end
  end
  check("effective_parameters preserves order", ordered, true)
end

-- Sizes must come through untouched; a wrong size is a malformed frame.
do
  local device = device_with({ absoluteThreshold = 7, percentThreshold = 20 })
  local sizes = {}
  for _, param in ipairs(configuration.effective_parameters(device)) do
    sizes[param.parameter_number] = param.size
  end
  check("parameter 8 stays size 2", sizes[8], 2)
  check("parameter 15 stays size 1", sizes[15], 1)
  check("parameter 112 stays size 4", sizes[112], 4)
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
