---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Wiring                                       --
-- Loaded via loadScript() from ELRSTelemetry/main.lua with             --
-- (zone, options, Telemetry); returns the widget instance table.       --
--                                                                      --
-- One of these exists per placed widget. It owns no state of its own:  --
-- everything it shows lives in the Telemetry singleton, which outlives --
-- it. All this file does is pick the layout for the screen, wire the   --
-- components together, and drive them from the widget callbacks.       --
--                                                                      --
-- The minimized layout is per screen size; the full-screen page is     --
-- shared, because lvgl.page() handles the responsive part itself.      --
---------------------------------------------------------------------------

local zone, options, Telemetry = ...

-- ============================================================================
-- Display components
-- ============================================================================

local Display, WidgetLayout = loadScript("/WIDGETS/ELRSTelemetry/ui/display.lua")(Telemetry)
local Components = loadScript("/WIDGETS/ELRSTelemetry/ui/components.lua")(Display)

-- ============================================================================
-- Screen detection and UI loading
-- ============================================================================

--- Detect screen resolution and return an ID for the per-screen UI file.
local function getScreenId()
  local w, h = LCD_W, LCD_H
  if w >= 800 then
    return "hd" -- 800x480
  elseif w < h then
    return "portrait" -- 320x480 (EL18)
  elseif w <= 320 then
    return "small" -- 320x240
  elseif h >= 320 then
    return "sd_tall" -- 480x320 (T15, T15 Pro, TX15, ST16, PL18)
  else
    return "sd" -- 480x272 (TX16S, MAX, Mk II)
  end
end

--- Convert Transparency option (0-5) to LVGL opacity (255-0).
local function bgOpacity(opts)
  local t = (opts and opts.Transparency) or 2
  return math.max(0, 255 - 51 * t)
end

local screenId = getScreenId()
local uiPath = table.concat({ "/WIDGETS/ELRSTelemetry/ui/", screenId, ".lua" })
local WidgetUI = loadScript(uiPath)({
  Display = Display,
  bgOpacity = bgOpacity,
  WidgetLayout = WidgetLayout,
  Components = Components,
})

-- ============================================================================
-- Widget lifecycle
-- ============================================================================

local wgt = {
  zone = zone,
  options = options,
}

-- drain() is per instance and ungated: this instance owns a pop queue in the
-- firmware that only it can empty. update() is shared and samples at most once
-- per tick, so the instances after the first fall through it.
function wgt.background()
  Telemetry.drain()
  Telemetry.update()
end

function wgt.refresh(_event, _touchState)
  wgt.background()
end

local FullScreenUI

--- Build the full-screen page, loading it the first time it is asked for.
--- Only one widget can be full screen at a time, so loading it eagerly would
--- leave a page builder resident in every instance that never shows one.
--- Nothing is lost by waiting: update() is not a hot path -- EdgeTX calls it
--- on construction, on entering and leaving full screen, and on an options
--- edit -- so a loadScript here costs nothing.
local function buildFullScreen()
  if not FullScreenUI then
    FullScreenUI = loadScript("/WIDGETS/ELRSTelemetry/ui/fullscreen.lua")(Telemetry, Display)
  end
  FullScreenUI.build()
end

function wgt.update(newOptions)
  wgt.options = newOptions
  if lvgl.isFullScreen() then
    buildFullScreen()
  else
    WidgetUI.build(wgt.zone, wgt.options)
  end
end

-- Populate the snapshot before the first paint: update() runs callRefs without a
-- preceding refresh(), so label callbacks can fire before the first background tick.
Telemetry.update()

-- Initial build
WidgetUI.build(wgt.zone, wgt.options)

return wgt
