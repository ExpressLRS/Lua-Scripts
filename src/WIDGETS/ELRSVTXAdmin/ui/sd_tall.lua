---------------------------------------------------------------------------
-- VTX Administrator Widget - UI for 480x320 (SD Tall)                   --
-- Jumper T15, T15 Pro, TX15, ST16, PL18                                 --
---------------------------------------------------------------------------

local ctx = ...
local VTX = ctx.VTX
local Protocol = ctx.Protocol
local bgOpacity = ctx.bgOpacity
local VTXDisplay = ctx.VTXDisplay
local WidgetLayout = ctx.WidgetLayout

local WidgetUI = {}

-- Breakpoints: absolute pixel values for 480x320.
-- 48px taller than 480x272 so widget zones are proportionally taller.
WidgetUI.breakpoints = {
  topBarW = 100,
  sixthH = 50,
  quarterH = 62,
  thirdH = 118,
  halfH = 147,
}

WidgetUI.fonts = {
  sixth = { status = BOLD },
  quarter = { status = BOLD },
  third = { status = BOLD, cheatsheet = SMLSIZE },
  half = { hero = MIDSIZE, detail = SMLSIZE, cheatsheet = STDSIZE },
  full = { hero = MIDSIZE, detail = SMLSIZE, cheatsheet = STDSIZE },
}

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSVTXAdmin/ui/topbar.lua")({
  VTXDisplay = VTXDisplay,
})

--- 1/6: single row. Wide: band + detail + cheatsheet. Narrow: band + detail.
--- Fixed-width band column prevents layout jumping when values change.
--- Status text (loading/error/off) uses unconstrained label for narrow columns.
function WidgetUI.buildSixth(w, h, opa)
  local wide = w > 200
  local c1w = math.floor(w * 0.22)
  local columns = {
    {
      type = lvgl.LABEL,
      font = BOLD,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.statusText,
      visible = VTXDisplay.showStatus,
    },
    {
      type = lvgl.LABEL,
      w = c1w,
      font = WidgetUI.fonts.sixth.status,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.bandChannel,
      visible = VTXDisplay.showChannel,
    },
    {
      type = lvgl.LABEL,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = VTXDisplay.detailLine,
    },
  }
  if wide then
    local labels = VTXDisplay.build6posLabels()
    for _, lbl in ipairs(labels) do
      columns[#columns + 1] = lbl
    end
  end

  WidgetLayout.row(w, h, opa, columns)
end

--- 1/4: two rows. Row 1: band + power (+ pit mode when wide). Row 2: cheatsheet.
--- Fixed-width band column prevents layout jumping when values change.
--- Status text (loading/error/off) uses unconstrained label for narrow columns.
function WidgetUI.buildQuarter(w, h, opa)
  local wide = w > 200
  local c1w = math.floor(w * 0.22)
  local row1 = {
    {
      type = lvgl.LABEL,
      w = c1w,
      align = LEFT,
      font = WidgetUI.fonts.quarter.status,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.bandChannel,
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = WidgetUI.fonts.quarter.status,
      color = COLOR_THEME_SECONDARY1,
      text = VTXDisplay.powerShort,
    },
  }
  if wide then
    row1[#row1 + 1] = {
      type = lvgl.LABEL,
      align = LEFT,
      font = SMLSIZE,
      color = VTXDisplay.pitColor,
      text = VTXDisplay.pitText,
    }
  end
  local rows = {
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = BOLD,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.statusText,
      visible = VTXDisplay.showStatus,
    },
    {
      type = lvgl.BOX,
      w = w,
      align = LEFT + VCENTER,
      flexFlow = lvgl.FLOW_ROW,
      borderPad = 0,
      flexPad = lvgl.PAD_TINY,
      visible = VTXDisplay.showChannel,
      children = row1,
    },
  }
  local cheatsheet = VTXDisplay.buildCheatsheet()
  if cheatsheet then
    rows[#rows + 1] = cheatsheet
  end
  WidgetLayout.column(w, h, opa, rows)
end

--- 1/3: three rows — title, band + detail, cheatsheet.
--- 480x320 has enough room for a title row.
--- Fixed-width band column prevents layout jumping when values change.
--- Status text (loading/error/off) uses unconstrained label for narrow columns.
function WidgetUI.buildThird(w, h, opa)
  local c1w = math.floor(w * 0.22)
  local rows = {}
  -- Title row — 480x320 has more vertical room than 480x272
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    font = BOLD,
    color = COLOR_THEME_SECONDARY1,
    text = "VTX Admin",
  }
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = BOLD,
    color = VTXDisplay.mainColor,
    text = VTXDisplay.statusText,
    visible = VTXDisplay.showStatus,
  }
  rows[#rows + 1] = {
    type = lvgl.BOX,
    w = w,
    align = LEFT + VCENTER,
    flexFlow = lvgl.FLOW_ROW,
    flexPad = lvgl.PAD_TINY,
    borderPad = 0,
    visible = VTXDisplay.showChannel,
    children = {
      {
        type = lvgl.LABEL,
        w = c1w,
        align = LEFT,
        font = WidgetUI.fonts.third.status,
        color = VTXDisplay.mainColor,
        text = VTXDisplay.bandChannel,
      },
      {
        type = lvgl.LABEL,
        align = LEFT,
        font = SMLSIZE,
        color = COLOR_THEME_SECONDARY1,
        text = VTXDisplay.detailLine,
      },
    },
  }
  local cs1, cs2 = VTXDisplay.buildCheatsheetRows(WidgetUI.fonts.third.cheatsheet)
  if cs1 then
    rows[#rows + 1] = cs1
    rows[#rows + 1] = cs2
  end

  WidgetLayout.column(w, h, opa, rows)
end

--- 1/2: title + band/status + detail + cheatsheet.
function WidgetUI.buildHalf(w, h, opa)
  local rows = {
    {
      type = lvgl.LABEL,
      font = BOLD,
      color = COLOR_THEME_SECONDARY1,
      text = "VTX Admin",
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = BOLD,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.statusText,
      visible = VTXDisplay.showStatus,
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = WidgetUI.fonts.half.hero,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.bandChannel,
      visible = VTXDisplay.showChannel,
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = VTXDisplay.detailLong,
    },
  }
  local cs1, cs2 = VTXDisplay.buildCheatsheetRows(WidgetUI.fonts.half.cheatsheet)
  if cs1 then
    rows[#rows + 1] = cs1
    rows[#rows + 1] = cs2
  end

  WidgetLayout.column(w, h, opa, rows)
end

--- 1/1: title + band/status + detail + cheatsheet.
function WidgetUI.buildFull(w, h, opa)
  local rows = {
    {
      type = lvgl.LABEL,
      font = BOLD,
      color = COLOR_THEME_SECONDARY1,
      text = "VTX Admin",
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = BOLD,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.statusText,
      visible = VTXDisplay.showStatus,
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = WidgetUI.fonts.full.hero,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.bandChannel,
      visible = VTXDisplay.showChannel,
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = WidgetUI.fonts.full.detail,
      color = COLOR_THEME_SECONDARY1,
      text = VTXDisplay.detailLong,
    },
  }
  local cs1, cs2 = VTXDisplay.buildCheatsheetRows(WidgetUI.fonts.full.cheatsheet)
  if cs1 then
    rows[#rows + 1] = cs1
    rows[#rows + 1] = cs2
  end

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
