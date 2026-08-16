---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Wiring                                       --
-- Loaded via loadScript() from ELRSTelemetry/main.lua with             --
-- (zone, options, Telemetry); returns the widget instance table.       --
--                                                                      --
-- One of these exists per placed widget. It owns no state of its own:  --
-- everything it shows lives in the Telemetry singleton, which outlives --
-- it. All this file does is pick the layout for the screen, wire the   --
-- components together, and drive them from the widget callbacks.       --
--                                                                      --
-- The minimized layout is per screen size; the full-screen page is     --
-- shared, because lvgl.page() handles the responsive part itself.      --
---------------------------------------------------------------------------

local zone, options, Telemetry = ...

-- ============================================================================
-- Display components
-- ============================================================================

local Display, WidgetLayout = loadScript("/WIDGETS/ELRSTelemetry/ui/display.lua")(Telemetry)

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
  Display = Display,
  bgOpacity = bgOpacity,
  WidgetLayout = WidgetLayout,
})

-- ============================================================================
-- Full-screen row helpers (shared across all screen sizes)
-- ============================================================================

-- Portrait screens get a narrower label column to leave more room for values.
local LABEL_PCT = (LCD_W < LCD_H) and 42 or 50

--- Wrap a value formatter so a row reads "--" while the link is down.
--- Only the Link Status and Power rows take this: the flight controller and
--- GPS rows have their own fallbacks, and latitude/longitude deliberately keep
--- showing the last known position after the link drops.
local function whenConnected(fn)
  return function()
    if not Telemetry.isConnected() then
      return "--"
    end
    return fn()
  end
end

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
    subtitle = Display.pageSubtitle,
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
      visible = Display.isMismatch,
    },
  })

  -- Link Status section
  createSectionHeader(fields, "Link Status")

  createDisplayRow(fields, "RF Mode", Display.rfModeText)

  createDisplayRow(fields, "Link Quality", Display.lqValueText)

  createDisplayRow(
    fields,
    "RSSI 1",
    whenConnected(function()
      local rssi1 = Telemetry.link.rssi1
      if rssi1 == nil then
        return "--"
      end
      return table.concat({ tostring(rssi1), " dBm" })
    end)
  )

  createDisplayRow(
    fields,
    "RSSI 2",
    whenConnected(function()
      local rssi2 = Telemetry.link.rssi2
      if rssi2 == nil then
        return "--"
      end
      return table.concat({ tostring(rssi2), " dBm" })
    end),
    function()
      if not Telemetry.hasDiversity() then
        return COLOR_THEME_DISABLED
      end
      return COLOR_THEME_SECONDARY1
    end
  )

  createDisplayRow(
    fields,
    "Active Antenna",
    whenConnected(function()
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
  )

  createDisplayRow(
    fields,
    "Range",
    whenConnected(function()
      return table.concat({ tostring(Telemetry.rangePct), "%" })
    end)
  )

  -- Power section
  createSectionHeader(fields, "Power")

  createDisplayRow(
    fields,
    "TX Power",
    whenConnected(function()
      local tpwr = Telemetry.link.tpwr
      if tpwr == nil then
        return "--"
      end
      return table.concat({ tostring(tpwr), " mW" })
    end)
  )

  createDisplayRow(
    fields,
    "Power Index",
    whenConnected(function()
      local tpwr = Telemetry.link.tpwr
      if tpwr == nil then
        return "--"
      end
      return tostring(Telemetry.powerIndex(tpwr))
    end)
  )

  -- Flight Controller section
  createSectionHeader(fields, "Flight Controller")

  createDisplayRow(fields, "Battery", Display.batteryTextVerbose)

  createDisplayRow(fields, "Current", function()
    local curr = Telemetry.link.curr
    if curr == nil or curr <= 0 then
      return "--"
    end
    return string.format("%.2f A", curr)
  end)

  createDisplayRow(fields, "Flight Mode", function()
    local fm = Telemetry.link.fm
    if fm == nil or fm == 0 then
      return "--"
    end
    return tostring(fm)
  end)

  -- GPS section
  createSectionHeader(fields, "GPS")

  createDisplayRow(fields, "Satellites", function()
    local sats = Telemetry.link.sats
    if sats == nil then
      return "--"
    end
    return tostring(sats)
  end)

  createDisplayRow(fields, "Speed", function()
    local gspd = Telemetry.link.gspd
    if gspd == nil then
      return "--"
    end
    return string.format("%.1f", gspd)
  end)

  createDisplayRow(fields, "Altitude", function()
    local alt = Telemetry.link.alt
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

-- drain() is per instance and ungated: this instance owns a pop queue in the
-- firmware that only it can empty. update() is shared and samples at most once
-- per tick, so the instances after the first fall through it.
function wgt.background()
  Telemetry.drain()
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
