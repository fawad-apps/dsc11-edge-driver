-- Copyright 2026 Fawad Rizwi
-- Licensed under the Apache License, Version 2.0 (the "License"); you may not
-- use this file except in compliance with the License. You may obtain a copy
-- of the License at: http://www.apache.org/licenses/LICENSE-2.0

--[[
  DSC11 endpoint mapping.

  This device addresses the SAME physical outlet with TWO DIFFERENT Z-Wave
  endpoint numbers, depending on the command class:

      outlet N (1..4)   switch / basic endpoint  =  N       (1..4)
                        meter endpoint           =  N + 2   (3..6)

  That is not a guess. SmartThings' own legacy device handler for this device
  gates the offset on the command class.

  The excerpts below are from that handler, reformatted and truncated:

      devicetypes/smartthings/aeon-smartstrip.src/aeon-smartstrip.groovy
      https://github.com/SmartThingsCommunity/SmartThingsPublic/blob/master/devicetypes/smartthings/aeon-smartstrip.src/aeon-smartstrip.groovy
      Copyright 2015 SmartThings
      Licensed under the Apache License, Version 2.0

      private encap(cmd, endpoint) {
          if (endpoint) {
              if (cmd.commandClassId == 0x32) {        // COMMAND_CLASS_METER
                  // Metered outlets are numbered differently than switches
                  if (endpoint < 0x80) { endpoint += 2 }

  ...and unwinds it on receive:

      Integer endpoint = cmd.sourceEndPoint
      if (endpoint > 2) { zwaveEvent(encapsulatedCommand, endpoint - 2) }

  The same DTH's tile fixtures show switch reports arriving on source
  endpoints 01..04, confirming switches are NOT offset.

  WHY THIS FILE EXISTS

  A single component->endpoint map cannot describe this device, so the maps
  installed via set_component_to_endpoint_fn / set_endpoint_to_component_fn
  carry the SWITCH convention only. Every METER command is addressed
  explicitly with dst_channels, and every METER report is routed by hand in
  handlers.lua.

  Endpoints 3 and 4 are genuinely ambiguous -- they are the switch endpoints
  for outlets 3 and 4 AND the meter endpoints for outlets 1 and 2. Only the
  command class distinguishes them, and endpoint_to_component never sees the
  command class. Any code here that routes a meter report through the
  component map will silently attribute outlet 1's power to outlet 3.
]]

local log = require "log"

local endpoints = {}

endpoints.OUTLET_COUNT = 4

-- The two always-on sockets. Confirmed on hardware: they are metered, on
-- meter endpoints 1 and 2, and that is what the offset above is for.
--
--     meter endpoint 1..2  =  the two always-on sockets
--     meter endpoint 3..6  =  the four switchable outlets
--
-- So the strip meters all SIX sockets in physical order, and the switchable
-- four simply start at 3. METER_OFFSET is not an arbitrary quirk: it is
-- exactly the number of always-on sockets that come first.
--
-- Established by querying channels 1 and 2 directly and checking the result
-- against the strip's own whole-device total: the six socket readings sum to
-- it, which a wrong mapping would not do.
endpoints.ALWAYS_ON_COUNT = 2

-- Offset applied to meter endpoints only. See the DTH excerpt above, and the
-- always-on sockets that explain it.
endpoints.METER_OFFSET = endpoints.ALWAYS_ON_COUNT

--- Z-Wave endpoint carrying switch/basic traffic for an outlet.
--- @param outlet number 1..4
--- @return number
function endpoints.switch_endpoint(outlet)
  return outlet
end

--- Z-Wave endpoint carrying meter traffic for an outlet.
--- @param outlet number 1..4
--- @return number
function endpoints.meter_endpoint(outlet)
  return outlet + endpoints.METER_OFFSET
end

--- Profile component id for an outlet.
--- @param outlet number 1..4
--- @return string
function endpoints.component_for_outlet(outlet)
  return string.format("switch%d", outlet)
end

--- Outlet a switch/basic report on `channel` refers to, or nil.
--- @param channel number
--- @return number|nil
function endpoints.outlet_for_switch_channel(channel)
  if channel >= 1 and channel <= endpoints.OUTLET_COUNT then
    return channel
  end
  return nil
end

--- Outlet a meter report on `channel` refers to, or nil.
--- @param channel number
--- @return number|nil
function endpoints.outlet_for_meter_channel(channel)
  local outlet = channel - endpoints.METER_OFFSET
  if outlet >= 1 and outlet <= endpoints.OUTLET_COUNT then
    return outlet
  end
  return nil
end

--- Meter endpoint for one of the always-on sockets. They come first, so the
--- mapping is the identity -- and that is exactly why the switchable outlets
--- are offset by two.
--- @param socket number 1..2
--- @return number
function endpoints.always_on_meter_endpoint(socket)
  return socket
end

--- Always-on socket a meter report on `channel` refers to, or nil.
--- @param channel number
--- @return number|nil
function endpoints.always_on_for_meter_channel(channel)
  if channel >= 1 and channel <= endpoints.ALWAYS_ON_COUNT then
    return channel
  end
  return nil
end

--- Profile component id for an always-on socket.
--- @param socket number 1..2
--- @return string
function endpoints.component_for_always_on(socket)
  return string.format("alwaysOn%d", socket)
end

--- SWITCH-convention component -> endpoint map. Meter commands must NOT use
--- this; they address dst_channels directly.
function endpoints.component_to_endpoint(device, component_id)
  if component_id == "main" then
    -- Empty means the root device: the strip's own master switch and its
    -- whole-strip meter.
    return {}
  end
  local outlet = tonumber(component_id:match("^switch(%d+)$"))
  if outlet and outlet >= 1 and outlet <= endpoints.OUTLET_COUNT then
    return { endpoints.switch_endpoint(outlet) }
  end
  log.warn(string.format("no switch endpoint for component '%s'", component_id))
  return {}
end

--- SWITCH-convention endpoint -> component map.
function endpoints.endpoint_to_component(device, endpoint)
  local outlet = endpoints.outlet_for_switch_channel(endpoint)
  if outlet then
    local component_id = endpoints.component_for_outlet(outlet)
    if device.profile.components[component_id] then
      return component_id
    end
  end
  return "main"
end

return endpoints
