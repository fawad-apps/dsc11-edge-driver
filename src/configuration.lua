-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0 (the "License"); you may not
-- use this file except in compliance with the License. You may obtain a copy
-- of the License at: http://www.apache.org/licenses/LICENSE-2.0

--[[
  DSC11 configuration parameters.

  The DSC11 is pre-Z-Wave-Plus. It does not volunteer per-outlet metering
  until its report groups are configured, and it is the unsolicited reports --
  not polling -- that keep per-outlet watts fresh between refreshes.

  These values are not from memory or from the manual. They are the set
  SmartThings shipped for this exact device, in two independent places that
  agree with each other:

    * the legacy DTH's configure()
      (devicetypes/smartthings/aeon-smartstrip.src/aeon-smartstrip.groovy)
    * the Edge zwave-switch driver's configurations.lua, AEON_SMART_STRIP,
      matching mfr 0x0086 / product type 0x0003 / product id 0x000B

  Report groups:
    101 / 111  group 1 content + interval  (900 s = 15 min)
    102 / 112  group 2 content + interval  (90 s)  <- per-outlet reports
    102 = 30976 = 0x7900, matching the DTH's configurationValue [0, 0, 0x79, 0]

  Thresholds:
    5, 8, 9, 10, 11   per-outlet absolute change threshold
    12, 15, 16, 17, 18  per-outlet percentage change threshold

  The exact bit meanings of 101/102 are not documented here because they were
  not verified against the manual -- only that these are the values
  SmartThings shipped and that they produced working per-outlet reports under
  the DTH. Confirm against the DSC11 manual before changing any of them.

  PARAMETERS IS THE SHIPPED DEFAULT, NOT NECESSARILY WHAT GETS SENT

  Some of these are exposed as device preferences (see preferences.lua). Where
  the user has set one, that value wins -- at BOTH call sites:

    * effective_parameters(), which is what configure() sends;
    * expected_value(),       which is what the read-back compares against.

  Overriding only the first would make the read-back warn "did not take" on
  every parameter the user tuned, turning the one mechanism that catches real
  configuration failures into noise.
]]

local preferences = require "preferences"

local configuration = {}

configuration.PARAMETERS = {
  -- PARAMETER 4 IS UNDOCUMENTED, AND WAS SUSPECTED OF WIPING ENERGY. IT DOES
  -- NOT.
  --
  -- It is shipped as 1 by SmartThings, in both the legacy DTH and the Edge
  -- zwave-switch driver, and neither says what it does. This driver inherited
  -- it on that authority alone. It fell under suspicion because a strip was
  -- once seen reporting near-zero lifetime energy shortly after a configure,
  -- and on Aeon hardware of this era a small parameter in this range is
  -- commonly an accumulated-energy reset.
  --
  -- A controlled test settles it: with known non-zero values in the
  -- registers, a full configure was forced through driverSwitched -- sending
  -- all fifteen parameters including this one -- and every register came back
  -- unchanged. Parameter 4 does not reset accumulated energy.
  --
  -- What did cause that earlier behaviour is unknown, and is recorded as
  -- unknown rather than guessed at a second time.
  { parameter_number = 4,   size = 1, configuration_value = 1 },

  -- per-outlet absolute change thresholds
  { parameter_number = 5,   size = 2, configuration_value = 5 },
  { parameter_number = 8,   size = 2, configuration_value = 5 },
  { parameter_number = 9,   size = 2, configuration_value = 5 },
  { parameter_number = 10,  size = 2, configuration_value = 5 },
  { parameter_number = 11,  size = 2, configuration_value = 5 },

  -- per-outlet percentage change thresholds
  { parameter_number = 12,  size = 1, configuration_value = 50 },
  { parameter_number = 15,  size = 1, configuration_value = 50 },
  { parameter_number = 16,  size = 1, configuration_value = 50 },
  { parameter_number = 17,  size = 1, configuration_value = 50 },
  { parameter_number = 18,  size = 1, configuration_value = 50 },

  -- report group contents
  { parameter_number = 101, size = 4, configuration_value = 1 },
  { parameter_number = 102, size = 4, configuration_value = 30976 },

  -- report group intervals, seconds
  { parameter_number = 111, size = 4, configuration_value = 900 },
  { parameter_number = 112, size = 4, configuration_value = 90 },
}

-- Read back after configuring. A Configuration:Set is unacknowledged, so
-- without this there is no evidence any of it took -- which is how a strip
-- that reports nothing per-outlet looks identical to one that was never
-- configured. Limited to the report groups because those are the ones that
-- decide whether per-outlet data arrives at all.
configuration.READ_BACK = { 101, 102, 111, 112 }

--- The value shipped for a parameter, ignoring any preference.
--- @param parameter_number number
--- @return number|nil
local function shipped_value(parameter_number)
  for _, param in ipairs(configuration.PARAMETERS) do
    if param.parameter_number == parameter_number then
      return param.configuration_value
    end
  end
  return nil
end

--- Expected value for a parameter, for comparing against a read-back: the
--- user's preference where they set one, otherwise the shipped default.
--- @param device table|nil
--- @param parameter_number number
--- @return number|nil
function configuration.expected_value(device, parameter_number)
  local preferred = preferences.value_for_parameter(device, parameter_number)
  if preferred ~= nil then
    return preferred
  end
  return shipped_value(parameter_number)
end

--- Every parameter with preference overrides applied -- what configure()
--- actually sends. Order matches PARAMETERS so the wire order is unchanged.
--- @param device table|nil
--- @return table list of { parameter_number, size, configuration_value }
function configuration.effective_parameters(device)
  local out = {}
  for _, param in ipairs(configuration.PARAMETERS) do
    local preferred = preferences.value_for_parameter(device, param.parameter_number)
    out[#out + 1] = {
      parameter_number = param.parameter_number,
      size = param.size,
      configuration_value = preferred ~= nil and preferred or param.configuration_value,
    }
  end
  return out
end

return configuration
