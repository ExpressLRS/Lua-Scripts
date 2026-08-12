---------------------------------------------------------------------------
-- VTX Administrator Widget                                              --
-- Displays VTX status (minimized) and allows full VTX configuration     --
-- (full-screen) via the CRSF config protocol to the ELRS TX module.     --
--                                                                       --
-- Uses the loadable.lua pattern to minimize memory when not in use.     --
-- Requires /SCRIPTS/ELRS on the SD card for shared CRSF protocol.       --
---------------------------------------------------------------------------

local name = "ELRSVTXAdmin"

-- selene: allow(undefined_variable)
local function create(zone, options)
  if not _crsfSingleton then
    local getCRSF = loadScript("/SCRIPTS/ELRS/crsf.lua")
    ---@diagnostic disable-next-line: need-check-nil
    _crsfSingleton = getCRSF()
  end
  if not _crsfSessionClass then
    local getParams = loadScript("/SCRIPTS/ELRS/crsf_params.lua")
    ---@diagnostic disable-next-line: need-check-nil
    local params = getParams(_crsfSingleton)
    local getSessionClass = loadScript("/SCRIPTS/ELRS/crsf_session.lua")
    ---@diagnostic disable-next-line: need-check-nil
    _crsfSessionClass = getSessionClass(_crsfSingleton, params)
  end
  local loadable = loadScript("/WIDGETS/" .. name .. "/loadable.lua")
  ---@diagnostic disable-next-line: need-check-nil
  return loadable(zone, options, _crsfSingleton, _crsfSessionClass)
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
  name = "ExpressLRS VTX Admin",
  create = create,
  refresh = refresh,
  background = background,
  update = update,
  options = {
    { "Transparency", VALUE, 2, 0, 5 },
  },
  useLvgl = true,
}
