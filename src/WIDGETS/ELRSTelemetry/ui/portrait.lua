---------------------------------------------------------------------------
-- ELRS Telemetry Widget - UI for 320x480 (Portrait)                    --
-- FlySky EL18 — vertical screen                                        --
---------------------------------------------------------------------------

local ctx = ...
local Display = ctx.Display
local bgOpacity = ctx.bgOpacity
local Components = ctx.Components

local WidgetUI = {}

-- Font line heights, measured once. Fonts do not change under the widget, so
-- there is nothing to invalidate; this only avoids re-measuring per build.
local metrics
local function measured()
  if not metrics then
    metrics = Components.measure()
  end
  return metrics
end

-- Breakpoints: absolute pixel values for 320x480 portrait.
WidgetUI.breakpoints = {
  wideW = 240,
  topBarW = 80,
  quarterH = 78,
  thirdH = 110,
}

WidgetUI.fonts = {
  compact = { hero = BOLD },
  third = { hero = BOLD, detail = SMLSIZE },
  full = { hero = MIDSIZE, heroStatus = BOLD, detail = SMLSIZE },
}

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSTelemetry/ui/topbar.lua")({ Display = Display })

--- 1/4 and 1/6: one row of readings over the headroom bar. The composition
--- is shared, and it sheds cells and bar height as the zone shrinks.
function WidgetUI.buildCompact(w, h, opa)
  local m = measured()
  Components.compactTier(w, h, opa, m, { lqFont = WidgetUI.fonts.compact.hero, lqH = m.bold })
end

--- 1/3: the strip, LQ beside the RSSI pair, then the headroom bar.
function WidgetUI.buildThird(w, h, opa)
  local m = measured()
  Components.thirdTier(w, h, opa, m, { lqFont = WidgetUI.fonts.third.hero, lqH = m.bold })
end

--- 1/1: the uplink panel between a status strip and the group rows.
--- Everything but the fonts is shared, so the composition itself lives in
--- ui/components.lua and this picks the hero size the tier can afford.
function WidgetUI.buildFull(w, h, opa)
  local m = measured()
  Components.fullTier(w, h, opa, m, {
    wide = w >= WidgetUI.breakpoints.wideW,
    lqFont = BOLD,
    lqH = m.bold,
  })
end

--- Route to the appropriate minimized layout based on widget dimensions.
function WidgetUI.build(wgtZone, opts)
  lvgl.clear()
  local w, h = wgtZone.w, wgtZone.h
  local opa = bgOpacity(opts)
  local bp = WidgetUI.breakpoints
  if w < bp.topBarW then
    TopBarUI.build(w, h)
  elseif h < bp.quarterH then
    WidgetUI.buildCompact(w, h, opa)
  elseif h < bp.thirdH then
    WidgetUI.buildThird(w, h, opa)
  else
    WidgetUI.buildFull(w, h, opa)
  end
end

return WidgetUI
