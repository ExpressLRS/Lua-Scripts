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

--- The inverse, for the strip elements a mismatch banner displaces. They take
--- this rather than being left out, so the banner and the elements it hides
--- occupy the same rect and nothing reflows.
function Display.isNotMismatch()
  return not Telemetry.isMismatch()
end

--- Whether the RX reports a second antenna, so a layout can hide the cell
--- that would otherwise imply a path this receiver does not have.
function Display.hasDiversity()
  return Telemetry.hasDiversity()
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

--- Uplink LQ as a bar fraction, 0-100.
function Display.lqPct()
  if not Telemetry.isConnected() then
    return 0
  end
  return Telemetry.link.rqly or 0
end

--- Signal headroom as a bar fraction, 0-100. Zero rather than nil so a size
--- closure never has to think about it; the bar hides on hasHeadroom().
function Display.headroomPct()
  return Telemetry.headroomPct or 0
end

--- Whether there is a rated floor to draw a headroom scale against.
function Display.hasHeadroom()
  return Telemetry.headroomPct ~= nil
end

--- Downlink link quality, e.g. "100 %". Captioned TQly by its callers, which
--- is the name EdgeTX puts in the model's telemetry list.
function Display.tqlyText()
  local tqly = Telemetry.link.tqly
  if not Telemetry.isConnected() or tqly == nil then
    return "--"
  end
  return table.concat({ tostring(tqly), " %" })
end

--- Downlink RSSI, e.g. "-95". Captioned TRSS by its callers.
function Display.trssText()
  local trss = Telemetry.link.trss
  if not Telemetry.isConnected() or trss == nil then
    return "--"
  end
  return tostring(trss)
end

--- The same with its unit, for rows wide enough to carry one.
--- A separate zero-argument function rather than a parameter, because these
--- are handed to LVGL by reference and called with no arguments.
function Display.trssTextUnit()
  local trss = Telemetry.link.trss
  if not Telemetry.isConnected() or trss == nil then
    return "--"
  end
  return table.concat({ tostring(trss), " dBm" })
end

--- The rated floor on its own, e.g. "-108", for the headroom bar's left
--- endpoint. Empty when there is no floor, which is also when the bar hides.
function Display.sensText()
  local sens = Telemetry.link.sens
  if sens == nil then
    return ""
  end
  return tostring(sens)
end

--- The headroom bar's right endpoint, the RSSI above which more signal buys
--- nothing. A property of the scale, so it comes from the state, not a literal
--- in a layout file.
function Display.ceilingText()
  return tostring(Telemetry.RSSI_CEILING)
end

--- TX power on its own, e.g. "100 mW", or "--" while unknown.
function Display.powerText()
  local tpwr = Telemetry.link.tpwr
  if tpwr == nil then
    return "--"
  end
  return table.concat({ tostring(tpwr), " mW" })
end

--- Per-cell battery voltage, e.g. "4S 3.75 V", or "--".
--- The pack total is a separate value so a row can carry one or both.
function Display.cellText()
  local vbat = Telemetry.link.vbat
  if vbat == nil or vbat <= 0 then
    return "--"
  end
  local cells = Telemetry.cellCnt
  if cells == nil then
    return "--"
  end
  return string.format("%dS %.2f V", cells, vbat / cells)
end

--- Pack voltage, e.g. "15.20 V", or "--".
function Display.packText()
  local vbat = Telemetry.link.vbat
  if vbat == nil or vbat <= 0 then
    return "--"
  end
  return string.format("%.2f V", vbat)
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

-- One health ramp, shared by the bars and the status LED, so a green bar and
-- an amber dot can never describe the same link.
local HEALTH = { GREEN, ORANGE, RED }

-- Link margin in dB above the rated floor. At or below MARGIN_CRIT the
-- receiver is at the edge of what it can hear; above MARGIN_WARN there is
-- room left to fly into. Same thresholds the range percentage used, the right
-- way up and in the unit the number is actually measured in.
local MARGIN_CRIT = 10
local MARGIN_WARN = 30

--- Colour for a health level: 1 good, 2 warn, 3 critical.
function Display.healthColor(level)
  return HEALTH[level] or COLOR_THEME_DISABLED
end

-- Uplink LQ. Below LQ_CRIT ExpressLRS is dropping enough packets to matter;
-- at or above LQ_GOOD the link is doing what it is supposed to.
local LQ_GOOD = 90
local LQ_CRIT = 50

--- Health level of the uplink LQ.
function Display.lqLevel()
  if not Telemetry.isConnected() then
    return 3
  end
  local lq = Telemetry.link.rqly or 0
  if lq >= LQ_GOOD then
    return 1
  end
  if lq >= LQ_CRIT then
    return 2
  end
  return 3
end

--- Health level of the link margin, worst while there is no margin to judge.
function Display.marginLevel()
  local db = Telemetry.marginDb()
  if db == nil then
    return 3
  end
  if db > MARGIN_WARN then
    return 1
  end
  if db > MARGIN_CRIT then
    return 2
  end
  return 3
end

--- Fill colour for the LQ bar.
function Display.lqBarColor()
  return Display.healthColor(Display.lqLevel())
end

--- Fill colour for the headroom bar.
function Display.headroomBarColor()
  return Display.healthColor(Display.marginLevel())
end

-- Blink periods in getTime() ticks, which run at 10 ms. Halved for the on/off
-- phase, so BLINK_SLOW is 1 Hz and BLINK_FAST is 4 Hz.
local BLINK_SLOW = 50
local BLINK_FAST = 12

--- Whether a blink of the given half-period is in its lit phase.
local function lit(halfPeriod)
  return math.floor(getTime() / halfPeriod) % 2 == 0
end

--- Status LED colour.
--- Red means bad and blinking means the link is broken or bound to the wrong
--- model; solid means the link works and only the numbers are poor. The
--- reference widgets blink to mean "healthy", which teaches the eye to ignore
--- a blinking dot -- the one thing it must not do here.
--- The off phase returns the track colour rather than hiding the dot, so it
--- reads as an LED that is off instead of a hole in the strip, and stays right
--- under a transparent background.
function Display.ledColor()
  local level = Telemetry.statusLevel()
  local STATUS = Telemetry.STATUS
  if level == STATUS.NO_MODULE then
    return COLOR_THEME_DISABLED
  end
  if level == STATUS.NO_TELEMETRY then
    return lit(BLINK_SLOW) and RED or COLOR_THEME_DISABLED
  end
  if level == STATUS.MISMATCH then
    return lit(BLINK_FAST) and RED or COLOR_THEME_DISABLED
  end
  return Display.lqBarColor()
end

-- ExpressLRS power ladder in mW. The meter counts steps on this rather than
-- scaling a percentage, because the steps are what the module actually offers
-- and 100 mW is halfway up the ladder but 5% of the range.
local POWER_STEPS = { 10, 25, 50, 100, 250, 500, 1000, 2000 }

--- How many power steps are lit, 0 to #POWER_STEPS.
function Display.powerSteps()
  local tpwr = Telemetry.link.tpwr
  if tpwr == nil then
    return 0
  end
  local n = 0
  for i = 1, #POWER_STEPS do
    if tpwr >= POWER_STEPS[i] then
      n = i
    end
  end
  return n
end

--- Total cells in the power meter, so a layout can size it without knowing
--- the ladder.
function Display.powerStepCount()
  return #POWER_STEPS
end

--- Colour for antenna cell n (1 or 2): lit when that path is the active one.
--- A factory, not a callback -- call it when building.
function Display.antColor(n)
  return function()
    if not Telemetry.isConnected() then
      return COLOR_THEME_DISABLED
    end
    -- ANT is 0-based and the cells are 1-based, same convention as the
    -- full-screen page's "Ant 1" / "Ant 2" rows.
    if (Telemetry.link.ant or 0) + 1 == n then
      return COLOR_THEME_PRIMARY1
    end
    return COLOR_THEME_DISABLED
  end
end

--- Detail line colour: warns as the link margin shrinks, neutral while there
--- is no margin to judge -- no link, or a rate with no published floor.
--- Deliberately not the health ramp: a line of text that turns green whenever
--- nothing is wrong is noise, while a bar that turns green is the point of
--- drawing it.
function Display.detailColor()
  local db = Telemetry.marginDb()
  if db == nil then
    return COLOR_THEME_SECONDARY1
  end
  local level = Display.marginLevel()
  if level == 1 then
    return COLOR_THEME_SECONDARY1
  end
  return Display.healthColor(level)
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
