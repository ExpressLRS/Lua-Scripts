---------------------------------------------------------------------------
-- VTX Administrator Widget - UI for 480x320 (SD Tall)                   --
-- Jumper T15, T15 Pro, TX15, ST16, PL18                                 --
---------------------------------------------------------------------------

local ctx = ...
local bgOpacity = ctx.bgOpacity
local VTXDisplay = ctx.VTXDisplay
local WidgetLayout = ctx.WidgetLayout

local WidgetUI = {}

-- Breakpoints: absolute pixel values for 480x320.
-- 48px taller than 480x272 so widget zones are proportionally taller.
WidgetUI.breakpoints = {
  topBarW = 100,
  sixthH = 50,
  -- The 1/6 tier stacks the cheatsheet on a second row from here up,
  -- and only where the six columns have the width for it.
  sixthStackH = 40,
  sixthStackW = 180,
  quarterH = 62,
  thirdH = 118,
  halfH = 147,
  -- From here up a zone spans the screen rather than half of it. What it buys
  -- differs by tier: the whole cheatsheet on one row and a step up in type at
  -- 1/3, pit mode said in full at 1/6.
  wideW = 340,
}

WidgetUI.fonts = {
  sixth = { status = BOLD },
  quarter = { status = BOLD },
  third = { status = BOLD, cheatsheet = SMLSIZE },
  -- Two lines at the half-width sizes fill the top third of a full-width zone
  -- and leave the rest of the panel empty, so both of them step up.
  thirdWide = { status = MIDSIZE, cheatsheet = STDSIZE },
  half = { hero = MIDSIZE, detail = SMLSIZE, cheatsheet = STDSIZE },
  full = { hero = DBLSIZE, detail = SMLSIZE, cheatsheet = STDSIZE },
}

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSVTXAdmin/ui/topbar.lua")({
  VTXDisplay = VTXDisplay,
})

--- 1/6: the headline over the cheatsheet, wherever the zone holds two rows.
--- Two rows are what make room for the name: with the whole cheatsheet on the row
--- below, the one above is left to the name, the reading and the detail, and none
--- of the three has to give. That is worth having at any width -- a full-width
--- zone can fit all four inline, but then the widget is a row of readings with
--- nothing saying whose they are, where every other tier says "VTX Admin".
--- It fits at all only on the container's padding: at this tier PAD_SMALL top and
--- bottom is the whole difference between two rows and one. So the vertical
--- padding gives and the left edge keeps it -- that edge is what a widget in the
--- zone above lines its own text up against.
--- A zone too short for two rows, or too narrow to carry six cells on one, falls
--- back to a single inline row, which has no width to spare for the name.
--- Fixed-width band column prevents layout jumping when values change.
--- Status text (loading/error/off) uses unconstrained label for narrow columns.
function WidgetUI.buildSixth(w, h, opa)
  local bp = WidgetUI.breakpoints
  local cheatsheet = nil
  if h >= bp.sixthStackH and w >= bp.sixthStackW then
    cheatsheet = VTXDisplay.buildCheatsheet()
  end
  if cheatsheet then
    local extras = VTXDisplay.buildDetailExtras(w >= bp.wideW)
    extras[#extras + 1] = {
      type = lvgl.LABEL,
      align = LEFT,
      font = BOLD,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.statusText,
      visible = VTXDisplay.showStatus,
    }
    WidgetLayout.column(w, h, opa, {
      VTXDisplay.buildHeadline(w, WidgetUI.fonts.sixth.status, extras),
      cheatsheet,
    }, { left = lvgl.PAD_SMALL, right = lvgl.PAD_SMALL, top = lvgl.PAD_TINY, bottom = lvgl.PAD_TINY })
    return
  end

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
  if w >= bp.wideW then
    local labels = VTXDisplay.build6posLabels()
    for _, lbl in ipairs(labels) do
      columns[#columns + 1] = lbl
    end
  end

  WidgetLayout.row(w, h, opa, columns)
end

--- 1/4: two rows. Row 1: the headline, power, and pit mode where it fits.
--- Row 2: cheatsheet.
--- Power rides the headline rather than taking a row: two rows is all there is
--- here, and the cheatsheet has the other one.
--- The status line rides it too, which is the one place it does. This tier has no
--- spare row to hold it, so "VTX Admin  Loading..." is the whole first line while
--- the VTX is quiet.
function WidgetUI.buildQuarter(w, h, opa)
  local wide = w > 200
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
  }
  if wide then
    extras[#extras + 1] = {
      type = lvgl.LABEL,
      align = LEFT,
      font = SMLSIZE,
      color = VTXDisplay.pitColor,
      text = VTXDisplay.pitText,
      visible = VTXDisplay.showChannel,
    }
  end
  extras[#extras + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = BOLD,
    color = VTXDisplay.mainColor,
    text = VTXDisplay.statusText,
    visible = VTXDisplay.showStatus,
  }
  local rows = { VTXDisplay.buildHeadline(w, font, extras) }
  local cheatsheet = VTXDisplay.buildCheatsheet()
  if cheatsheet then
    rows[#rows + 1] = cheatsheet
  end
  WidgetLayout.column(w, h, opa, rows)
end

--- 1/3: the headline, then the cheatsheet.
--- The name shares the headline with the reading rather than taking a line of
--- its own, as it does at 1/4: at one size, told apart by colour, they read as a
--- caption and its value. The line that buys puts the whole cheatsheet on one
--- row, which is what a full-width zone has the width for -- two rows of three
--- across 396px leave the right half of the widget empty.
--- A half-width zone has neither the width for six columns nor for the detail
--- line in full, so it keeps the two rows, the terse forms and the smaller type.
function WidgetUI.buildThird(w, h, opa)
  local wide = w >= WidgetUI.breakpoints.wideW
  local f = wide and WidgetUI.fonts.thirdWide or WidgetUI.fonts.third
  local rows = {
    VTXDisplay.buildHeadline(w, f.status, VTXDisplay.buildDetailExtras(wide)),
    -- The status keeps a row of its own here, unlike at 1/4. This tier has the
    -- height for it, and a hidden flex child costs nothing while the VTX is
    -- tuned.
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

--- 1/2: title + band/status + detail + cheatsheet.
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

--- 1/1: title + band/status + detail + cheatsheet.
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
