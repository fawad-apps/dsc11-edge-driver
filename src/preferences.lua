-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0 (the "License"); you may not
-- use this file except in compliance with the License. You may obtain a copy
-- of the License at: http://www.apache.org/licenses/LICENSE-2.0

--[[
  Device preferences -> DSC11 configuration parameters.

  WHY ONE PREFERENCE CAN DRIVE SEVERAL PARAMETERS

  The strip has five absolute-change thresholds (5, 8, 9, 10, 11) and five
  percentage thresholds (12, 15, 16, 17, 18) -- five of each for four outlets
  plus the strip. WHICH parameter governs which outlet is not established.
  configuration.lua deliberately refuses to document the bit meanings of
  101/102 for the same reason, and the profile refuses to label the outlet
  components until a known load has been measured in each socket.

  A preference labelled "Outlet 1 reporting threshold" pointing at parameter 8
  would encode exactly the mapping this codebase has twice refused to guess.
  So each threshold preference drives its whole group, which is also what the
  device is already configured with: SmartThings ships all five absolute
  thresholds at 5 and all five percentage thresholds at 50. Setting them as a
  group changes nothing about the current behaviour and claims nothing that
  has not been verified.

  Once a known load has been measured in each socket, splitting these into
  per-outlet preferences is a small change -- and by then it would be a
  statement of fact rather than a guess.

  The report intervals are not ambiguous: 111 is group 1's interval and 112 is
  group 2's, and group 2 is the one carrying per-outlet reports. Those are
  exposed individually, under upstream's names for them (group1Time /
  group2Time in zwave-switch's preferences.lua).

  DEFAULTS LIVE HERE

  The `default` below is the value configuration.PARAMETERS ships, and is the
  single source of truth. The `default:` in the profile YAML mirrors it and
  says so; if they ever disagree, this file wins, because this is what
  configure() actually sends.
]]

local preferences = {}

--- Preference id -> the parameters it drives.
--- `parameter_numbers` is a list because a threshold preference governs its
--- whole group; see the header.
preferences.MAP = {
  group1Time = {
    parameter_numbers = { 111 },
    size = 4,
    default = 900,
  },
  group2Time = {
    parameter_numbers = { 112 },
    size = 4,
    default = 90,
  },
  absoluteThreshold = {
    parameter_numbers = { 5, 8, 9, 10, 11 },
    size = 2,
    default = 5,
  },
  percentThreshold = {
    parameter_numbers = { 12, 15, 16, 17, 18 },
    size = 1,
    default = 50,
  },
}

-- Iteration order. `pairs` over MAP is unspecified, and an unspecified order
-- would mean the commands a preference change puts on the wire differ run to
-- run -- untestable, and unpleasant to read in logcat.
preferences.ORDER = {
  "group1Time",
  "group2Time",
  "absoluteThreshold",
  "percentThreshold",
}

-- parameter number -> preference id. Built once from MAP so the two cannot
-- drift apart.
local parameter_to_preference = {}
for id, entry in pairs(preferences.MAP) do
  for _, number in ipairs(entry.parameter_numbers) do
    parameter_to_preference[number] = id
  end
end

--- The preference id governing a parameter, or nil if it is not tunable.
--- @param parameter_number number
--- @return string|nil
function preferences.for_parameter(parameter_number)
  return parameter_to_preference[parameter_number]
end

--- Coerce a preference value to a number. Preferences arrive as strings from
--- the app, and booleans from a checkbox control. Mirrors upstream's
--- zwave-switch preferences.to_numeric_value.
--- @return number|nil nil when the value is not usable
function preferences.to_numeric_value(value)
  if value == nil then
    return nil
  end
  if type(value) == "boolean" then
    return value and 1 or 0
  end
  return tonumber(value)
end

--- The value a parameter should be set to for this device: the user's
--- preference when they have expressed one and it is usable, otherwise nil so
--- the caller falls back to the shipped default.
---
--- Returns nil rather than the default so callers can tell "user chose this"
--- from "nobody chose anything", which matters when deciding whether a
--- read-back mismatch is worth warning about.
--- @param device table
--- @param parameter_number number
--- @return number|nil
function preferences.value_for_parameter(device, parameter_number)
  local id = parameter_to_preference[parameter_number]
  if id == nil then
    return nil
  end
  local prefs = device and device.preferences
  if prefs == nil then
    return nil
  end
  return preferences.to_numeric_value(prefs[id])
end

return preferences
