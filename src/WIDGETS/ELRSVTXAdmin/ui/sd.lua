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
  -- The 1/6 tier stacks the preset cells on a second row from here up,
  -- and only where the six cells have the width for it.
  sixthStackH = 40,
  sixthStackW = 180,
  quarterH = 70,
  thirdH = 100,
  halfH = 125,
  -- From here up a zone spans the screen rather than half of it. Past the top
  -- bar this only gates the 1/6 inline row's preset cells, which need the
  -- width of a full-screen zone to share one line with the readings.
  wideW = 340,
}

-- Every tier that draws the preset cells sizes them here: cellH is the cell
-- box in this screen's pixels, cells the font inside it.
WidgetUI.fonts = {
  sixth = { status = BOLD, cells = SMLSIZE, cellH = 16 },
  quarter = { status = BOLD, cells = SMLSIZE, cellH = 20 },
  third = { hero = MIDSIZE, cells = SMLSIZE, cellH = 22 },
  half = { hero = MIDSIZE, cells = STDSIZE, cellH = 24 },
  full = { hero = DBLSIZE, cells = STDSIZE, cellH = 26 },
}

-- The corner radius on the preset cells, in this screen's pixels.
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
    color = COLOR_THEME_SECONDARY1,
    text = VTXDisplay.statusText,
    visible = VTXDisplay.showStatus,
  }
end

--- The preset cells sized for one tier; cellH overrides the tier's own for a
--- layout that sizes them to its zone. nil when the presets feature is off,
--- same as the builder.
local function cells(f, cellH)
  return VTXDisplay.buildCells({
    cellH = cellH or f.cellH,
    font = f.cells,
    rounded = CELL_ROUNDED,
  })
end

--- The card the 1/3, 1/2 and 1/1 tiers share: header with the pit state, the
--- hero with its power level riding beside it, the preset cells.
local function cardRows(f, w)
  local heroStatus, hero = VTXDisplay.buildHero(f.hero)
  local rows = { VTXDisplay.buildHeader(w), heroStatus, hero }
  rows[#rows + 1] = cells(f)
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
--- falls back to a single inline row; the name leads it where a full-screen
--- zone has the width for both. Fixed-width band column prevents layout
--- jumping when values change.
function WidgetUI.buildSixth(w, h, opa)
  local bp = WidgetUI.breakpoints
  local f = WidgetUI.fonts.sixth
  if h >= bp.sixthStackH and w >= bp.sixthStackW then
    local cellRow = cells(f)
    if cellRow then
      WidgetLayout.column(w, h, opa, {
        VTXDisplay.buildHeadline(w, f.status, { statusLabel() }),
        cellRow,
      }, {
        left = lvgl.PAD_SMALL,
        right = lvgl.PAD_SMALL,
        top = lvgl.PAD_TINY,
        -- The cells sit against this edge, and flush against it their fills
        -- read as clipped; the top keeps the trim because text carries its
        -- own leading.
        bottom = lvgl.PAD_SMALL,
      })
      return
    end
  end

  local columns = {}
  if w >= bp.wideW then
    columns[#columns + 1] = {
      type = lvgl.LABEL,
      align = LEFT,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = "VTX Admin",
    }
  end
  columns[#columns + 1] = statusLabel()
  columns[#columns + 1] = {
    type = lvgl.LABEL,
    -- Reserved against the widest reading rather than a screen fraction, so
    -- the row stays put when the channel changes and gives the rest to the
    -- cells.
    w = (lcd.sizeText("R8", f.status)) + lvgl.PAD_SMALL,
    font = f.status,
    color = VTXDisplay.heroColor,
    text = VTXDisplay.bandChannel,
    visible = VTXDisplay.showChannel,
  }
  columns[#columns + 1] = {
    type = lvgl.LABEL,
    align = LEFT,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = VTXDisplay.powerShort,
    visible = VTXDisplay.showChannel,
  }
  if w >= bp.wideW then
    -- The inline row is the cells' whole zone, so they take its height -- up
    -- to a comfortable bubble around the font -- rather than the stacked
    -- tier's cell height.
    local fontH = select(2, lcd.sizeText("0", f.cells))
    columns[#columns + 1] = cells(f, math.min(h - 2 * lvgl.PAD_SMALL, fontH + 2 * lvgl.PAD_SMALL))
  end

  WidgetLayout.row(w, h, opa, columns)
end

--- 1/4: two rows. Row 1: the headline, carrying the status while the VTX is
--- quiet -- this tier has no spare row to hold it. Row 2: the preset cells.
function WidgetUI.buildQuarter(w, h, opa)
  local f = WidgetUI.fonts.quarter
  local rows = {
    VTXDisplay.buildHeadline(w, f.status, { statusLabel() }),
  }
  rows[#rows + 1] = cells(f)
  WidgetLayout.column(w, h, opa, rows, {
    left = lvgl.PAD_SMALL,
    right = lvgl.PAD_SMALL,
    top = lvgl.PAD_SMALL,
    -- A breath more than the default: the cells are the bottom row, and their
    -- fills flush against the edge read as clipped.
    bottom = lvgl.PAD_SMALL + lvgl.PAD_TINY,
  })
end

--- 1/3: the whole card at the tier's own type scale.
function WidgetUI.buildThird(w, h, opa)
  WidgetLayout.column(w, h, opa, cardRows(WidgetUI.fonts.third, w))
end

--- 1/2: the whole card.
function WidgetUI.buildHalf(w, h, opa)
  WidgetLayout.column(w, h, opa, cardRows(WidgetUI.fonts.half, w))
end

--- 1/1: the whole card, one step up in type.
function WidgetUI.buildFull(w, h, opa)
  WidgetLayout.column(w, h, opa, cardRows(WidgetUI.fonts.full, w))
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
