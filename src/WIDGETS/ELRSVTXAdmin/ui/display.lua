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

function WidgetLayout.column(w, h, opa, children)
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
      borderPad = lvgl.PAD_SMALL,
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
