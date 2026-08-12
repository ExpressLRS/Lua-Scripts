---------------------------------------------------------------------------
-- ELRS Telemetry Widget                                                --
-- Displays ELRS link telemetry: RSSI, LQ, Range, RF Mode, Power,      --
-- Battery, Current, GPS, and Flight Mode.                              --
--                                                                      --
-- Uses the loadable.lua pattern to minimize memory when not in use.    --
-- Requires /SCRIPTS/ELRS on the SD card for shared CRSF protocol.      --
---------------------------------------------------------------------------

local name = "ELRSTelemetry"

-- selene: allow(undefined_variable)
local function create(zone, options)
  if not _crsfSingleton then
    local getCRSF = loadScript("/SCRIPTS/ELRS/crsf.lua")
    ---@diagnostic disable-next-line: need-check-nil
    _crsfSingleton = getCRSF()
  end
  if not _elrsTxInfoSingleton then
    local getTxInfo = loadScript("/WIDGETS/" .. name .. "/txinfo.lua")
    ---@diagnostic disable-next-line: need-check-nil
    _elrsTxInfoSingleton = getTxInfo(_crsfSingleton)
  end
  local loadable = loadScript("/WIDGETS/" .. name .. "/loadable.lua")
  ---@diagnostic disable-next-line: need-check-nil
  return loadable(zone, options, _crsfSingleton, _elrsTxInfoSingleton)
end

local function refresh(widget, event, touchState)
  widget.refresh(event, touchState)
end

local function background(widget)
  widget.background()
end

local function update(widget, options)
  widget.update(options)
end

return {
  name = "ExpressLRS Telemetry",
  create = create,
  refresh = refresh,
  background = background,
  update = update,
  options = {
    { "Transparency", VALUE, 2, 0, 5 },
  },
  useLvgl = true,
}
