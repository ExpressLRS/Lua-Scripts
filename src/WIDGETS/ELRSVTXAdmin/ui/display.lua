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
function WidgetLayout.column(w, h, opa, children, pad)
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

function WidgetLayout.row(w, h, opa, children)
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

--- The power level in the terse form that rides beside the channel on the
--- one-line tiers, e.g. "P2". "" when no power is set: ExpressLRS cannot
--- report one, and a bare "P" would read as a reading stuck mid-arrival.
function VTXDisplay.powerShort()
  if not VTXAdmin.hasPower() then
    return ""
  end
  return table.concat({ "P", VTXAdmin.state.power })
end

--- The same reading said in full, e.g. "Power 2", for the hero row -- at that
--- size the terse form reads as part of the channel rather than as its own
--- reading.
function VTXDisplay.powerLong()
  if not VTXAdmin.hasPower() then
    return ""
  end
  return table.concat({ "Power ", VTXAdmin.state.power })
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

--- The hero pair for a flex column: the status while the VTX is quiet, and
--- once it is tuned the band and channel in the tier's display font with
--- "Power 2" sat on its baseline beside it. Two children to append in order
--- -- a hidden flex child costs no height, so only the live one takes a row.
--- The status takes the same display font as the reading it stands in for:
--- the two swap over one row, and at two sizes everything below them jumps
--- the moment the VTX loads.
--- A plain box with absolute children rather than a flex row: small type
--- beside a large number sits on its baseline, not its top, and flex has no
--- way to say that. Same mechanics as the telemetry hero's caption -- the
--- power's x is reserved against the widest reading, so it never moves when
--- the channel changes.
function VTXDisplay.buildHero(font)
  local heroH = select(2, lcd.sizeText("0", font))
  -- Four fifths of the height difference, not all of it: line boxes carry
  -- descender room in proportion to the font, so aligning box bottoms sinks
  -- the small text below the shared baseline by the difference in descent.
  local drop = math.max(0, math.floor((heroH - select(2, lcd.sizeText("0", SMLSIZE))) * 4 / 5))
  return {
    type = lvgl.LABEL,
    align = LEFT,
    font = font,
    -- The muted theme colour, not the text primary: at the hero size a black
    -- "Loading..." reads as the reading itself, and a status is background.
    color = COLOR_THEME_SECONDARY1,
    text = VTXDisplay.statusText,
    visible = VTXDisplay.showStatus,
  }, {
    type = lvgl.BOX,
    h = heroH,
    visible = VTXDisplay.showChannel,
    children = {
      {
        type = lvgl.LABEL,
        x = 0,
        y = 0,
        font = font,
        color = VTXDisplay.heroColor,
        text = VTXDisplay.bandChannel,
      },
      {
        type = lvgl.LABEL,
        x = (lcd.sizeText("R8", font)) + lvgl.PAD_MEDIUM,
        y = drop,
        font = SMLSIZE,
        color = COLOR_THEME_SECONDARY1,
        text = VTXDisplay.powerLong,
      },
    },
  }
end

--- The 6POS presets as a row of six fixed-width cells, the latched one lit in
--- the accent. Always exactly six cells: an unset preset shows "--" rather
--- than giving its cell up, so the position is the cell's place in the row.
--- Everything live rides in closures -- colours and label text -- so the
--- cells themselves never move or resize, and presets edited in another
--- instance's editor show up without a rebuild.
--- spec.cellH, spec.font and spec.rounded come from the screen file's scale.
--- Returns nil when the presets feature is off or no module is present.
function VTXDisplay.buildCells(spec)
  if not (VTXAdmin.hasModule() and PresetsStorage.enabled) then
    return nil
  end
  local font = spec.font or SMLSIZE
  -- One width for all six, measured against the widest label a cell can carry.
  local cellW = math.max((lcd.sizeText("R8", font)), (lcd.sizeText("--", font))) + 2 * lvgl.PAD_SMALL
  local function isActive(idx)
    return PresetsStorage.latch.lastPos == idx
  end
  local function cellText(idx)
    local p = PresetsStorage.items[idx]
    if p.band == 0 then
      return "--"
    end
    return table.concat({ VTXAdmin.BAND_LETTERS[p.band] or "?", p.channel })
  end
  local cells = {}
  for idx = 1, 6 do
    cells[idx] = {
      type = lvgl.RECTANGLE,
      w = cellW,
      h = spec.cellH,
      filled = true,
      rounded = spec.rounded,
      color = function()
        return isActive(idx) and COLOR_THEME_FOCUS or COLOR_THEME_DISABLED
      end,
      -- Part opacity is background-only on a rectangle, so the inactive cells
      -- sit back while their labels keep full weight.
      opacity = function()
        return isActive(idx) and 255 or 90
      end,
      children = {
        {
          type = lvgl.LABEL,
          w = cellW,
          align = CENTER + VCENTER,
          font = font,
          color = function()
            return isActive(idx) and COLOR_THEME_PRIMARY2 or COLOR_THEME_SECONDARY1
          end,
          text = function()
            return cellText(idx)
          end,
        },
      },
    }
  end
  return {
    type = lvgl.BOX,
    flexFlow = lvgl.FLOW_ROW,
    borderPad = 0,
    -- Tighter than the theme paddings: six cells read as one control when the
    -- gaps between them are beats, not breaks.
    flexPad = 4,
    align = LEFT,
    visible = VTXAdmin.hasModule,
    children = cells,
  }
end

--- The headline row: the widget's name, then the band and channel, on one line.
--- For the tiers with no row to spare for a title of its own. The name keeps
--- the small muted caption type every other tier titles itself with; only the
--- reading takes the tier's font and the accent, so the emphasis falls on the
--- reading at every widget size.
--- extras are trailing labels, for a tier with nowhere else to put them.
function VTXDisplay.buildHeadline(w, font, extras)
  local children = {
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = SMLSIZE,
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
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = VTXDisplay.powerShort,
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
