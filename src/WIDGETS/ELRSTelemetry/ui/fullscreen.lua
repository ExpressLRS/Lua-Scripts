---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Full-Screen Page                              --
-- Loaded via loadScript() from ELRSTelemetry/loadable.lua with          --
-- (Telemetry, Display); returns the FullScreenUI table.                 --
--                                                                       --
-- One layout for every screen size, because lvgl.page() handles the     --
-- responsive part: the link, power, flight controller and GPS rows, and --
-- the no-module checklist in place of all of them.                      --
--                                                                       --
-- Loaded lazily, on the first full-screen entry. Only one widget can be --
-- full screen at a time, so eager loading would leave this resident in  --
-- every other instance for nothing.                                     --
--                                                                       --
-- build() runs on entry, not per frame: EdgeTX calls a widget's         --
-- update() when it is constructed, when it enters or leaves full        --
-- screen, and when its options are edited. Every value here is a        --
-- per-frame text or color callback, so nothing on the page needs a      --
-- rebuild to stay current.                                              --
---------------------------------------------------------------------------

local Telemetry, Display = ...

local FullScreenUI = {}

-- ============================================================================
-- Row helpers
-- ============================================================================

-- Portrait screens get a narrower label column to leave more room for values.
local LABEL_PCT = (LCD_W < LCD_H) and 42 or 50

--- Wrap a value formatter so a row reads "--" while the link is down.
--- Only the link and power rows take this. The flight controller and GPS rows
--- have their own fallbacks, and latitude/longitude deliberately keep showing
--- the last known position after the link drops -- that is what you read when
--- you are looking for a model that stopped answering.
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
-- The page
-- ============================================================================

function FullScreenUI.build()
  lvgl.clear()

  local pg = lvgl.page({
    title = "ExpressLRS",
    subtitle = Display.pageSubtitle,
    back = function()
      lvgl.exitFullScreen()
    end,
  })

  -- No module — show checklist instead of telemetry. Decided at build time on
  -- purpose: module presence is a Model Setup fact, and changing it means
  -- leaving this page, which rebuilds it on the way back in.
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

return FullScreenUI
