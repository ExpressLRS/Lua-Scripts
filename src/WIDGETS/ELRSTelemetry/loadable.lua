---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Core Logic                                   --
-- Loaded via loadScript() from ELRSTelemetry/main.lua                  --
--                                                                      --
-- Displays ELRS link telemetry using LVGL. Uses the shared CRSF        --
-- singleton passed from main.lua for device info discovery.             --
--                                                                      --
-- UI is loaded from a screen-specific file in ui/ based on LCD_W/LCD_H.--
---------------------------------------------------------------------------

local zone, options, crsf = ...

-- Forward declarations for modules
local Telemetry

-- ============================================================================
-- Telemetry Module: cell counting, state, power mapping
-- ============================================================================

Telemetry = {
  -- Smoothed range percentage
  smoothRng = nil,

  -- Range percentage, recomputed once per tick by Telemetry.update()
  rangePct = 0,

  -- Cell count detection state
  cellCnt = nil,
  ---@type number|nil
  cellCntCnt = nil,
  cellLastV = nil,

  -- Connection state, used to detect the falling edge on disconnect
  wasConnected = false,

  -- Cached GPS position (persists across disconnects)
  ---@type {lat: number, lon: number}|nil
  gps = nil,

  -- Shared link snapshot, refilled once per tick by Telemetry.update().
  -- The table identity never changes, so consumers may cache a reference.
  link = {},

  -- Power level mapping table
  POWERS = { 10, 25, 50, 100, 250, 500, 1000, 2000 },
}

--- Map a power value in mW to a 0-based index.
function Telemetry.pwrToIdx(powval)
  for k, v in ipairs(Telemetry.POWERS) do
    if powval == v then
      return k - 1
    end
  end
  return 7
end

--- Cell count detection heuristic (same logic as original).
function Telemetry.checkCellCount(v)
  -- once the cellCnt is the same X times in a row, stop updating
  if (Telemetry.cellCntCnt or 0) > 5 then
    return
  end

  -- try to lock on to the cell count, so as the voltage sags we don't change S
  local cellCnt = math.floor(v / 4.35) + 1
  -- Prevent lock on when no voltage is present
  if (v / cellCnt) < 3.0 then
    return
  end

  if Telemetry.cellCnt ~= cellCnt then
    Telemetry.cellCnt = cellCnt
    Telemetry.cellCntCnt = 0
  else
    -- The value has to change to count as an update
    if Telemetry.cellLastV == v then
      return
    end
    Telemetry.cellLastV = v
    Telemetry.cellCntCnt = Telemetry.cellCntCnt + 1
  end
end

--- Check if a CRSF/ELRS module is available.
function Telemetry.hasModule()
  return crsf.hasCrsfModule()
end

--- True when a connected link is reporting a model mismatch.
--- modelMismatch arrives in the same ELRS_STATUS frame as hasTelemetry, so it only means
--- anything while connected: ungated, a stale flag paints a label RED under text reading "--".
function Telemetry.isMismatch()
  return crsf.hasTelemetry and crsf.modelMismatch
end

--- Short status text when not operational or warning active.
--- Returns nil when connected with no warnings.
--- Used by both full-screen and minimized UIs.
function Telemetry.statusText()
  if not crsf.hasCrsfModule() then
    return "No CRSF module"
  end
  if not crsf.hasTelemetry then
    return "No telemetry"
  end
  if crsf.modelMismatch then
    return "Model Mismatch"
  end
  return nil
end

--- Compute smoothed range percentage from RSSI.
function Telemetry.getRangePct(tlm)
  local mod = crsf.deviceInfo
  local rssi = (tlm.ant == 1) and tlm.rssi2 or tlm.rssi1
  if rssi == nil then
    return 0
  end
  local minrssi = (mod.RFRSSI and tlm.rfmd and mod.RFRSSI[tlm.rfmd + 1]) or -128
  if rssi > -50 then
    rssi = -50
  end
  local pct = math.floor(100 * (rssi + 50) / (minrssi + 50) + 0.5)
  local smooth = Telemetry.smoothRng or pct
  if pct > smooth then
    pct = smooth + ((pct > smooth + 8) and 4 or 1)
  elseif pct < smooth then
    pct = smooth - ((pct < smooth - 8) and 4 or 1)
  end
  Telemetry.smoothRng = pct
  return pct
end

--- Get RF mode string from device info.
function Telemetry.getRfModeStr(rfmd)
  if not crsf.hasTelemetry or rfmd == nil then
    return ""
  end
  local mod = crsf.deviceInfo
  return (mod.RFMOD and mod.RFMOD[rfmd + 1]) or table.concat({ "RFMD", tostring(rfmd) })
end

--- Update GPS cache from telemetry.
function Telemetry.updateGps()
  local gps = crsf.getSensorValue("GPS")
  if gps and gps ~= 0 then
    Telemetry.gps = gps
  end
end

--- Whether the RX reports a second antenna.
--- An RX only writes uplink_RSSI_2 when it has two RF paths — a dual-radio RX
--- fills it every packet, a switched-antenna RX once it first selects antenna 2.
--- A single-antenna RX never touches it, so it arrives as 0 dBm, impossible for
--- a real signal. Same test ExpressLRS uses on the TX module's own screens.
function Telemetry.hasDiversity()
  local rssi2 = Telemetry.link.rssi2
  return rssi2 ~= nil and rssi2 ~= 0
end

--- Pick the active antenna's RSSI value from a link snapshot.
function Telemetry.getRssi(tlm)
  if not tlm then
    return nil
  end
  return (tlm.ant == 1) and tlm.rssi2 or tlm.rssi1
end

--- Clear per-connection state.
--- The original discarded its whole ctx table on RX disconnect, so cell count and
--- range smoothing re-detect on the next battery instead of latching forever.
--- gps is deliberately kept — the port caches last-known position across dropouts.
function Telemetry.resetConnection()
  Telemetry.smoothRng = nil
  Telemetry.rangePct = 0
  Telemetry.cellCnt = nil
  Telemetry.cellCntCnt = nil
  Telemetry.cellLastV = nil
end

--- Refill the shared link snapshot and recompute all derived state.
--- Called once per tick from wgt.background(). EdgeTX runs wgt.refresh() immediately
--- before it evaluates every LVGL text/color callback, so labels always read values
--- sampled in their own frame and every field sees the same snapshot.
function Telemetry.update()
  local link = Telemetry.link
  link.tpwr = crsf.getSensorValue("TPWR")
  link.rfmd = crsf.getSensorValue("RFMD")
  link.rssi1 = crsf.getSensorValue("1RSS")
  link.rssi2 = crsf.getSensorValue("2RSS")
  link.rqly = crsf.getSensorValue("RQly")
  link.ant = crsf.getSensorValue("ANT")
  link.vbat = crsf.getSensorValue("RxBt")

  local connected = crsf.hasTelemetry
  if Telemetry.wasConnected and not connected then
    Telemetry.resetConnection()
  end
  Telemetry.wasConnected = connected
  if not connected then
    return
  end

  Telemetry.updateGps()
  Telemetry.rangePct = Telemetry.getRangePct(link)
  if link.vbat then
    Telemetry.checkCellCount(link.vbat)
  end
end

--- Hero label colour: red only while a connected link reports a model mismatch.
function Telemetry.heroColor()
  if Telemetry.isMismatch() then
    return RED
  end
  return COLOR_THEME_PRIMARY1
end

--- Hero label font for one tier of a screen's WidgetUI.fonts table.
--- Status text ("No CRSF module") is far longer than "LQ 100%", so tiers that would
--- overflow declare a smaller heroStatus and drop to it while a status shows.
--- Tiers without one get the constant back, so no callback runs per frame.
function Telemetry.heroFont(tier)
  if not tier.heroStatus then
    return tier.hero
  end
  return function()
    if Telemetry.statusText() then
      return tier.heroStatus
    end
    return tier.hero
  end
end

--- Map range percentage to a warning color.
function Telemetry.rangeColor(pct)
  if pct > 90 then
    return RED
  end
  if pct > 70 then
    return ORANGE
  end
  return COLOR_THEME_SECONDARY1
end

--- Range percentage + RSSI text (e.g. "Range 69% -90dBm").
function Telemetry.signalText()
  if not crsf.hasTelemetry then
    return ""
  end
  local parts = { table.concat({ "Range ", tostring(Telemetry.rangePct), "%" }) }
  local rssi = Telemetry.getRssi(Telemetry.link)
  if rssi then
    parts[#parts + 1] = table.concat({ tostring(rssi), "dBm" })
  end
  return table.concat(parts, " ")
end

--- RF mode text (e.g. "250Hz"). Narrow zones use this without the power suffix.
function Telemetry.rfModeText()
  return Telemetry.getRfModeStr(Telemetry.link.rfmd)
end

--- RF mode + TX power text (e.g. "250Hz 50mW").
function Telemetry.rfDetailText()
  local parts = { Telemetry.rfModeText() }
  local tpwr = Telemetry.link.tpwr
  if crsf.hasTelemetry and tpwr then
    parts[#parts + 1] = table.concat({ tostring(tpwr), "mW" })
  end
  return table.concat(parts, " ")
end

--- Battery text for minimized layouts (e.g. "Bat 4S 3.80V").
function Telemetry.batteryText()
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

--- Battery text for the full-screen row (e.g. "4S 3.80V (15.20V)").
function Telemetry.batteryTextVerbose()
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
-- Screen detection and UI loading
-- ============================================================================

--- Detect screen resolution and return an ID for the per-screen UI file.
local function getScreenId()
  local w, h = LCD_W, LCD_H
  if w >= 800 then
    return "hd" -- 800x480
  elseif w < h then
    return "portrait" -- 320x480 (EL18)
  elseif w <= 320 then
    return "small" -- 320x240
  elseif h >= 320 then
    return "sd_tall" -- 480x320 (T15, T15 Pro, TX15, ST16, PL18)
  else
    return "sd" -- 480x272 (TX16S, MAX, Mk II)
  end
end

--- Convert Transparency option (0-5) to LVGL opacity (255-0).
local function bgOpacity(opts)
  local t = (opts and opts.Transparency) or 2
  return math.max(0, 255 - 51 * t)
end

local screenId = getScreenId()
local uiPath = table.concat({ "/WIDGETS/ELRSTelemetry/ui/", screenId, ".lua" })
local WidgetUI = loadScript(uiPath)({
  crsf = crsf,
  Telemetry = Telemetry,
  bgOpacity = bgOpacity,
  WidgetLayout = WidgetLayout,
})

-- ============================================================================
-- Full-screen row helpers (shared across all screen sizes)
-- ============================================================================

-- Portrait screens get a narrower label column to leave more room for values.
local LABEL_PCT = (LCD_W < LCD_H) and 42 or 50

local function createDisplayRow(container, label, valueFn, colorFn)
  container:rectangle({
    w = lvgl.PERCENT_SIZE + 100,
    thickness = 0,
    flexFlow = lvgl.FLOW_ROW,
    flexPad = 0,
    children = {
      {
        type = lvgl.LABEL,
        text = label,
        color = COLOR_THEME_PRIMARY1,
        w = lvgl.PERCENT_SIZE + LABEL_PCT,
        y = lvgl.PAD_SMALL,
      },
      {
        type = lvgl.LABEL,
        text = valueFn,
        color = colorFn or COLOR_THEME_SECONDARY1,
        w = lvgl.PERCENT_SIZE + (100 - LABEL_PCT),
        y = lvgl.PAD_SMALL,
      },
    },
  })
end

local function createSectionHeader(container, title)
  container:build({
    {
      type = lvgl.RECTANGLE,
      w = lvgl.PERCENT_SIZE + 100,
      h = lvgl.PAD_SMALL,
      thickness = 0,
    },
    {
      type = lvgl.LABEL,
      font = BOLD,
      color = COLOR_THEME_PRIMARY1,
      text = title,
    },
  })
end

-- ============================================================================
-- Full-screen LVGL layout (shared across all screen sizes)
-- ============================================================================

local function buildFullScreen()
  lvgl.clear()

  local pg = lvgl.page({
    title = "ExpressLRS",
    subtitle = function()
      if not Telemetry.hasModule() then
        return "No CRSF module"
      end
      if not crsf.hasTelemetry then
        return "No telemetry"
      end
      if crsf.modelMismatch then
        return "Model Mismatch"
      end
      return "Telemetry"
    end,
    back = function()
      lvgl.exitFullScreen()
    end,
  })

  -- No module — show checklist instead of telemetry (matches expresslrs.lua NoModuleDialog)
  if not Telemetry.hasModule() then
    pg:rectangle({
      w = lvgl.PERCENT_SIZE + 100,
      thickness = 0,
      flexFlow = lvgl.FLOW_COLUMN,
      flexPad = lvgl.PAD_MEDIUM,
      children = {
        { type = lvgl.LABEL, text = "No module found. Check Model Setup:", color = COLOR_THEME_PRIMARY1 },
        { type = lvgl.LABEL, text = "- Internal/External module enabled", color = COLOR_THEME_DISABLED },
        { type = lvgl.LABEL, text = "- Protocol set to CRSF", color = COLOR_THEME_DISABLED },
        {
          type = lvgl.LABEL,
          text = "- Baud rate: 400k (250Hz), 921k (500Hz), 1.87M (F1000)",
          color = COLOR_THEME_DISABLED,
        },
      },
    })
    return
  end

  local fields = pg:rectangle({
    w = lvgl.PERCENT_SIZE + 100,
    thickness = 0,
    flexFlow = lvgl.FLOW_COLUMN,
  })

  -- Model mismatch warning banner
  fields:build({
    {
      type = lvgl.LABEL,
      font = BOLD,
      color = RED,
      text = "Model Mismatch — RC commands not sent",
      visible = Telemetry.isMismatch,
    },
  })

  -- Link Status section
  createSectionHeader(fields, "Link Status")

  createDisplayRow(fields, "RF Mode", Telemetry.rfModeText)

  createDisplayRow(fields, "Link Quality", function()
    if not crsf.hasTelemetry then
      return "--"
    end
    return table.concat({ tostring(Telemetry.link.rqly or 0), "%" })
  end)

  createDisplayRow(fields, "RSSI 1", function()
    if not crsf.hasTelemetry then
      return "--"
    end
    local rssi1 = Telemetry.link.rssi1
    if rssi1 == nil then
      return "--"
    end
    return table.concat({ tostring(rssi1), " dBm" })
  end)

  createDisplayRow(fields, "RSSI 2", function()
    if not crsf.hasTelemetry then
      return "--"
    end
    local rssi2 = Telemetry.link.rssi2
    if rssi2 == nil then
      return "--"
    end
    return table.concat({ tostring(rssi2), " dBm" })
  end, function()
    if not Telemetry.hasDiversity() then
      return COLOR_THEME_DISABLED
    end
    return COLOR_THEME_SECONDARY1
  end)

  createDisplayRow(fields, "Active Antenna", function()
    if not crsf.hasTelemetry then
      return "--"
    end
    if not Telemetry.hasDiversity() then
      return "N/A"
    end
    -- EdgeTX's telemetry list prints the raw ANT enum (0/1) and so does the TX
    -- module's own screen. The "Ant " prefix keeps this row from reading as that
    -- same number, and 1/2 matches the RSSI 1 / RSSI 2 rows above.
    if Telemetry.link.ant == 0 then
      return "Ant 1"
    end
    if Telemetry.link.ant == 1 then
      return "Ant 2"
    end
    return "--"
  end)

  createDisplayRow(fields, "Range", function()
    if not crsf.hasTelemetry then
      return "--"
    end
    return table.concat({ tostring(Telemetry.rangePct), "%" })
  end)

  -- Power section
  createSectionHeader(fields, "Power")

  createDisplayRow(fields, "TX Power", function()
    if not crsf.hasTelemetry then
      return "--"
    end
    local tpwr = Telemetry.link.tpwr
    if tpwr == nil then
      return "--"
    end
    return table.concat({ tostring(tpwr), " mW" })
  end)

  createDisplayRow(fields, "Power Index", function()
    if not crsf.hasTelemetry then
      return "--"
    end
    local tpwr = Telemetry.link.tpwr
    if tpwr == nil then
      return "--"
    end
    return tostring(Telemetry.pwrToIdx(tpwr))
  end)

  -- Flight Controller section
  createSectionHeader(fields, "Flight Controller")

  createDisplayRow(fields, "Battery", Telemetry.batteryTextVerbose)

  createDisplayRow(fields, "Current", function()
    local curr = crsf.getSensorValue("Curr")
    if curr == nil or curr <= 0 then
      return "--"
    end
    return string.format("%.2f A", curr)
  end)

  createDisplayRow(fields, "Flight Mode", function()
    local fm = crsf.getSensorValue("FM")
    if fm == nil or fm == 0 then
      return "--"
    end
    return tostring(fm)
  end)

  -- GPS section
  createSectionHeader(fields, "GPS")

  createDisplayRow(fields, "Satellites", function()
    local sats = crsf.getSensorValue("Sats")
    if sats == nil then
      return "--"
    end
    return tostring(sats)
  end)

  createDisplayRow(fields, "Speed", function()
    local gspd = crsf.getSensorValue("GSpd")
    if gspd == nil then
      return "--"
    end
    return string.format("%.1f", gspd)
  end)

  createDisplayRow(fields, "Altitude", function()
    local alt = crsf.getSensorValue("Alt")
    if alt == nil then
      return "--"
    end
    return tostring(alt)
  end)

  createDisplayRow(fields, "Latitude", function()
    if Telemetry.gps == nil then
      return "--"
    end
    return tostring(Telemetry.gps.lat)
  end)

  createDisplayRow(fields, "Longitude", function()
    if Telemetry.gps == nil then
      return "--"
    end
    return tostring(Telemetry.gps.lon)
  end)
end

-- ============================================================================
-- Widget lifecycle
-- ============================================================================

local wgt = {
  zone = zone,
  options = options,
}

function wgt.background()
  crsf:poll()
  crsf:requestDeviceInfo()
  crsf:requestElrsStatus()
  Telemetry.update()
end

function wgt.refresh(_event, _touchState)
  wgt.background()
end

function wgt.update(newOptions)
  wgt.options = newOptions
  if lvgl.isFullScreen() then
    buildFullScreen()
  else
    WidgetUI.build(wgt.zone, wgt.options)
  end
end

-- Populate the snapshot before the first paint: update() runs callRefs without a
-- preceding refresh(), so label callbacks can fire before the first background tick.
Telemetry.update()

-- Initial build
WidgetUI.build(wgt.zone, wgt.options)

return wgt
