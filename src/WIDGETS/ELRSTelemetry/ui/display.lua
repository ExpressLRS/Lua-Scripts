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

-- One word per rung of Telemetry.STATUS. Title case throughout, because
-- pageSubtitle() puts these under the full-screen page's own title, where
-- shouting would read wrong. The tiers that want a caps banner spell it out
-- themselves as a fixed label.
local STATUS_TEXT = {
  [Telemetry.STATUS.NO_MODULE] = "No CRSF module",
  [Telemetry.STATUS.NO_TELEMETRY] = "No telemetry",
  [Telemetry.STATUS.MISMATCH] = "Model Mismatch",
}

--- Short status text when not operational or a warning is active.
--- Returns nil when connected with no warnings, which is the OK rung having
--- no entry above rather than a case handled here.
function Display.statusText()
  return STATUS_TEXT[Telemetry.statusLevel()]
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

--- Active RSSI against the rate's rated floor, e.g. "-90 / -112 dBm".
--- The pair is the point: RSSI alone says nothing until you know what the
--- receiver can still hear at, and that figure moves with the packet rate.
--- Drops to the reading alone when the rate is unrated.
function Display.signalText()
  if not Telemetry.isConnected() then
    return ""
  end
  local rssi = Telemetry.activeRssi()
  if rssi == nil then
    return ""
  end
  local sens = Telemetry.link.sens
  if sens == nil then
    return table.concat({ tostring(rssi), " dBm" })
  end
  return table.concat({ tostring(rssi), " / ", tostring(sens), " dBm" })
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

-- Link margin in dB above the rated floor. At or below MARGIN_CRIT the
-- receiver is at the edge of what it can hear; above MARGIN_WARN there is
-- room left to fly into. Same thresholds the range percentage used, the right
-- way up and in the unit the number is actually measured in.
local MARGIN_CRIT = 10
local MARGIN_WARN = 30

--- Map link margin to a warning colour.
local function marginColor(db)
  if db <= MARGIN_CRIT then
    return RED
  end
  if db <= MARGIN_WARN then
    return ORANGE
  end
  return COLOR_THEME_SECONDARY1
end

--- Detail line colour: warns as the link margin shrinks, neutral while there
--- is no margin to judge -- no link, or a rate with no published floor.
function Display.detailColor()
  local db = Telemetry.marginDb()
  if db == nil then
    return COLOR_THEME_SECONDARY1
  end
  return marginColor(db)
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
