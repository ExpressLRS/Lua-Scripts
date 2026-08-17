---------------------------------------------------------------------------
-- Minimized Display Layer                                               --
-- Loaded via loadScript() from ELRSVTXAdmin/loadable.lua with           --
-- (VTXAdmin, PresetsStorage); returns VTXDisplay, WidgetLayout.         --
--                                                                       --
-- VTXDisplay is the read-model the per-screen ui/ files consume:        --
-- zero-arg formatters passed by reference as LVGL text/color/visible    --
-- callbacks. WidgetLayout builds the minimized zone containers.         --
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

function VTXDisplay.powerShort()
  if not VTXAdmin.hasPower() then
    return ""
  end
  return table.concat({ "P", VTXAdmin.state.power })
end

function VTXDisplay.powerLong()
  if not VTXAdmin.hasPower() then
    return ""
  end
  return table.concat({ "Power ", VTXAdmin.state.power })
end

--- Pit mode state. "" when no power is set: ExpressLRS cannot send pit mode without it.
--- A switch binding names the switch rather than asserting a position the folder name
--- does not carry.
function VTXDisplay.pitText()
  if not VTXAdmin.hasPower() then
    return ""
  end
  if VTXAdmin.state.pitmode then
    return "Pit Mode On"
  end
  if VTXAdmin.state.pitmodeAux then
    return table.concat({ "Pit Mode ", VTXAdmin.state.pitmodeAux })
  end
  return "Pit Mode Off"
end

--- As pitText, but reports a disabled VTX instead of falling silent.
function VTXDisplay.pitTextLong()
  if VTXAdmin.isDisabled() then
    return "VTX Disabled"
  end
  return VTXDisplay.pitText()
end

--- Terse flag for narrow tiers. Only a confirmed pit mode is worth the width.
function VTXDisplay.pitShort()
  return VTXAdmin.state.pitmode and "Pit" or ""
end

--- Red only when pit mode is confirmed on. An aux binding is not an assertion.
function VTXDisplay.pitColor()
  return VTXAdmin.state.pitmode and RED or COLOR_THEME_SECONDARY1
end

function VTXDisplay.detailLine()
  if not VTXAdmin.hasPower() then
    return ""
  end
  return table.concat({ VTXDisplay.powerShort(), " ", VTXDisplay.pitText() })
end

function VTXDisplay.detailLong()
  if VTXAdmin.isDisabled() then
    return "VTX Disabled"
  end
  if not VTXAdmin.hasPower() then
    return ""
  end
  return table.concat({ VTXDisplay.powerLong(), "  ", VTXDisplay.pitText() })
end

--- Whether detailLong() has anything to say. On the tiers that give it a column
--- row of its own an empty label still costs a full line, and that line is the
--- gap that opens between the band and the cheatsheet on a VTX reporting no
--- power. A flex column drops hidden children rather than reserving their space,
--- so this closes the gap instead of merely blanking it.
function VTXDisplay.hasDetail()
  return VTXAdmin.isDisabled() or VTXAdmin.hasPower()
end

function VTXDisplay.mainColor()
  if VTXAdmin.state.pitmode then
    return RED
  end
  return COLOR_THEME_PRIMARY1
end

function VTXDisplay.build6posLabels(font)
  if not VTXAdmin.hasModule() then
    return {}
  end
  if not PresetsStorage.enabled then
    return {}
  end
  local labels = {}
  for i = 1, 6 do
    local idx = i
    labels[#labels + 1] = {
      type = lvgl.LABEL,
      font = font or SMLSIZE,
      color = function()
        return (PresetsStorage.latch.lastPos == idx) and COLOR_THEME_PRIMARY1 or COLOR_THEME_DISABLED
      end,
      text = function()
        local p = PresetsStorage.items[idx]
        if p.band == 0 then
          return table.concat({ idx, ":--" })
        end
        return table.concat({ idx, ":", VTXAdmin.BAND_LETTERS[p.band] or "?", p.channel })
      end,
    }
  end
  return labels
end

--- Wrap 6POS labels in a row box. Shared by the one-row and two-row cheatsheets.
local function cheatsheetRow(labels)
  return {
    type = lvgl.BOX,
    flexFlow = lvgl.FLOW_ROW,
    borderPad = 0,
    flexPad = lvgl.PAD_TINY,
    align = LEFT,
    visible = VTXAdmin.hasModule,
    children = labels,
  }
end

--- Single row of all six presets, for tiers with only one line to spare.
function VTXDisplay.buildCheatsheet(font)
  local labels = VTXDisplay.build6posLabels(font)
  if #labels == 0 then
    return nil
  end
  return cheatsheetRow(labels)
end

--- The headline row: the widget's name, then the band and channel, on one line at
--- one size. For the tiers with no row to spare for a title of its own.
--- Both at one size on purpose. The name is a caption in the muted theme colour
--- and the reading is the primary, which is what lets them share a line without
--- competing -- where two type sizes in one breath read as two importances, and
--- a name shrunk beside its own value reads as an afterthought.
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
      color = VTXDisplay.mainColor,
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

--- The power and pit-mode labels that ride a headline row, in the form the width
--- affords: pit mode said in full where there is room for it, and terse -- "Pit"
--- rather than "Pit Mode Off" -- where the name and the reading come first and
--- the row cannot hold all three whole.
--- Two labels either way, because pit mode carries its own colour: a confirmed
--- pit mode is the one thing on this row worth going red, and a single label
--- holding both readings could only be one colour.
--- A caller with no spare row for the status appends its own status label after
--- these.
function VTXDisplay.buildDetailExtras(wide)
  return {
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
      text = wide and VTXDisplay.pitText or VTXDisplay.pitShort,
      visible = VTXDisplay.showChannel,
    },
  }
end

--- The rows 1/2 and 1/1 share: the name, the band and channel as a hero on its
--- own line, and the detail line. The caller appends its cheatsheet rows.
--- detailText overrides the detail formatter, for a screen too narrow for the
--- full one. Its emptiness follows hasDetail either way, since every form of the
--- line falls silent on the same two conditions.
function VTXDisplay.buildHeroRows(fonts, detailText)
  return {
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
      type = lvgl.LABEL,
      align = LEFT,
      font = fonts.hero,
      color = VTXDisplay.mainColor,
      text = VTXDisplay.bandChannel,
      visible = VTXDisplay.showChannel,
    },
    {
      type = lvgl.LABEL,
      align = LEFT,
      font = fonts.detail,
      color = COLOR_THEME_SECONDARY1,
      text = detailText or VTXDisplay.detailLong,
      visible = VTXDisplay.hasDetail,
    },
  }
end

--- Two rows, 1-3 over 4-6. Fits narrow zones and reads larger where height allows.
function VTXDisplay.buildCheatsheetRows(font)
  local labels = VTXDisplay.build6posLabels(font)
  if #labels == 0 then
    return nil, nil
  end
  local row1, row2 = {}, {}
  for i = 1, 3 do
    row1[#row1 + 1] = labels[i]
  end
  for i = 4, 6 do
    row2[#row2 + 1] = labels[i]
  end
  return cheatsheetRow(row1), cheatsheetRow(row2)
end

return VTXDisplay, WidgetLayout
