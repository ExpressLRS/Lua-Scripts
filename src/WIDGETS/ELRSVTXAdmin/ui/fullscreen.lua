---------------------------------------------------------------------------
-- Full-Screen Editor                                                    --
-- Loaded via loadScript() from ELRSVTXAdmin/loadable.lua with           --
-- (VTXAdmin, PresetsStorage); returns the FullScreenUI table.           --
--                                                                       --
-- One layout for every screen size: VTX Settings editing                --
-- VTXAdmin.desired, the Send VTx button, 6POS Quick Change and preset   --
-- slot rows saving through PresetsStorage, and the no-module checklist. --
---------------------------------------------------------------------------

local VTXAdmin, PresetsStorage = ...

local FullScreenUI = {}

-- ============================================================================
-- Row helpers (shared across all screen sizes)
-- ============================================================================

-- Portrait screens get a narrower label column to leave more room for controls.
local LABEL_PCT = (LCD_W < LCD_H) and 42 or 50

local function createRow(container, label, hint, visibleFn)
  local row = container:rectangle({
    w = lvgl.PERCENT_SIZE + 100,
    thickness = 0,
    flexFlow = lvgl.FLOW_ROW,
    flexPad = 0,
    visible = visibleFn,
  })

  local labelChildren = {
    { type = lvgl.LABEL, y = lvgl.PAD_SMALL, text = label, color = COLOR_THEME_PRIMARY1 },
  }
  if hint then
    labelChildren[#labelChildren + 1] = {
      type = lvgl.LABEL,
      text = hint,
      color = COLOR_THEME_DISABLED,
      font = SMLSIZE,
      w = lvgl.PERCENT_SIZE + 100,
    }
  end

  row:rectangle({
    w = lvgl.PERCENT_SIZE + LABEL_PCT,
    thickness = 0,
    flexFlow = hint and lvgl.FLOW_COLUMN or nil,
    h = not hint and lvgl.UI_ELEMENT_HEIGHT or nil,
    children = labelChildren,
  })

  local ctrl = row:rectangle({
    w = lvgl.PERCENT_SIZE + (100 - LABEL_PCT),
    thickness = 0,
    flexFlow = lvgl.FLOW_ROW,
    align = LEFT + VCENTER,
  })

  return ctrl
end

local function createChoiceRow(container, label, values, getFn, setFn)
  local ctrl = createRow(container, label)
  ctrl:choice({
    title = label,
    values = values,
    get = getFn,
    set = setFn,
  })
end

local function createNumberRow(container, label, min, max, getFn, setFn, editedFn, displayFn)
  local ctrl = createRow(container, label)
  ctrl:numberEdit({
    min = min,
    max = max,
    get = getFn,
    set = setFn,
    edited = editedFn,
    display = displayFn,
  })
end

local function createToggleRow(container, label, getFn, setFn, visibleFn, hint)
  local ctrl = createRow(container, label, hint, visibleFn)
  ctrl:toggle({
    get = getFn,
    set = setFn,
  })
end

local function createSourceRow(container, label, getFn, setFn, filter, hint)
  local ctrl = createRow(container, label, hint)
  ctrl:source({
    get = getFn,
    set = setFn,
    filter = filter,
  })
end

local function createHintRow(container, text)
  container:rectangle({
    w = lvgl.PERCENT_SIZE + 100,
    thickness = 0,
    children = {
      {
        type = lvgl.LABEL,
        text = text,
        color = COLOR_THEME_DISABLED,
        font = SMLSIZE,
        w = lvgl.PERCENT_SIZE + 100,
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

function FullScreenUI.build()
  lvgl.clear()

  local d = VTXAdmin.desired

  local pg = lvgl.page({
    title = "ExpressLRS",
    subtitle = function()
      if VTXAdmin.isActive() then
        return "VTX Administrator"
      end
      return VTXAdmin.statusText
    end,
    back = function()
      lvgl.exitFullScreen()
    end,
  })

  -- No module — show checklist instead of controls (matches expresslrs.lua NoModuleDialog)
  if not VTXAdmin.hasModule() then
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

  -- VTX Settings section
  createSectionHeader(fields, "VTX Settings")

  createChoiceRow(fields, "Band", { "Off", "A", "B", "E", "F", "R", "L" }, function()
    return d.band + 1
  end, function(idx)
    d.band = idx - 1
    VTXAdmin.writeConfig()
  end)

  createNumberRow(fields, "Channel", 1, 8, function()
    return d.channel
  end, function(v)
    d.channel = v
  end, function(v)
    d.channel = v
    VTXAdmin.writeConfig()
  end)

  createNumberRow(fields, "Power Level", 0, 8, function()
    return d.power
  end, function(v)
    d.power = v
  end, function(v)
    d.power = v
    VTXAdmin.writeConfig()
  end, function(v)
    return v == 0 and "-" or tostring(v)
  end)

  -- Pit mode rides on the power byte, so ExpressLRS hides it while power is "-".
  createToggleRow(fields, "Pit Mode", function()
    return d.pitmode
  end, function(v)
    d.pitmode = v
    VTXAdmin.writeConfig()
  end, function()
    return d.power > 0
  end)

  local sendWrapper = fields:box({
    w = lvgl.PERCENT_SIZE + 100,
    flexFlow = lvgl.FLOW_COLUMN,
    align = CENTER,
    borderPad = { top = lvgl.PAD_SMALL, bottom = lvgl.PAD_SMALL },
  })
  sendWrapper:button({
    text = function()
      if VTXAdmin.isSending() then
        return "Sending..."
      end
      return "Send VTx"
    end,
    w = lvgl.PERCENT_SIZE + 99,
    press = function()
      VTXAdmin.writeConfig()
      VTXAdmin.pushToVtx()
    end,
    active = function()
      return VTXAdmin.isReady()
    end,
  })

  -- 6POS Quick Change section
  createSectionHeader(fields, "6POS Quick Change")

  createToggleRow(fields, "Enabled", function()
    return PresetsStorage.enabled and 1 or 0
  end, function(v)
    PresetsStorage.enabled = (v == 1)
    PresetsStorage.save()
  end)

  createSourceRow(fields, "Source", function()
    return PresetsStorage.source
  end, function(v)
    PresetsStorage.source = v or 0
    PresetsStorage.save()
  end, lvgl.SRC_STICK + lvgl.SRC_POT + lvgl.SRC_SWITCH)

  createToggleRow(fields, "Auto Push to VTX", function()
    return PresetsStorage.autoPushVtx and 1 or 0
  end, function(v)
    PresetsStorage.autoPushVtx = (v == 1)
    PresetsStorage.save()
  end, nil, "Send to the VTX as soon as the 6POS position changes. When off, use the trigger below.")

  createSourceRow(
    fields,
    "Send VTx Trigger",
    function()
      return PresetsStorage.pushSource
    end,
    function(v)
      PresetsStorage.pushSource = v or 0
      VTXAdmin.pushLastHigh = nil
      PresetsStorage.save()
    end,
    lvgl.SRC_STICK + lvgl.SRC_POT + lvgl.SRC_SWITCH,
    "Assign a switch or button to manually push the current VTX config to the receiver."
  )

  -- Presets section
  createSectionHeader(fields, "Presets")

  createHintRow(fields, "Assign a Band and Channel to each 6POS switch position.")

  local bandValues = { "--", "A", "B", "E", "F", "R", "L" }
  for i = 1, 6 do
    local idx = i
    local ctrl = createRow(fields, table.concat({ "Preset ", idx }))

    ctrl:choice({
      values = bandValues,
      get = function()
        return PresetsStorage.items[idx].band + 1
      end,
      set = function(v)
        PresetsStorage.items[idx].band = v - 1
        PresetsStorage.save()
      end,
    })

    ctrl:numberEdit({
      min = 1,
      max = 8,
      get = function()
        return PresetsStorage.items[idx].channel
      end,
      set = function(v)
        PresetsStorage.items[idx].channel = v
        PresetsStorage.save()
      end,
      visible = function()
        return PresetsStorage.items[idx].band > 0
      end,
    })
  end
end

return FullScreenUI
