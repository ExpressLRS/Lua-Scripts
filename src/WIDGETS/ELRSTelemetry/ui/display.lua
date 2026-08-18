---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Display Components                            --
-- Loaded via loadScript() from ELRSTelemetry/loadable.lua with          --
-- (Telemetry); returns the Display table.                               --
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

--- Downlink RSSI, e.g. "-95 dBm". Captioned TRSS by its callers.
--- The unit is not optional: TQly sits beside this on the same row in
--- percent, and a bare -95 next to a percentage invites reading it as one.
function Display.trssText()
  local trss = Telemetry.link.trss
  if not Telemetry.isConnected() or trss == nil then
    return "--"
  end
  return table.concat({ tostring(trss), " dBm" })
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

--- The bare LQ number for the hero figure, e.g. "99", or "--" while
--- disconnected. No caption and no unit: the tier draws those as its own
--- fixed label, so the number can take a display font without dragging a
--- "%" the same size along.
function Display.lqHeroText()
  if not Telemetry.isConnected() then
    return "--"
  end
  return tostring(Telemetry.link.rqly or 0)
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

--- Whether a status is standing, for the labels that swap places with the
--- readings: the status label takes hasStatus, the reading it displaces takes
--- noStatus, and the pair occupy the same rect so nothing reflows.
function Display.hasStatus()
  return Display.statusText() ~= nil
end

function Display.noStatus()
  return Display.statusText() == nil
end

--- RSSI against the rate's rated floor, e.g. "-90 / -112 dBm".
--- The pair is the point: RSSI alone says nothing until you know what the
--- receiver can still hear at, and that figure moves with the packet rate.
--- On diversity hardware both antennas appear ("-85 -92 / -112 dBm") in
--- fixed 1-2 order, so neither number jumps position when the RX switches
--- paths. Drops the floor when the rate is unrated.
function Display.signalText()
  if not Telemetry.isConnected() then
    return ""
  end
  local rssi = Telemetry.activeRssi()
  if rssi == nil then
    return ""
  end
  local parts
  if Telemetry.hasDiversity() then
    parts = { tostring(Telemetry.link.rssi1 or "--"), " ", tostring(Telemetry.link.rssi2) }
  else
    parts = { tostring(rssi) }
  end
  local sens = Telemetry.link.sens
  if sens ~= nil then
    parts[#parts + 1] = " / "
    parts[#parts + 1] = tostring(sens)
  end
  parts[#parts + 1] = " dBm"
  return table.concat(parts)
end

--- The signal pair in its narrowest form: the active antenna alone against
--- the floor. The compact tier reserves a fixed box for this reading, and the
--- diversity pair is wider than the box can be without pushing the hero into
--- wrapping -- so the tightest tier shows the path the link is on, the same
--- trade its width ladder already makes with the antenna cells.
function Display.signalShortText()
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
    return COLOR_THEME_WARNING
  end
  return COLOR_THEME_PRIMARY1
end

-- One health ramp, shared by the bars and the status LED, so a green bar and
-- an amber dot can never describe the same link.
--
-- Theme colours rather than the GREEN/ORANGE/RED literals. Those are raw
-- primaries -- GREEN is RGB(0,255,0) and RED is RGB(255,0,0)
-- (colors.cpp:51-54) -- which is why a full-width LQ bar in GREEN was the
-- loudest thing on the screen, and they stay that way whatever theme the
-- pilot picked. The theme's own EDIT/ACTIVE/WARNING are the same three
-- meanings in colours chosen to sit together, and they repaint with the theme.
local HEALTH = { COLOR_THEME_EDIT, COLOR_THEME_ACTIVE, COLOR_THEME_WARNING }

-- The same ramp for text. COLOR_THEME_ACTIVE is a bright yellow: fine as a
-- bar fill, illegible as a word on the light themes' near-white panel, so
-- warnings in text keep ORANGE.
local HEALTH_TEXT = { COLOR_THEME_EDIT, ORANGE, COLOR_THEME_WARNING }

-- Link margin in dB above the rated floor. At or below MARGIN_CRIT the
-- receiver is at the edge of what it can hear; above MARGIN_WARN there is
-- room left to fly into. Same thresholds the range percentage used, the right
-- way up and in the unit the number is actually measured in.
local MARGIN_CRIT = 10
local MARGIN_WARN = 30

--- Fill colour for a health level: 1 good, 2 warn, 3 critical.
function Display.healthColor(level)
  return HEALTH[level] or COLOR_THEME_DISABLED
end

--- The same, for text that has to stay readable on the panel.
function Display.healthTextColor(level)
  return HEALTH_TEXT[level] or COLOR_THEME_DISABLED
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

--- Colour for the LQ headline, which is a word and not a fill.
function Display.lqTextColor()
  return Display.healthTextColor(Display.lqLevel())
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
    return lit(BLINK_SLOW) and COLOR_THEME_WARNING or COLOR_THEME_DISABLED
  end
  if level == STATUS.MISMATCH then
    return lit(BLINK_FAST) and COLOR_THEME_WARNING or COLOR_THEME_DISABLED
  end
  return Display.lqBarColor()
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
      -- The theme's accent, not COLOR_THEME_PRIMARY1: that is the text colour,
      -- RGB(0,0,0) on the light themes, and a filled black block is not text.
      -- This cell means "the link is on this path", which is what the accent
      -- says everywhere else in EdgeTX.
      return COLOR_THEME_FOCUS
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
  return Display.healthTextColor(level)
end

-- ============================================================================
-- Return components
-- ============================================================================

return Display
