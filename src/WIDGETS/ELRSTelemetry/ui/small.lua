---------------------------------------------------------------------------
-- ELRS Telemetry Widget - UI for 320x240 (Small)                       --
-- Small color LCD (PA01)                                               --
---------------------------------------------------------------------------

local ctx = ...
local Display = ctx.Display
local bgOpacity = ctx.bgOpacity
local WidgetLayout = ctx.WidgetLayout
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

-- Breakpoints: absolute pixel values for 320x240.
-- Smallest color screen — everything is compact.
WidgetUI.breakpoints = {
  wideW = 240,
  topBarW = 80,
  sixthH = 30,
  quarterH = 42,
  thirdH = 58,
  halfH = 82,
}

WidgetUI.fonts = {
  sixth = { hero = BOLD },
  quarter = { hero = BOLD },
  third = { hero = BOLD, detail = SMLSIZE },
  full = { hero = BOLD, detail = SMLSIZE },
}

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSTelemetry/ui/topbar.lua")({ Display = Display })

--- 1/6: single compact line — LQ (bold) + Range/dBm (colored) + RF mode (neutral).
--- Fixed-width columns prevent layout jumping when digit counts change.
function WidgetUI.buildSixth(w, h, opa)
  local c1w = math.floor(w * 0.28)
  local c2w = math.floor(w * 0.40)
  local c3w = w - c1w - c2w
  local columns = {
    {
      type = lvgl.BOX,
      w = c1w,
      h = lvgl.UI_ELEMENT_HEIGHT,
      children = {
        {
          type = lvgl.LABEL,
          y = lvgl.PAD_SMALL,
          font = WidgetUI.fonts.sixth.hero,
          color = Display.heroColor,
          text = Display.heroText,
        },
      },
    },
    {
      type = lvgl.BOX,
      w = c2w,
      h = lvgl.UI_ELEMENT_HEIGHT,
      children = {
        {
          type = lvgl.LABEL,
          y = lvgl.PAD_SMALL,
          font = SMLSIZE,
          color = Display.detailColor,
          text = Display.signalText,
        },
      },
    },
    {
      type = lvgl.BOX,
      w = c3w,
      h = lvgl.UI_ELEMENT_HEIGHT,
      children = {
        {
          type = lvgl.LABEL,
          y = lvgl.PAD_SMALL,
          font = SMLSIZE,
          color = COLOR_THEME_SECONDARY1,
          text = Display.rfModeText,
        },
      },
    },
  }
  WidgetLayout.row(w, h, opa, columns)
end

--- 1/4: LQ + Range/dBm on row 1, RF mode + Power on row 2.
--- Fixed-width first column prevents layout jumping when digit counts change.
function WidgetUI.buildQuarter(w, h, opa)
  local c1w = math.floor(w * 0.30)
  local rows = {
    {
      type = lvgl.BOX,
      w = w,
      align = LEFT + VCENTER,
      flexFlow = lvgl.FLOW_ROW,
      flexPad = lvgl.PAD_TINY,
      borderPad = 0,
      children = {
        {
          type = lvgl.LABEL,
          w = c1w,
          align = LEFT,
          font = WidgetUI.fonts.quarter.hero,
          color = Display.heroColor,
          text = Display.heroText,
        },
        {
          type = lvgl.LABEL,
          align = LEFT,
          font = SMLSIZE,
          color = Display.detailColor,
          text = Display.signalText,
        },
      },
    },
    {
      type = lvgl.BOX,
      w = w,
      align = LEFT,
      flexFlow = lvgl.FLOW_ROW,
      flexPad = lvgl.PAD_TINY,
      borderPad = 0,
      children = {
        {
          type = lvgl.LABEL,
          align = LEFT,
          font = SMLSIZE,
          color = COLOR_THEME_SECONDARY1,
          text = Display.rfDetailText,
        },
      },
    },
  }
  WidgetLayout.column(w, h, opa, rows)
end

--- 1/3: hero LQ + Range/RSSI detail + RF mode. No title on small screen.
function WidgetUI.buildThird(w, h, opa)
  local rows = {}
  -- No title row — too tight on 320x240
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = Display.heroFont(WidgetUI.fonts.third),
    color = Display.heroColor,
    text = Display.heroText,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = WidgetUI.fonts.third.detail,
    color = Display.detailColor,
    text = Display.signalText,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = Display.rfDetailText,
  }

  WidgetLayout.column(w, h, opa, rows)
end

--- Data rows shared by the 1/2 and 1/1 tiers:
--- LQ, Range/RSSI, RF mode/power, battery.
local function appendDataRows(rows)
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = Display.heroFont(WidgetUI.fonts.full),
    color = Display.heroColor,
    text = Display.heroText,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = WidgetUI.fonts.full.detail,
    color = Display.detailColor,
    text = Display.signalText,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = Display.rfDetailText,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = Display.batteryText,
  }
end

--- 1/2: the panel without the group rows or the rules.
--- Both bars survive, which is the whole point of the layout: this is the
--- size the widget is usually placed at.
function WidgetUI.buildHalf(w, h, opa)
  local m = measured()
  Components.halfTier(w, h, opa, m, { lqFont = BOLD, lqH = m.bold })
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
  elseif h < bp.sixthH then
    WidgetUI.buildSixth(w, h, opa)
  elseif h < bp.quarterH then
    WidgetUI.buildQuarter(w, h, opa)
  elseif h < bp.thirdH then
    WidgetUI.buildThird(w, h, opa)
  elseif h < bp.halfH then
    WidgetUI.buildHalf(w, h, opa)
  else
    WidgetUI.buildFull(w, h, opa)
  end
end

return WidgetUI
