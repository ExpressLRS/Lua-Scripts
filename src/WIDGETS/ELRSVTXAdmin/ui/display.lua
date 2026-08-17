---------------------------------------------------------------------------
-- Minimized Display Layer                                               --
-- Loaded via loadScript() from ELRSVTXAdmin/loadable.lua with           --
-- (VTXAdmin, PresetsStorage); returns VTXDisplay, WidgetLayout.         --
--                                                                       --
-- VTXDisplay is the read-model the per-screen ui/ files consume:        --
-- zero-arg formatters passed by reference as LVGL text/color/visible    --
-- callbacks, plus the card's composite rows. WidgetLayout builds the    --
-- minimized zone containers.                                            --
---------------------------------------------------------------------------

local VTXAdmin, PresetsStorage = ...

-- ============================================================================
-- WidgetLayout: minimized zone container builders
-- ============================================================================

local WidgetLayout = {}

--- pad overrides the container's border padding, for a tier where the default
--- costs more height than it has. Pass a table to keep the horizontal padding
--- while trimming the vertical: the left edge is what a widget in the zone
--- above or beside lines its own text up against, so it is not the one to give.
--- rounded is the card's corner radius, on the fill alone: the box draws
--- nothing, so its square corners cannot show.
function WidgetLayout.column(w, h, opa, children, pad, rounded)
  lvgl.build({
    {
      type = lvgl.RECTANGLE,
      x = 0,
      y = 0,
      w = w,
      h = h,
      color = COLOR_THEME_PRIMARY2,
      opacity = opa,
      filled = true,
      rounded = rounded,
    },
    {
      type = lvgl.BOX,
      x = 0,
      y = 0,
      w = w,
      h = h,
      align = LEFT,
      flexFlow = lvgl.FLOW_COLUMN,
      flexPad = 0,
      borderPad = pad or lvgl.PAD_SMALL,
      children = children,
    },
  })
end

function WidgetLayout.row(w, h, opa, children, rounded)
  lvgl.build({
    {
      type = lvgl.RECTANGLE,
      x = 0,
      y = 0,
      w = w,
      h = h,
      color = COLOR_THEME_PRIMARY2,
      opacity = opa,
      filled = true,
      rounded = rounded,
    },
    {
      type = lvgl.BOX,
      x = 0,
      y = 0,
      w = w,
      h = h,
      align = LEFT + VCENTER,
      flexFlow = lvgl.FLOW_ROW,
      flexPad = lvgl.PAD_TINY,
      borderPad = lvgl.PAD_SMALL,
      children = children,
    },
  })
end

-- ============================================================================
-- VTXDisplay: shared display formatters for minimized UI
-- ============================================================================

local VTXDisplay = {}

--- True when VTX is tuned to a band (band+channel should be shown in fixed column).
function VTXDisplay.showChannel()
  return VTXAdmin.isTuned()
end

--- True when a status message should be shown (loading, error, VTX off).
function VTXDisplay.showStatus()
  return not VTXAdmin.isTuned()
end

--- Band + channel string (e.g. "F6", "R4") when VTX is tuned, "" otherwise.
function VTXDisplay.bandChannel()
  if not VTXAdmin.isTuned() then
    return ""
  end
  return table.concat({ VTXAdmin.state.bandLetter, VTXAdmin.state.channel })
end

--- Short status message for non-VTX states, "" when VTX is tuned.
function VTXDisplay.statusText()
  if not VTXAdmin.hasModule() then
    return "No module"
  end
  if not VTXAdmin.isActive() then
    return "Loading..."
  end
  if VTXAdmin.state.band == 0 then
    return "VTX Off"
  end
  return ""
end

--- The hero and the active preset cell take the theme's accent -- the reading
--- is what the widget exists to show, and the accent is what "the current one"
--- looks like everywhere else in EdgeTX. A confirmed pit mode outranks it:
--- red on the reading itself is the one signal worth recolouring the hero for.
--- An aux binding is not an assertion, so it stays on the accent.
function VTXDisplay.heroColor()
  if VTXAdmin.state.pitmode then
    return RED
  end
  return COLOR_THEME_FOCUS
end

--- Pit mode as the header's right end spells it. "" when no power is set:
--- ExpressLRS cannot send pit mode without it, and the firmware hides the
--- field. A switch binding names the switch rather than asserting a position
--- the folder name does not carry.
function VTXDisplay.pitHeaderText()
  if not VTXAdmin.hasPower() then
    return ""
  end
  if VTXAdmin.state.pitmode then
    return "PIT ON"
  end
  if VTXAdmin.state.pitmodeAux then
    return table.concat({ "PIT ", VTXAdmin.state.pitmodeAux })
  end
  return "PIT OFF"
end

--- Red only when pit mode is confirmed on.
function VTXDisplay.pitHeaderColor()
  return VTXAdmin.state.pitmode and RED or COLOR_THEME_SECONDARY1
end

--- The power level on its own, for the power row's right end.
function VTXDisplay.powerValueText()
  return tostring(VTXAdmin.state.power)
end

--- The header row: the widget's name in the muted caption colour on the left,
--- the pit state pinned to the right edge of the same line.
--- Not a flex row: a right-aligned label needs an explicit width to align
--- inside, so the two labels sit in a plain box at absolute x and the hidden
--- pit label cannot reflow the name.
--- w is the zone width; the box subtracts the container's own padding so the
--- right edge lands where every other row's content ends.
function VTXDisplay.buildHeader(w)
  local cw = w - 2 * lvgl.PAD_SMALL
  return {
    type = lvgl.BOX,
    w = cw,
    children = {
      {
        type = lvgl.LABEL,
        x = 0,
        y = 0,
        font = SMLSIZE,
        color = COLOR_THEME_SECONDARY1,
        text = "VTX Admin",
      },
      {
        type = lvgl.LABEL,
        x = 0,
        y = 0,
        w = cw,
        align = RIGHT,
        font = SMLSIZE,
        color = VTXDisplay.pitHeaderColor,
        text = VTXDisplay.pitHeaderText,
        visible = VTXDisplay.showChannel,
      },
    },
  }
end

--- The hero pair for a flex column: the status while the VTX is quiet, the
--- band and channel in the tier's display font once it is tuned. Two children
--- to append in order -- a hidden flex child costs no height, so only the live
--- one takes a row.
function VTXDisplay.buildHero(font)
  return {
    type = lvgl.LABEL,
    align = LEFT,
    font = BOLD,
    color = COLOR_THEME_PRIMARY1,
    text = VTXDisplay.statusText,
    visible = VTXDisplay.showStatus,
  }, {
    type = lvgl.LABEL,
    align = LEFT,
    font = font,
    color = VTXDisplay.heroColor,
    text = VTXDisplay.bandChannel,
    visible = VTXDisplay.showChannel,
  }
end

--- The 6POS presets as a row of six equal cells, the latched one lit in the
--- accent. The row is always exactly six cells and never reflows: a preset
--- without a band shows "--" in its cell rather than giving the cell up, and
--- the position is the cell's place in the row, so the labels drop the "n:"
--- prefix the text cheatsheet needed.
--- The active cell recolours through closures -- the cells themselves never
--- move or resize, which keeps the row to zero layout work per frame.
--- spec.w is the width the row may span; spec.cellH, spec.font and
--- spec.rounded come from the screen file's own scale.
--- Returns nil when the presets feature is off or no module is present, the
--- same build-time gates the text cheatsheet had; the runtime module gate
--- rides the row's visible.
function VTXDisplay.buildCells(spec)
  if not VTXAdmin.hasModule() then
    return nil
  end
  if not PresetsStorage.enabled then
    return nil
  end
  -- The mock's own cell gap. Tighter than the theme paddings, and fixed: six
  -- cells only read as one control when the gaps between them are beats, not
  -- breaks.
  local gap = 4
  local cellW = math.floor((spec.w - 5 * gap) / 6)
  local font = spec.font or SMLSIZE
  local textY = math.floor((spec.cellH - select(2, lcd.sizeText("0", font))) / 2)
  local cells = {}
  for i = 1, 6 do
    local idx = i
    cells[#cells + 1] = {
      type = lvgl.RECTANGLE,
      w = cellW,
      h = spec.cellH,
      filled = true,
      rounded = spec.rounded,
      color = function()
        return (PresetsStorage.latch.lastPos == idx) and COLOR_THEME_FOCUS or COLOR_THEME_DISABLED
      end,
      -- The inactive cells sit back at part opacity so the lit one carries
      -- the row; opacity is background-only on a rectangle, so the label
      -- inside keeps its full weight either way.
      opacity = function()
        return (PresetsStorage.latch.lastPos == idx) and 255 or 90
      end,
      children = {
        {
          type = lvgl.LABEL,
          x = 0,
          y = math.max(0, textY),
          w = cellW,
          align = CENTER,
          font = font,
          color = function()
            return (PresetsStorage.latch.lastPos == idx) and COLOR_THEME_PRIMARY2 or COLOR_THEME_SECONDARY1
          end,
          text = function()
            local p = PresetsStorage.items[idx]
            if p.band == 0 then
              return "--"
            end
            return table.concat({ VTXAdmin.BAND_LETTERS[p.band] or "?", p.channel })
          end,
        },
      },
    }
  end
  return {
    type = lvgl.BOX,
    flexFlow = lvgl.FLOW_ROW,
    borderPad = 0,
    flexPad = gap,
    align = LEFT,
    visible = VTXAdmin.hasModule,
    children = cells,
  }
end

--- The power row at the card's foot: the caption on the left, the level
--- right-aligned. Same box shape as the header, and hidden whole -- a flex
--- column drops a hidden child rather than reserving its line, so a VTX
--- reporting no power closes the row instead of leaving a gap.
function VTXDisplay.buildPowerRow(w)
  local cw = w - 2 * lvgl.PAD_SMALL
  return {
    type = lvgl.BOX,
    w = cw,
    visible = VTXAdmin.hasPower,
    children = {
      {
        type = lvgl.LABEL,
        x = 0,
        y = 0,
        font = SMLSIZE,
        color = COLOR_THEME_SECONDARY1,
        text = "Power",
      },
      {
        type = lvgl.LABEL,
        x = 0,
        y = 0,
        w = cw,
        align = RIGHT,
        font = SMLSIZE,
        color = COLOR_THEME_PRIMARY1,
        text = VTXDisplay.powerValueText,
      },
    },
  }
end

--- The headline row: the widget's name, then the band and channel, on one line
--- at one size. For the tiers with no row to spare for a title of its own.
--- Both at one size on purpose. The name is a caption in the muted theme colour
--- and the reading takes the accent, which is what lets them share a line
--- without competing -- where two type sizes in one breath read as two
--- importances, and a name shrunk beside its own value reads as an afterthought.
--- extras are trailing labels, for a tier with nowhere else to put them.
function VTXDisplay.buildHeadline(w, font, extras)
  local children = {
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = font,
      color = COLOR_THEME_SECONDARY1,
      text = "VTX Admin",
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = font,
      color = VTXDisplay.heroColor,
      text = VTXDisplay.bandChannel,
      visible = VTXDisplay.showChannel,
    },
  }
  for i = 1, extras and #extras or 0 do
    children[#children + 1] = extras[i]
  end
  return {
    type = lvgl.BOX,
    w = w,
    align = LEFT + VCENTER,
    flexFlow = lvgl.FLOW_ROW,
    -- Wider than the tier's other gaps. At one size and with only colour telling
    -- the caption from the reading, PAD_TINY leaves "VTX Admin" and "R1" reading
    -- as one run-together word.
    flexPad = lvgl.PAD_MEDIUM,
    borderPad = 0,
    children = children,
  }
end

return VTXDisplay, WidgetLayout
