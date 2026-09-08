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
-- No half rung: portrait zones are tall, so everything past the third
-- breakpoint has the height for the whole card and goes straight to full.
WidgetUI.breakpoints = {
  topBarW = 80,
  quarterH = 78,
  thirdH = 110,
}

-- The full tier's hero is a ladder, not a size: the tier serves every zone
-- from the 145px third up to the 435px full. The ladder tops out at DBLSIZE:
-- the screen is narrow, and XXL digits crowd the caption and the readings
-- beside them off a 320-wide card.
WidgetUI.fonts = {
  compact = { hero = SMLSIZE },
  third = { hero = BOLD },
  full = { heroLadder = { DBLSIZE, MIDSIZE, BOLD } },
}

-- The cap on bar thickness, in this screen's pixels.
local BAR_H = 5

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSTelemetry/ui/topbar.lua")({ Display = Display })

--- 1/4 and 1/6: one row of readings over the RSSI bar. The composition is
--- shared, and it sheds cells and bar height as the zone shrinks.
function WidgetUI.buildCompact(w, h, opa)
  local m = measured()
  Components.compactTier(w, h, opa, m, {
    heroFont = WidgetUI.fonts.compact.hero,
    barH = BAR_H,
  })
end

--- 1/3: header, the hero beside the RSSI pair, one bar.
function WidgetUI.buildThird(w, h, opa)
  local m = measured()
  Components.thirdTier(w, h, opa, m, {
    heroFont = WidgetUI.fonts.third.hero,
    barH = BAR_H,
  })
end

--- 1/1: the whole card -- header, hero, both bar rows, the reading grid.
--- Everything but the fonts is shared, so the composition itself lives in
--- ui/components.lua and this hands it the ladder the screen can afford.
function WidgetUI.buildFull(w, h, opa)
  local m = measured()
  Components.fullTier(w, h, opa, m, {
    heroLadder = WidgetUI.fonts.full.heroLadder,
    barH = BAR_H,
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
