---------------------------------------------------------------------------
-- VTX Administrator Widget - UI for 480x272 (SD)                        --
-- Standard definition landscape (TX16S, TX16S MAX, TX16S Mark II)       --
---------------------------------------------------------------------------

local ctx = ...
local bgOpacity = ctx.bgOpacity
local VTXDisplay = ctx.VTXDisplay
local WidgetLayout = ctx.WidgetLayout

local WidgetUI = {}

-- Breakpoints: absolute pixel values for 480x272.
WidgetUI.breakpoints = {
  topBarW = 100,
  sixthH = 50,
  -- The 1/6 tier stacks the cheatsheet on a second row from here up,
  -- and only where the six columns have the width for it.
  sixthStackH = 40,
  sixthStackW = 180,
  quarterH = 70,
  thirdH = 100,
  halfH = 125,
  -- From here up a 1/3 zone spans the screen rather than half of it: the whole
  -- cheatsheet goes on one row, and the type steps up to the size that width
  -- affords.
  thirdWideW = 340,
}

WidgetUI.fonts = {
  sixth = { status = BOLD },
  quarter = { status = BOLD },
  third = { status = BOLD, cheatsheet = SMLSIZE },
  -- A full-width 1/3 zone is 400px across and 80 tall for two lines. At the
  -- half-width sizes those two lines fill its top third and leave the rest of
  -- the panel empty, so both of them step up.
  thirdWide = { status = MIDSIZE, cheatsheet = STDSIZE },
  half = { hero = BOLD, detail = SMLSIZE, cheatsheet = STDSIZE },
  full = { hero = DBLSIZE, detail = SMLSIZE, cheatsheet = STDSIZE },
}

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSVTXAdmin/ui/topbar.lua")({
  VTXDisplay = VTXDisplay,
})

--- 1/6: band + detail on one row, with the cheatsheet inline where the zone is
--- wide enough to carry all three.
--- A narrow zone stacks the cheatsheet under them instead, when the height and
--- the six columns both measure. It fits at all only on the container's
--- padding: at this tier PAD_SMALL top and bottom is the whole difference
--- between two rows and one. So the vertical padding gives and the left edge
--- keeps it -- that edge is what a widget in the zone above lines its own text
--- up against.
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
    WidgetLayout.row(w, h, opa, columns)
    return
  end

  local bp = WidgetUI.breakpoints
  local cheatsheet = nil
  if h >= bp.sixthStackH and w >= bp.sixthStackW then
    cheatsheet = VTXDisplay.buildCheatsheet()
  end
  if cheatsheet == nil then
    WidgetLayout.row(w, h, opa, columns)
    return
  end

  -- Once the cheatsheet moves off the row there is width for the name, so the
  -- widget gets to say what it is. Power and pit mode pay for it in their terse
  -- forms -- "P2 Pit" rather than "P2 Pit Mode Off" -- because the name and the
  -- reading come first and this row cannot hold all three in full.
  WidgetLayout.column(w, h, opa, {
    VTXDisplay.buildHeadline(w, WidgetUI.fonts.sixth.status, {
      {
        type = lvgl.LABEL,
        align = LEFT,
        font = SMLSIZE,
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
    }),
    cheatsheet,
  }, { left = lvgl.PAD_SMALL, right = lvgl.PAD_SMALL, top = lvgl.PAD_TINY, bottom = lvgl.PAD_TINY })
end

--- 1/4: two rows. Row 1: the headline plus power. Row 2: cheatsheet.
--- Power rides the headline rather than taking a row: two rows is all there is
--- here, and the cheatsheet has the other one.
--- The status line rides it too, which is the one place it does. This tier has no
--- spare row to hold it, so "VTX Admin  Loading..." is the whole first line while
--- the VTX is quiet -- and that is why the fit below is measured against the
--- status string as well as the band.
function WidgetUI.buildQuarter(w, h, opa)
  local font = WidgetUI.fonts.quarter.status
  local rows = {
    VTXDisplay.buildHeadline(w, font, {
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
        font = BOLD,
        color = VTXDisplay.mainColor,
        text = VTXDisplay.statusText,
        visible = VTXDisplay.showStatus,
      },
    }),
  }
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
  local wide = w >= WidgetUI.breakpoints.thirdWideW
  local f = wide and WidgetUI.fonts.thirdWide or WidgetUI.fonts.third
  local extras
  if wide then
    extras = {
      {
        type = lvgl.LABEL,
        align = LEFT,
        font = SMLSIZE,
        color = COLOR_THEME_SECONDARY1,
        text = VTXDisplay.detailLine,
        visible = VTXDisplay.showChannel,
      },
    }
  else
    extras = {
      {
        type = lvgl.LABEL,
        align = LEFT,
        font = SMLSIZE,
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
    }
  end
  local rows = {
    VTXDisplay.buildHeadline(w, f.status, extras),
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
