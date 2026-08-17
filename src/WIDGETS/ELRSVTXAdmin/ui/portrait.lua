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
  sixth = { status = BOLD, cells = SMLSIZE, cellH = 12 },
  quarter = { status = BOLD, cells = SMLSIZE, cellH = 14 },
  third = { hero = MIDSIZE, cells = SMLSIZE, cellH = 14 },
  half = { hero = MIDSIZE, cells = SMLSIZE, cellH = 16 },
  full = { hero = DBLSIZE, cells = STDSIZE, cellH = 18 },
}

-- The card's corner radius, and the smaller one on the preset cells, in this
-- screen's pixels.
local ROUNDED = 4
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

--- 1/6: a single inline row -- the status or the band and channel, then the
--- preset cells where the width allows. No stacked variant here; the name is
--- what this tier gives up.
--- Fixed-width band column prevents layout jumping when values change.
function WidgetUI.buildSixth(w, h, opa)
  local bp = WidgetUI.breakpoints
  local f = WidgetUI.fonts.sixth
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
