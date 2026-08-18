---------------------------------------------------------------------------
-- VTX Administrator Widget - UI for 320x480 (Portrait)                  --
-- FlySky EL18 — vertical screen                                         --
---------------------------------------------------------------------------

local ctx = ...
local bgOpacity = ctx.bgOpacity
local VTXDisplay = ctx.VTXDisplay
local WidgetLayout = ctx.WidgetLayout

local WidgetUI = {}

-- Breakpoints: absolute pixel values for 320x480 portrait.
-- Portrait zones are tall for their width, so every rung starts higher than
-- on the landscape screens. No stacked 1/6 variant: below sixthH the zone is
-- a custom sliver with one row in it.
WidgetUI.breakpoints = {
  topBarW = 80,
  sixthH = 70,
  quarterH = 100,
  thirdH = 140,
  halfH = 210,
  -- Past the top bar this only gates the 1/6 inline row's preset cells; the
  -- screen itself is 320 wide, so a full-width zone clears it.
  wideW = 240,
}

-- Every tier that draws the preset cells sizes them here: cellH is the cell
-- box in this screen's pixels, cells the font inside it.
WidgetUI.fonts = {
  -- No cellH: the 1/6 inline row sizes its cells to the zone itself.
  sixth = { status = BOLD, cells = SMLSIZE },
  quarter = { status = BOLD, cells = SMLSIZE, cellH = 18 },
  third = { hero = MIDSIZE, cells = SMLSIZE, cellH = 18 },
  half = { hero = MIDSIZE, cells = SMLSIZE, cellH = 20 },
  full = { hero = DBLSIZE, cells = STDSIZE, cellH = 24 },
}

-- The corner radius on the preset cells, in this screen's pixels.
local CELL_ROUNDED = 3

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

--- 1/6: a single inline row -- the name where a full-width zone has the
--- width for it, the status or the band and channel with its power level,
--- then the preset cells. No stacked variant here.
--- Fixed-width band column prevents layout jumping when values change.
function WidgetUI.buildSixth(w, h, opa)
  local bp = WidgetUI.breakpoints
  local f = WidgetUI.fonts.sixth
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
    -- to a comfortable bubble around the font.
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
