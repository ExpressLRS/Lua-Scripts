---------------------------------------------------------------------------
-- VTX Administrator Widget - UI for 320x240 (Small)                     --
-- Small color LCD (PA01)                                                --
---------------------------------------------------------------------------

local ctx = ...
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
  -- From here up a zone spans the screen rather than half of it: at 1/3 the whole
  -- cheatsheet goes on one row and the type steps up as far as 320x240 allows,
  -- and pit mode is said in full.
  wideW = 240,
}

WidgetUI.fonts = {
  sixth = { status = BOLD },
  quarter = { status = BOLD },
  third = { status = BOLD, cheatsheet = SMLSIZE },
  -- Only the cheatsheet steps up. The band stays BOLD because MIDSIZE is what
  -- the 1/1 tier uses on this screen, and a 1/3 zone reading larger than the
  -- whole-screen one is not a ladder.
  thirdWide = { status = BOLD, cheatsheet = STDSIZE },
  half = { hero = BOLD, detail = SMLSIZE, cheatsheet = SMLSIZE },
  full = { hero = MIDSIZE, detail = SMLSIZE, cheatsheet = SMLSIZE },
}

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSVTXAdmin/ui/topbar.lua")({
  VTXDisplay = VTXDisplay,
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

--- 1/4: two rows. Row 1: the headline plus power. Row 2: cheatsheet.
--- Power rides the headline rather than taking a row: two rows is all there is
--- here, and the cheatsheet has the other one.
--- The status line rides it too, which is the one place it does. This tier has no
--- spare row to hold it, so "VTX Admin  Loading..." is the whole first line while
--- the VTX is quiet.
function WidgetUI.buildQuarter(w, h, opa)
  local font = WidgetUI.fonts.quarter.status
  local extras = {
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = font,
      color = COLOR_THEME_SECONDARY1,
      text = VTXDisplay.powerShort,
      visible = VTXDisplay.showChannel,
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = SMLSIZE,
      color = VTXDisplay.pitColor,
      text = VTXDisplay.pitShort,
      visible = VTXDisplay.showChannel,
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = BOLD,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.statusText,
      visible = VTXDisplay.showStatus,
    },
  }
  local rows = { VTXDisplay.buildHeadline(w, font, extras) }
  local cheatsheet = VTXDisplay.buildCheatsheet()
  if cheatsheet then
    rows[#rows + 1] = cheatsheet
  end
  WidgetLayout.column(w, h, opa, rows)
end

--- 1/3: the headline, then the cheatsheet.
--- The name costs nothing here because it shares the headline with the reading:
--- at one size, told apart by colour, they read as a caption and its value. That
--- is what gets a title onto 320x240 at all, where a row of its own was always
--- too tight -- and the line it saves puts the whole cheatsheet on one row where
--- the zone is full width.
--- A half-width zone keeps the two rows, the terse detail forms and the smaller
--- cheatsheet.
function WidgetUI.buildThird(w, h, opa)
  local wide = w >= WidgetUI.breakpoints.wideW
  local f = wide and WidgetUI.fonts.thirdWide or WidgetUI.fonts.third
  local rows = {
    VTXDisplay.buildHeadline(w, f.status, VTXDisplay.buildDetailExtras(wide)),
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

--- 1/2: title + band + status + detail + cheatsheet.
function WidgetUI.buildHalf(w, h, opa)
  local f = WidgetUI.fonts.half
  local rows = VTXDisplay.buildHeroRows(f)
  local cs1, cs2 = VTXDisplay.buildCheatsheetRows(f.cheatsheet)
  if cs1 then
    rows[#rows + 1] = cs1
    rows[#rows + 1] = cs2
  end

  WidgetLayout.column(w, h, opa, rows)
end

--- 1/1: title + MIDSIZE band + status + detail + cheatsheet.
function WidgetUI.buildFull(w, h, opa)
  local f = WidgetUI.fonts.full
  local rows = VTXDisplay.buildHeroRows(f)
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
