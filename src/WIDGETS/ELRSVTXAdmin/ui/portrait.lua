---------------------------------------------------------------------------
-- VTX Administrator Widget - UI for 320x480 (Portrait)                  --
-- FlySky EL18 — vertical screen, widget zones differ significantly      --
---------------------------------------------------------------------------

local ctx = ...
local VTXAdmin = ctx.VTXAdmin
local bgOpacity = ctx.bgOpacity
local VTXDisplay = ctx.VTXDisplay
local WidgetLayout = ctx.WidgetLayout

local WidgetUI = {}

-- Breakpoints: absolute pixel values for 320x480 portrait.
-- Portrait widget zones tend to be wider-relative-to-height than landscape.
-- Height tiers are scaled for the taller 480px screen.
WidgetUI.breakpoints = {
  topBarW = 80,
  sixthH = 70,
  quarterH = 100,
  thirdH = 140,
  halfH = 210,
  -- From here up a zone spans the screen rather than half of it: at 1/3 the whole
  -- cheatsheet goes on one row and the band steps up to the size that width
  -- affords. 320px is all there is, so the cheatsheet cannot follow it.
  wideW = 240,
}

WidgetUI.fonts = {
  sixth = { status = BOLD },
  quarter = { status = BOLD },
  third = { status = BOLD, cheatsheet = STDSIZE },
  thirdWide = { status = MIDSIZE, cheatsheet = STDSIZE },
  half = { hero = MIDSIZE, detail = SMLSIZE, cheatsheet = STDSIZE },
  full = { hero = DBLSIZE, detail = SMLSIZE, cheatsheet = STDSIZE },
}

-- ============================================================================
-- Minimized display helpers (portrait-specific overrides)
-- ============================================================================

--- Shorter detail line for narrow portrait screen.
local function detailLine()
  if not VTXAdmin.hasPower() then
    return ""
  end
  local pit = VTXAdmin.state.pitmode and " Pit" or ""
  return table.concat({ VTXDisplay.powerShort(), pit })
end

--- Shorter long-form detail line for narrow portrait screen.
local function detailLong()
  if VTXAdmin.isDisabled() then
    return "VTX Disabled"
  end
  if not VTXAdmin.hasPower() then
    return ""
  end
  local pit = VTXAdmin.state.pitmode and "  Pit" or ""
  return table.concat({ VTXDisplay.powerLong(), pit })
end

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSVTXAdmin/ui/topbar.lua")({
  VTXDisplay = VTXDisplay,
})

--- 1/6: single row with band/channel + compact detail.
--- Fixed-width band column prevents layout jumping when values change.
--- Loading state uses unconstrained label to avoid overflow in narrow columns.
function WidgetUI.buildSixth(w, h, opa)
  local c1w = math.floor(w * 0.28)
  local columns = {
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
      font = BOLD,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.statusText,
      visible = VTXDisplay.showStatus,
    },
    {
      type = lvgl.LABEL,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = detailLine,
    },
  }
  local labels = VTXDisplay.build6posLabels()
  for _, lbl in ipairs(labels) do
    columns[#columns + 1] = lbl
  end

  WidgetLayout.row(w, h, opa, columns)
end

--- 1/4: title + band/channel + power + cheatsheet.
--- Fixed-width band column prevents layout jumping when values change.
--- Loading state uses unconstrained label to avoid overflow in narrow columns.
function WidgetUI.buildQuarter(w, h, opa)
  local c1w = math.floor(w * 0.28)
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
          color = VTXDisplay.pitColor,
          text = VTXDisplay.pitText,
        },
      },
    },
  }
  if w < 200 then
    local cs1, cs2 = VTXDisplay.buildCheatsheetRows()
    if cs1 then
      rows[#rows + 1] = cs1
      rows[#rows + 1] = cs2
    end
  else
    local cs = VTXDisplay.buildCheatsheet()
    if cs then
      rows[#rows + 1] = cs
    end
  end

  WidgetLayout.column(w, h, opa, rows)
end

--- 1/3: the headline, then the cheatsheet.
--- The name shares the headline with the reading rather than taking a line of
--- its own, as it does at 1/4: at one size, told apart by colour, they read as a
--- caption and its value. The line that buys puts the whole cheatsheet on one
--- row where the zone spans the screen; a half-width zone keeps the two rows.
function WidgetUI.buildThird(w, h, opa)
  local wide = w >= WidgetUI.breakpoints.wideW
  local f = wide and WidgetUI.fonts.thirdWide or WidgetUI.fonts.third
  local extras = {
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      -- Already the short form on this screen, so there is nothing terser to
      -- fall back to on a narrow zone.
      text = detailLine,
      visible = VTXDisplay.showChannel,
    },
  }
  local rows = {
    VTXDisplay.buildHeadline(w, f.status, extras),
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = BOLD,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.statusText,
      visible = VTXDisplay.showStatus,
    },
  }
  if wide then
    local cs = VTXDisplay.buildCheatsheet(f.cheatsheet)
    if cs then
      rows[#rows + 1] = cs
    end
  else
    local cs1, cs2 = VTXDisplay.buildCheatsheetRows(f.cheatsheet)
    if cs1 then
      rows[#rows + 1] = cs1
      rows[#rows + 1] = cs2
    end
  end

  WidgetLayout.column(w, h, opa, rows)
end

--- 1/2: title + band/channel + detail + cheatsheet.
function WidgetUI.buildHalf(w, h, opa)
  local f = WidgetUI.fonts.half
  local rows = VTXDisplay.buildHeroRows(f, detailLong)
  local cs1, cs2 = VTXDisplay.buildCheatsheetRows(f.cheatsheet)
  if cs1 then
    rows[#rows + 1] = cs1
    rows[#rows + 1] = cs2
  end

  WidgetLayout.column(w, h, opa, rows)
end

--- 1/1: title + MIDSIZE band/channel + detail + cheatsheet.
function WidgetUI.buildFull(w, h, opa)
  local f = WidgetUI.fonts.full
  local rows = VTXDisplay.buildHeroRows(f, detailLong)
  local cs1, cs2 = VTXDisplay.buildCheatsheetRows(f.cheatsheet)
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
