---------------------------------------------------------------------------
-- ELRS Telemetry Widget                                                --
-- Displays ELRS link telemetry: RSSI, LQ, Range, RF Mode, Power,      --
-- Battery, Current, GPS, and Flight Mode.                              --
--                                                                      --
-- Uses the loadable.lua pattern to minimize memory when not in use.    --
-- Requires /SCRIPTS/ELRS on the SD card for shared CRSF transport.     --
---------------------------------------------------------------------------

local name = "ELRSTelemetry"

-- selene: allow(undefined_variable)
local function create(zone, options)
  if not _crsfSingleton then
    local getCRSF = loadScript("/SCRIPTS/ELRS/crsf.lua")
    ---@diagnostic disable-next-line: need-check-nil
    _crsfSingleton = getCRSF()
  end
  if not _elrsTelemetrySingleton then
    local getTelemetry = loadScript(table.concat({ "/WIDGETS/", name, "/telemetry.lua" }))
    ---@diagnostic disable-next-line: need-check-nil
    _elrsTelemetrySingleton = getTelemetry(_crsfSingleton)
  end
  -- Every model has its own widgets, so create() runs again for each of them
  -- on a model change -- but the singleton above does not go with them. It is
  -- a global in the widget Lua state, which only boot and resume from shutdown
  -- rebuild, so the previous model's aircraft would still be on screen: its
  -- last GPS position above all, indistinguishable from a live fix.
  --
  -- Keyed on the model, not on create() alone, because create() also runs when
  -- a widget is placed: adding a second telemetry widget must not throw away
  -- the cell count and position the first one has locked on to. Two models
  -- with the same name share a verdict, which is as far as this needs to go.
  local modelId = model.getInfo().name
  if _elrsTelemetrySingleton.modelId ~= modelId then
    _elrsTelemetrySingleton.modelId = modelId
    _elrsTelemetrySingleton.resetModel()
  end
  -- Cheap, idempotent and self-repairing, so every create() may ask again.
  _elrsTelemetrySingleton.resetModelMatch()
  local loadable = loadScript(table.concat({ "/WIDGETS/", name, "/loadable.lua" }))
  ---@diagnostic disable-next-line: need-check-nil
  return loadable(zone, options, _elrsTelemetrySingleton)
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
