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
WidgetUI.breakpoints = {
  topBarW = 100,
  sixthH = 50,
  -- The 1/6 tier stacks the preset cells on a second row from here up,
  -- and only where the six cells have the width for it.
  sixthStackH = 40,
  sixthStackW = 180,
  quarterH = 62,
  thirdH = 118,
  halfH = 147,
  -- From here up a zone spans the screen rather than half of it. Past the top
  -- bar this only gates the 1/6 inline row's preset cells, which need the
  -- width of a full-screen zone to share one line with the readings.
  wideW = 340,
}

-- Every tier that draws the preset cells sizes them here: cellH is the cell
-- box in this screen's pixels, cells the font inside it.
-- The third tier's hero stays BOLD: its rung starts at 62px here, which is
-- too short for MIDSIZE over a cell row.
WidgetUI.fonts = {
  sixth = { status = BOLD, cells = SMLSIZE, cellH = 14 },
  quarter = { status = BOLD, cells = SMLSIZE, cellH = 18 },
  third = { hero = BOLD, cells = SMLSIZE, cellH = 18 },
  half = { hero = MIDSIZE, cells = STDSIZE, cellH = 20 },
  full = { hero = DBLSIZE, cells = STDSIZE, cellH = 22 },
}

-- The card's corner radius, and the smaller one on the preset cells, in this
-- screen's pixels.
local ROUNDED = 6
local CELL_ROUNDED = 4

-- ============================================================================
-- Minimized layout builders (by widget height tier)
-- ============================================================================

local TopBarUI = loadScript("/WIDGETS/ELRSVTXAdmin/ui/topbar.lua")({
  VTXDisplay = VTXDisplay,
})

--- The status line as a flex child, for the tiers whose headline has to carry
--- it inline: "VTX Admin  Loading..." is the whole first line while the VTX
--- is quiet.
local function statusLabel()
  return {
    type = lvgl.LABEL,
    align = LEFT,
    font = BOLD,
    color = COLOR_THEME_PRIMARY1,
    text = VTXDisplay.statusText,
    visible = VTXDisplay.showStatus,
  }
end

--- The preset cells sized for one tier, spanning the container's content
--- width. nil when the presets feature is off, same as the builder.
local function cells(f, w)
  return VTXDisplay.buildCells({
    w = w - 2 * lvgl.PAD_SMALL,
    cellH = f.cellH,
    font = f.cells,
    rounded = CELL_ROUNDED,
  })
end

--- The card the 1/2 and 1/1 tiers share: header with the pit state, the hero,
--- the preset cells, the power row at the foot.
local function cardRows(f, w)
  local heroStatus, hero = VTXDisplay.buildHero(f.hero)
  local rows = { VTXDisplay.buildHeader(w), heroStatus, hero }
  rows[#rows + 1] = cells(f, w)
  rows[#rows + 1] = VTXDisplay.buildPowerRow(w)
  return rows
end

--- 1/6: the headline over the preset cells, wherever the zone holds two rows.
--- Two rows are what make room for the name: with the cells on the row below,
--- the one above is left to the name and the reading, and neither has to give.
--- It fits at all only on the container's padding: at this tier PAD_SMALL top
--- and bottom is the whole difference between two rows and one. So the
--- vertical padding gives and the left edge keeps it -- that edge is what a
--- widget in the zone above lines its own text up against.
--- A zone too short for two rows, or too narrow to carry six cells on one,
--- falls back to a single inline row, which has no width to spare for the
--- name. Fixed-width band column prevents layout jumping when values change.
function WidgetUI.buildSixth(w, h, opa)
  local bp = WidgetUI.breakpoints
  local f = WidgetUI.fonts.sixth
  if h >= bp.sixthStackH and w >= bp.sixthStackW then
    local cellRow = cells(f, w)
    if cellRow then
      WidgetLayout.column(w, h, opa, {
        VTXDisplay.buildHeadline(w, f.status, { statusLabel() }),
        cellRow,
      }, {
        left = lvgl.PAD_SMALL,
        right = lvgl.PAD_SMALL,
        top = lvgl.PAD_TINY,
        bottom = lvgl.PAD_TINY,
      }, ROUNDED)
      return
    end
  end

  local c1w = math.floor(w * 0.22)
  local columns = {
    statusLabel(),
    {
      type = lvgl.LABEL,
      w = c1w,
      font = f.status,
      color = VTXDisplay.heroColor,
      text = VTXDisplay.bandChannel,
      visible = VTXDisplay.showChannel,
    },
  }
  if w >= bp.wideW then
    columns[#columns + 1] = VTXDisplay.buildCells({
      w = math.floor(w * 0.55),
      cellH = f.cellH,
      font = f.cells,
      rounded = CELL_ROUNDED,
    })
  end

  WidgetLayout.row(w, h, opa, columns, ROUNDED)
end

--- 1/4: two rows. Row 1: the headline, carrying the status while the VTX is
--- quiet -- this tier has no spare row to hold it. Row 2: the preset cells.
function WidgetUI.buildQuarter(w, h, opa)
  local f = WidgetUI.fonts.quarter
  local rows = {
    VTXDisplay.buildHeadline(w, f.status, { statusLabel() }),
  }
  rows[#rows + 1] = cells(f, w)
  WidgetLayout.column(w, h, opa, rows, nil, ROUNDED)
end

--- 1/3: the header with the pit state, the hero on its own line, the cells.
--- The power row is what gives at this height; a confirmed pit mode still
--- shows, in the header and on the hero's colour.
function WidgetUI.buildThird(w, h, opa)
  local f = WidgetUI.fonts.third
  local heroStatus, hero = VTXDisplay.buildHero(f.hero)
  local rows = { VTXDisplay.buildHeader(w), heroStatus, hero }
  rows[#rows + 1] = cells(f, w)
  WidgetLayout.column(w, h, opa, rows, nil, ROUNDED)
end

--- 1/2: the whole card.
function WidgetUI.buildHalf(w, h, opa)
  WidgetLayout.column(w, h, opa, cardRows(WidgetUI.fonts.half, w), nil, ROUNDED)
end

--- 1/1: the whole card, one step up in type.
function WidgetUI.buildFull(w, h, opa)
  WidgetLayout.column(w, h, opa, cardRows(WidgetUI.fonts.full, w), nil, ROUNDED)
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
