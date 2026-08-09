---------------------------------------------------------------------------
-- VTX Administrator Widget - UI for 320x240 (Small)                     --
-- Small color LCD (PA01)                                                --
---------------------------------------------------------------------------

local ctx = ...
local VTX = ctx.VTX
local Protocol = ctx.Protocol
local bgOpacity = ctx.bgOpacity
local VTXDisplay = ctx.VTXDisplay
local WidgetLayout = ctx.WidgetLayout

local WidgetUI = {}

-- Breakpoints: absolute pixel values for 320x240.
-- Smallest color screen — everything is compact.
WidgetUI.breakpoints = {
  topBarW = 80,
  sixthH = 38,
  quarterH = 54,
  thirdH = 76,
  halfH = 100,
}

WidgetUI.fonts = {
  sixth = { status = BOLD },
  quarter = { status = BOLD },
  third = { status = BOLD },
  half = { hero = BOLD, detail = SMLSIZE },
  full = { hero = MIDSIZE, detail = SMLSIZE },
}

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSVTXAdmin/ui/topbar.lua")({
  Protocol = Protocol,
  VTX = VTX,
})

--- 1/6: single row with band + status + power + pit mode + cheatsheet.
--- Fixed-width band column prevents layout jumping when values change.
--- Loading state uses unconstrained label to avoid overflow in narrow columns.
function WidgetUI.buildSixth(w, h, opa)
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
      align = LEFT,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = VTXDisplay.powerShort,
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = SMLSIZE,
      color = VTXDisplay.pitColor,
      text = VTXDisplay.pitText,
    },
  }
  local labels = VTXDisplay.build6posLabels()
  for _, lbl in ipairs(labels) do
    columns[#columns + 1] = lbl
  end

  WidgetLayout.row(w, h, opa, columns)
end

--- 1/4: two rows. Row 1: band + status + power + pit. Row 2: cheatsheet.
--- Fixed-width band column prevents layout jumping when values change.
--- Loading state uses unconstrained label to avoid overflow in narrow columns.
function WidgetUI.buildQuarter(w, h, opa)
  local c1w = math.floor(w * 0.22)
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
      children = {
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
          font = SMLSIZE,
          color = COLOR_THEME_SECONDARY1,
          text = VTXDisplay.powerShort,
        },
        {
          type = lvgl.LABEL,
          align = LEFT,
          font = SMLSIZE,
          color = RED,
          text = VTXDisplay.pitShort,
        },
      },
    },
  }
  local cheatsheet = VTXDisplay.buildCheatsheet()
  if cheatsheet then
    rows[#rows + 1] = cheatsheet
  end
  WidgetLayout.column(w, h, opa, rows)
end

--- 1/3: band + status + power + pit mode, cheatsheet. No title on small screen.
--- Fixed-width band column prevents layout jumping when values change.
--- Loading state uses unconstrained label to avoid overflow in narrow columns.
function WidgetUI.buildThird(w, h, opa)
  local c1w = math.floor(w * 0.22)
  local rows = {}
  -- Loading state: full-width status label
  rows[#rows + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = BOLD,
    color = VTXDisplay.mainColor,
    text = VTXDisplay.statusText,
    visible = VTXDisplay.showStatus,
  }
  -- Active state: band + power + pit mode row (no title — too tight on 320x240)
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
        text = VTXDisplay.powerShort,
      },
      {
        type = lvgl.LABEL,
        align = LEFT,
        font = SMLSIZE,
        color = VTXDisplay.pitColor,
        text = VTXDisplay.pitText,
      },
    },
  }
  local cheatsheet = VTXDisplay.buildCheatsheet()
  if cheatsheet then
    rows[#rows + 1] = cheatsheet
  end

  WidgetLayout.column(w, h, opa, rows)
end

--- 1/2: title + band + status + detail + cheatsheet.
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
      type = lvgl.BOX,
      w = w,
      align = LEFT + VCENTER,
      flexFlow = lvgl.FLOW_ROW,
      flexPad = lvgl.PAD_TINY,
      borderPad = 0,
      children = {
        {
          type = lvgl.LABEL,
          align = LEFT,
          font = SMLSIZE,
          color = COLOR_THEME_SECONDARY1,
          text = VTXDisplay.powerShort,
        },
        {
          type = lvgl.LABEL,
          align = LEFT,
          font = SMLSIZE,
          color = VTXDisplay.pitColor,
          text = VTXDisplay.pitTextLong,
        },
      },
    },
  }
  local cheatsheet = VTXDisplay.buildCheatsheet()
  if cheatsheet then
    rows[#rows + 1] = cheatsheet
  end

  WidgetLayout.column(w, h, opa, rows)
end

--- 1/1: title + MIDSIZE band + status + detail + cheatsheet.
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
  local cheatsheet = VTXDisplay.buildCheatsheet()
  if cheatsheet then
    rows[#rows + 1] = cheatsheet
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
