-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0

--[[
  Tests for the driver template -- which handler is registered against which
  command.

  WHY THIS FILE EXISTS

  Every other test in this suite calls a handler directly, so all of them pass
  even if the handler is wired to the wrong command. Swap meter_report and
  configuration_report in the template and the behavioural suite stays green
  while the driver routes every meter reading into the configuration logger.

  The registrations are a table of command-class/command-id pairs, which is
  precisely the kind of thing that is easy to get wrong and invisible when it
  is. So they get asserted, against the same numeric command ids the real
  library uses.

  Run from the repo root:
      lua test/test_template.lua
]]

local here = (arg and arg[0] or "test/test_template.lua"):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/../src/?.lua;src/?.lua;test/?.lua;" .. package.path

require "stubs"

local capabilities = require "st.capabilities"
local handlers = require "handlers"
local template = require "driver_template"

local cc = handlers.cc
local Basic = handlers.Basic
local Configuration = handlers.Configuration
local Meter = handlers.Meter
local SwitchBinary = handlers.SwitchBinary
local Version = handlers.Version

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

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-------------------------------------------------------------------------------
-- capabilities
-------------------------------------------------------------------------------

do
  local declared = {}
  for _, capability in ipairs(template.supported_capabilities) do
    declared[capability.ID] = true
  end
  for _, id in ipairs({ "switch", "powerMeter", "energyMeter", "refresh" }) do
    check("supports " .. id, declared[id], true)
  end
  -- SmartThings Energy reads powerConsumptionReport, not energyMeter. Without
  -- it declared, the windowed reports the driver emits go nowhere.
  check("supports powerConsumptionReport", declared["powerConsumptionReport"], true)
end

-------------------------------------------------------------------------------
-- z-wave handler registrations
-------------------------------------------------------------------------------

local zw = template.zwave_handlers

-- Switch state arrives as both Basic and SwitchBinary reports, on the switch
-- endpoints. Both go to the same handler.
check("Basic:Report -> switch_report",
  zw[cc.BASIC] and zw[cc.BASIC][Basic.REPORT], handlers.switch_report)
check("SwitchBinary:Report -> switch_report",
  zw[cc.SWITCH_BINARY] and zw[cc.SWITCH_BINARY][SwitchBinary.REPORT], handlers.switch_report)

-- The one that matters most: meter traffic must reach the hand-routed meter
-- handler, because the platform's own routing would misattribute it.
check("Meter:Report -> meter_report",
  zw[cc.METER] and zw[cc.METER][Meter.REPORT], handlers.meter_report)
check("Meter:SupportedReport -> meter_supported_report",
  zw[cc.METER] and zw[cc.METER][Meter.SUPPORTED_REPORT], handlers.meter_supported_report)

check("Configuration:Report -> configuration_report",
  zw[cc.CONFIGURATION] and zw[cc.CONFIGURATION][Configuration.REPORT],
  handlers.configuration_report)

check("Version:CommandClassReport -> version_command_class_report",
  zw[cc.VERSION] and zw[cc.VERSION][Version.COMMAND_CLASS_REPORT],
  handlers.version_command_class_report)

-- Meter's two commands are distinct ids, so a report and a supported-report
-- cannot collide. Asserted because both live under the same command class and
-- a copy-paste would silently give one handler both.
check("Meter REPORT and SUPPORTED_REPORT are different commands",
  Meter.REPORT ~= Meter.SUPPORTED_REPORT, true)
check("Meter registers exactly two handlers", count(zw[cc.METER]), 2)

-- Nothing extra, and in particular nothing registered under a class it does
-- not belong to.
check("Basic registers one handler", count(zw[cc.BASIC]), 1)
check("SwitchBinary registers one handler", count(zw[cc.SWITCH_BINARY]), 1)
check("Configuration registers one handler", count(zw[cc.CONFIGURATION]), 1)
check("Version registers one handler", count(zw[cc.VERSION]), 1)
check("five command classes are handled", count(zw), 5)

-- Every registration must be callable, whatever it is bound to.
do
  local all_functions = true
  for _, commands in pairs(zw) do
    for _, handler in pairs(commands) do
      if type(handler) ~= "function" then all_functions = false end
    end
  end
  check("every z-wave handler is a function", all_functions, true)
end

-------------------------------------------------------------------------------
-- capability handler registrations
-------------------------------------------------------------------------------

local ch = template.capability_handlers

check("switch on", ch[capabilities.switch.ID]
  and ch[capabilities.switch.ID][capabilities.switch.commands.on.NAME], handlers.switch_on)
check("switch off", ch[capabilities.switch.ID]
  and ch[capabilities.switch.ID][capabilities.switch.commands.off.NAME], handlers.switch_off)
check("refresh", ch[capabilities.refresh.ID]
  and ch[capabilities.refresh.ID][capabilities.refresh.commands.refresh.NAME], handlers.refresh)
check("resetEnergyMeter", ch[capabilities.energyMeter.ID]
  and ch[capabilities.energyMeter.ID][capabilities.energyMeter.commands.resetEnergyMeter.NAME],
  handlers.reset_energy_meter)

-- The custom reset capability exists only because the app refuses to draw the
-- standard one. It must reach the SAME handler -- two buttons that behave
-- differently would be worse than one button that is missing.
do
  local custom = ch["autumnpepper05038.energyreset"]
  check("the custom reset capability is registered", custom ~= nil, true)
  check("and calls the same handler as the standard reset",
    custom and custom["resetEnergy"], handlers.reset_energy_meter)
  check("which is exactly the standard reset handler",
    ch[capabilities.energyMeter.ID][capabilities.energyMeter.commands.resetEnergyMeter.NAME],
    custom and custom["resetEnergy"])
end

-------------------------------------------------------------------------------
-- lifecycle registrations
-------------------------------------------------------------------------------

local lc = template.lifecycle_handlers

check("init", lc.init, handlers.device_init)
check("doConfigure", lc.doConfigure, handlers.configure)
-- driverSwitched is the path this device actually arrives by.
check("driverSwitched", lc.driverSwitched, handlers.driver_switched)
-- Without infoChanged a preference change is accepted by the app and never
-- reaches the device.
check("infoChanged", lc.infoChanged, handlers.info_changed)

-- Deliberately absent: init already configures a device that has no record of
-- being configured, and configure ends by refreshing. An `added` refresh adds
-- nothing but 15 commands interleaved with configure's 34. The count is what
-- actually catches a re-added handler -- comparing lc.added against a
-- handler that no longer exists is nil == nil, which passes either way.
check("no added handler is registered", lc.added, nil)
check("exactly four lifecycle handlers", count(lc), 4)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
