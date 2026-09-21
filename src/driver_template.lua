-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0 (the "License"); you may not
-- use this file except in compliance with the License. You may obtain a copy
-- of the License at: http://www.apache.org/licenses/LICENSE-2.0

--[[
  The driver template: which handler is registered against which command.

  WHY THIS IS NOT IN init.lua

  init.lua ends with `driver:run()`, which blocks. Anything that requires it
  runs the driver, so no test can load it -- and the registrations below are
  exactly the kind of thing worth a test: every one is a command class paired
  with a command id, and swapping two of them produces a driver that passes
  every behavioural test in the suite while routing meter reports to the
  configuration handler.

  Keeping the table here lets test/test_template.lua require it without
  starting anything.

  WHY NO DEFAULT HANDLERS

  st.zwave.defaults is deliberately not registered. Every default that touches
  a METER command would be wrong on this device, because they all assume one
  component maps to one endpoint (see endpoints.lua):

    * the default refresh sends Meter:Get through send_to_component, so it
      would query switch endpoints 1..4 instead of meter endpoints 3..6;
    * the default powerMeter / energyMeter report handlers route by
      endpoint_to_component, so a report from meter endpoint 3 -- outlet 1 --
      would be attributed to component switch3.

  Registering defaults for the safe capabilities and overriding the rest would
  leave the reader guessing which of the two mappings any given event went
  through. There are only a handful of handlers, so all of them are explicit.
]]

local capabilities = require "st.capabilities"

local handlers = require "handlers"

-- The app will not draw energyMeter's own reset button: it substitutes its
-- energy card for powerMeter/energyMeter and the generic controls that belong
-- to them are never rendered. This is a button it does draw, calling the same
-- handler. See profiles/dsc11-smart-strip.yml.
local RESET_ENERGY = "autumnpepper05038.energyreset"

local Basic = handlers.Basic
local Configuration = handlers.Configuration
local Meter = handlers.Meter
local SwitchBinary = handlers.SwitchBinary
local Version = handlers.Version
local cc = handlers.cc

return {
  supported_capabilities = {
    capabilities.switch,
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.powerConsumptionReport,
    capabilities.refresh,
  },
  zwave_handlers = {
    [cc.BASIC] = {
      [Basic.REPORT] = handlers.switch_report,
    },
    [cc.SWITCH_BINARY] = {
      [SwitchBinary.REPORT] = handlers.switch_report,
    },
    [cc.METER] = {
      [Meter.REPORT] = handlers.meter_report,
      [Meter.SUPPORTED_REPORT] = handlers.meter_supported_report,
    },
    [cc.CONFIGURATION] = {
      [Configuration.REPORT] = handlers.configuration_report,
    },
    [cc.VERSION] = {
      [Version.COMMAND_CLASS_REPORT] = handlers.version_command_class_report,
    },
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handlers.switch_on,
      [capabilities.switch.commands.off.NAME] = handlers.switch_off,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handlers.refresh,
    },
    [capabilities.energyMeter.ID] = {
      [capabilities.energyMeter.commands.resetEnergyMeter.NAME] = handlers.reset_energy_meter,
    },
    -- Same handler, different door. Whichever the app offers, the behaviour
    -- is identical -- and the standard one still works from automations and
    -- the API even where no button appears.
    [RESET_ENERGY] = {
      ["resetEnergy"] = handlers.reset_energy_meter,
    },
  },
  -- No `added`: init already configures a device that has no record of being
  -- configured, and configure ends by refreshing. See handlers.lua.
  lifecycle_handlers = {
    init = handlers.device_init,
    doConfigure = handlers.configure,
    driverSwitched = handlers.driver_switched,
    infoChanged = handlers.info_changed,
  },
}
