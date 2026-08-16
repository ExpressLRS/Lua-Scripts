---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Display Components                            --
-- Loaded via loadScript() from ELRSTelemetry/loadable.lua with          --
-- (Telemetry); returns (Display, WidgetLayout).                         --
--                                                                       --
-- Display is the read model the ui/ files consume: zero-argument        --
-- formatters passed by reference as LVGL text/color callbacks, so they  --
-- are re-evaluated every frame without a rebuild. Every entry is a dot  --
-- function for that reason -- a colon method handed to LVGL would be    --
-- called with no receiver and fail at paint time.                       --
--                                                                       --
-- This is the whole vocabulary the view has. No ui/ file reaches past   --
-- it to the CRSF transport, and none of them formats a value itself.    --
---------------------------------------------------------------------------

local Telemetry = ...

local Display = {}

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
-- Link state, as the view asks about it
-- ============================================================================

--- Whether the link is up. The view never reads the transport itself.
function Display.isConnected()
  return Telemetry.isConnected()
end

--- Whether to paint a mismatch warning.
function Display.isMismatch()
  return Telemetry.isMismatch()
end

--- Short status text when not operational or a warning is active.
--- Returns nil when connected with no warnings.
function Display.statusText()
  if not Telemetry.hasModule() then
    return "No CRSF module"
  end
  if not Telemetry.isConnected() then
    return "No telemetry"
  end
  if Telemetry.modelMismatch then
    return "Model Mismatch"
  end
  return nil
end

--- Full-screen page subtitle: the same ladder, with a resting state.
function Display.pageSubtitle()
  return Display.statusText() or "Telemetry"
end

-- ============================================================================
-- Values
-- ============================================================================

--- Link quality on its own, e.g. "100%", or "--" while disconnected.
function Display.lqValueText()
  if not Telemetry.isConnected() then
    return "--"
  end
  return table.concat({ tostring(Telemetry.link.rqly or 0), "%" })
end

--- Link quality as the hero label spells it, e.g. "LQ 100%".
function Display.lqText()
  return table.concat({ "LQ ", tostring(Telemetry.link.rqly or 0), "%" })
end

--- Active antenna RSSI, e.g. "-87dBm", or "" while unknown.
--- sep is the gap between the number and the unit: "" in tight minimized
--- layouts, " " where the full-screen rows have room for it.
function Display.rssiText(sep)
  local rssi = Telemetry.activeRssi()
  if rssi == nil then
    return ""
  end
  return table.concat({ tostring(rssi), sep or "", "dBm" })
end

--- The hero label: a status when there is one, otherwise link quality.
function Display.heroText()
  return Display.statusText() or Display.lqText()
end

--- Range percentage + RSSI text, e.g. "Range 69% -90dBm".
function Display.signalText()
  if not Telemetry.isConnected() then
    return ""
  end
  local parts = { table.concat({ "Range ", tostring(Telemetry.rangePct), "%" }) }
  local rssi = Display.rssiText()
  if rssi ~= "" then
    parts[#parts + 1] = rssi
  end
  return table.concat(parts, " ")
end

--- RF mode text, e.g. "250Hz". Narrow zones use this without the power suffix.
function Display.rfModeText()
  if not Telemetry.isConnected() then
    return ""
  end
  return Telemetry.rfModeName() or ""
end

--- RF mode + TX power text, e.g. "250Hz 50mW".
function Display.rfDetailText()
  local parts = { Display.rfModeText() }
  local tpwr = Telemetry.link.tpwr
  if Telemetry.isConnected() and tpwr then
    parts[#parts + 1] = table.concat({ tostring(tpwr), "mW" })
  end
  return table.concat(parts, " ")
end

--- Battery text for minimized layouts, e.g. "Bat 4S 3.80V".
function Display.batteryText()
  local vbat = Telemetry.link.vbat
  if vbat == nil or vbat <= 0 then
    return ""
  end
  local cells = Telemetry.cellCnt
  if cells then
    return string.format("Bat %dS %.2fV", cells, vbat / cells)
  end
  return string.format("Bat %.2fV", vbat)
end

--- Battery text for the full-screen row, e.g. "4S 3.80V (15.20V)".
function Display.batteryTextVerbose()
  local vbat = Telemetry.link.vbat
  if vbat == nil or vbat <= 0 then
    return "--"
  end
  local cells = Telemetry.cellCnt
  if cells then
    return string.format("%dS %.2fV (%.2fV)", cells, vbat / cells, vbat)
  end
  return string.format("%.2fV", vbat)
end

-- ============================================================================
-- Colours and fonts
-- ============================================================================

--- Hero label colour: red only while a connected link reports a mismatch.
function Display.heroColor()
  if Telemetry.isMismatch() then
    return RED
  end
  return COLOR_THEME_PRIMARY1
end

--- Map range percentage to a warning colour.
local function rangeColor(pct)
  if pct > 90 then
    return RED
  end
  if pct > 70 then
    return ORANGE
  end
  return COLOR_THEME_SECONDARY1
end

--- Detail line colour: warns as the range percentage climbs, neutral while
--- there is no link to judge.
function Display.detailColor()
  if not Telemetry.isConnected() then
    return COLOR_THEME_SECONDARY1
  end
  return rangeColor(Telemetry.rangePct)
end

--- Hero label font for one tier of a screen's WidgetUI.fonts table.
--- Status text ("No CRSF module") is far longer than "LQ 100%", so tiers that
--- would overflow declare a smaller heroStatus and drop to it while a status
--- shows. Tiers without one get the constant back, so no callback runs per
--- frame. This is a factory, not a callback: call it when building.
function Display.heroFont(tier)
  if not tier.heroStatus then
    return tier.hero
  end
  return function()
    if Display.statusText() then
      return tier.heroStatus
    end
    return tier.hero
  end
end

-- ============================================================================
-- Return components
-- ============================================================================

return Display, WidgetLayout
