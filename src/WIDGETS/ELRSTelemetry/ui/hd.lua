---------------------------------------------------------------------------
-- ELRS Telemetry Widget - UI for 800x480 (HD)                          --
-- High definition landscape (TX16S Mark 3)                             --
---------------------------------------------------------------------------

local ctx = ...
local Telemetry = ctx.Telemetry
local crsf = ctx.crsf
local bgOpacity = ctx.bgOpacity
local WidgetLayout = ctx.WidgetLayout

local WidgetUI = {}

-- Breakpoints: absolute pixel values for 800x480.
WidgetUI.breakpoints = {
  topBarW = 200,
  sixthH = 74,
  quarterH = 104,
  thirdH = 146,
  halfH = 154,
}

WidgetUI.fonts = {
  sixth = { hero = BOLD },
  quarter = { hero = BOLD },
  third = { hero = MIDSIZE, detail = SMLSIZE },
  full = { hero = DBLSIZE, detail = 0 },
}

-- ============================================================================
-- Minimized display helpers
-- ============================================================================

local function detailColor()
  if not crsf.hasTelemetry then
    return COLOR_THEME_SECONDARY1
  end
  return Telemetry.rangeColor(Telemetry.rangePct)
end

local function heroTextLq()
  local status = Telemetry.statusText()
  if status then
    return status
  end
  return table.concat({ "LQ ", tostring(Telemetry.link.rqly or 0), "%" })
end

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSTelemetry/ui/topbar.lua")({
  crsf = crsf,
  Telemetry = Telemetry,
})

--- 1/6: single line — LQ (bold) + Range/dBm (colored) + RF mode/Power (neutral).
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
          font = BOLD,
          color = Telemetry.heroColor,
          text = heroTextLq,
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
          color = detailColor,
          text = Telemetry.signalText,
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
          text = Telemetry.rfDetailText,
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
      borderPad = 0,
      flexPad = lvgl.PAD_TINY,
      children = {
        {
          type = lvgl.LABEL,
          w = c1w,
          align = LEFT,
          font = BOLD,
          color = Telemetry.heroColor,
          text = heroTextLq,
        },
        {
          type = lvgl.LABEL,
          align = LEFT,
          font = SMLSIZE,
          color = detailColor,
          text = Telemetry.signalText,
        },
      },
    },
    {
      type = lvgl.BOX,
      w = w,
      align = LEFT,
      flexFlow = lvgl.FLOW_ROW,
      borderPad = 0,
      flexPad = lvgl.PAD_TINY,
      children = {
        {
          type = lvgl.LABEL,
          align = LEFT,
          font = SMLSIZE,
          color = COLOR_THEME_SECONDARY1,
          text = Telemetry.rfDetailText,
        },
      },
    },
  }
  WidgetLayout.column(w, h, opa, rows)
end

--- 1/3: title + hero LQ + Range/RSSI detail.
--- HD has plenty of room for a title row.
function WidgetUI.buildThird(w, h, opa)
  local rows = {}
  -- Title row
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = BOLD,
    color = COLOR_THEME_SECONDARY1,
    text = "ExpressLRS",
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = function()
      if Telemetry.statusText() then
        return BOLD
      end
      return MIDSIZE
    end,
    color = Telemetry.heroColor,
    text = heroTextLq,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = WidgetUI.fonts.third.detail,
    color = detailColor,
    text = Telemetry.signalText,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = Telemetry.rfDetailText,
  }

  WidgetLayout.column(w, h, opa, rows)
end

--- Data rows shared by the 1/2 and 1/1 tiers:
--- LQ, Range/RSSI, RF mode/power, battery.
local function appendDataRows(rows)
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = function()
      if Telemetry.statusText() then
        return 0
      end
      return MIDSIZE
    end,
    color = Telemetry.heroColor,
    text = heroTextLq,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = WidgetUI.fonts.full.detail,
    color = detailColor,
    text = Telemetry.signalText,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = Telemetry.rfDetailText,
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = Telemetry.batteryText,
  }
end

--- 1/2: the four data rows without the title.
--- Sits between 1/3 and 1/1 so the battery row is never clipped off the bottom.
function WidgetUI.buildHalf(w, h, opa)
  local rows = {}
  appendDataRows(rows)
  WidgetLayout.column(w, h, opa, rows)
end

--- 1/1: full telemetry display with title and large fonts.
function WidgetUI.buildFull(w, h, opa)
  local rows = {
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = BOLD,
      color = COLOR_THEME_SECONDARY1,
      text = "ExpressLRS",
    },
  }
  appendDataRows(rows)
  WidgetLayout.column(w, h, opa, rows)
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
