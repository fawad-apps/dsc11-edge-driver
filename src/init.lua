-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0 (the "License"); you may not
-- use this file except in compliance with the License. You may obtain a copy
-- of the License at: http://www.apache.org/licenses/LICENSE-2.0

--[[
  Aeon Labs DSC11 Smart Strip -- SmartThings Edge driver.

  Handles exactly one device: mfr 0x0086 / product type 0x0003 /
  product id 0x000B. See fingerprints.yml.

  This file does nothing but start the driver. The handler registrations live
  in driver_template.lua so that a test can read them without running
  anything -- `run()` below blocks, so requiring this file is not something a
  test can do. driver_template.lua explains what is registered and why the
  platform defaults are not.
]]

--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"

local driver_template = require "driver_template"

--- @type st.zwave.Driver
local dsc11_driver = ZwaveDriver("aeon-dsc11-smart-strip", driver_template)
dsc11_driver:run()
