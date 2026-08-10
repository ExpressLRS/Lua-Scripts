---------------------------------------------------------------------------
-- VTX Administrator Widget - Core Logic                                 --
-- Loaded via loadScript() from ELRSVTXAdmin/main.lua                    --
--                                                                       --
-- Communicates with the ELRS TX module's VTX Administrator via the      --
-- CRSF config protocol (PARAMETER_READ/WRITE). Field IDs are            --
-- discovered at runtime by name -- never hardcoded.                     --
--                                                                       --
-- UI is loaded from a screen-specific file in ui/ based on LCD_W/LCD_H. --
---------------------------------------------------------------------------

local zone, options, crsf = ...

-- Forward declarations for modules (needed for cross-references)
local VTX
local Protocol
local Presets

-- ============================================================================
-- VTX Module: Band lookups, field IDs, current/desired state, folder parsing
-- ============================================================================

VTX = {
  -- Band lookup tables. BAND_LETTERS is 1-based: band 0 has no letter, and its label
  -- differs by context ("Off" for a disabled VTX, "--" for an unused 6POS preset slot).
  BAND_LETTERS = { "A", "B", "E", "F", "R", "L" },
  BAND_VALUES = { Off = 0, A = 1, B = 2, E = 3, F = 4, R = 5, L = 6 },

  -- Field IDs (discovered at runtime)
  ids = {
    folder = nil,
    band = nil,
    channel = nil,
    power = nil,
    pitmode = nil,
    send = nil,
  },

  -- Current VTX state (parsed from folder name)
  state = {
    band = 0, -- 0=Off, 1=A, 2=B, 3=E, 4=F, 5=R, 6=L
    bandLetter = "?",
    channel = 0,
    power = 0,
    pitmode = false, -- true only when pit mode is confirmed on
    pitmodeAux = nil, -- switch name when pit mode is bound to an aux switch
  },

  -- Desired VTX state (edited by user in full-screen UI)
  desired = {
    band = 5, -- Raceband
    channel = 1,
    power = 0,
    pitmode = 0,
  },
}

--- Parse "VTX Admin (R:4:2:P)" into VTX.state fields.
-- ExpressLRS writes "VTX Admin (BAND:CHANNEL[:POWER[:PITMODE]])": band Off drops the whole
-- suffix, power "-" drops both power and pit mode, pit mode Off drops itself. PITMODE is "P"
-- when set to On, or the aux label ("AUX1\192".."AUX10\193", \192/\193 = up/down arrow) when
-- bound to a switch. The name carries only the binding, never the switch position, so an aux
-- binding sets pitmodeAux and leaves pitmode false.
function VTX.parseFolderName(name)
  local s = VTX.state
  local content = string.match(name, "%((.+)%)")
  if not content then
    s.band = 0
    s.bandLetter = "Off"
    s.channel = 0
    s.power = 0
    s.pitmode = false
    s.pitmodeAux = nil
    return true
  end

  local parts = {}
  for part in string.gmatch(content, "([^:]+)") do
    parts[#parts + 1] = part
  end
  if #parts < 2 then
    return false
  end

  s.bandLetter = parts[1]
  s.band = VTX.BAND_VALUES[parts[1]] or 0
  s.channel = tonumber(parts[2]) or 0
  s.power = tonumber(parts[3]) or 0
  if #parts < 4 then
    s.pitmode = false
    s.pitmodeAux = nil
  elseif parts[4] == "P" then
    s.pitmode = true
    s.pitmodeAux = nil
  else
    s.pitmode = false
    s.pitmodeAux = string.sub(parts[4], 1, -2)
  end
  return true
end

--- True when the VTX is tuned to a band.
function VTX.isTuned()
  return Protocol.isActive() and VTX.state.band > 0
end

--- True when the module is up but the VTX band is set to Off.
function VTX.isDisabled()
  return Protocol.isActive() and VTX.state.band == 0
end

--- True when a power level is set. ExpressLRS omits power and pit mode from the VTX Admin
--- folder name when power is "-", and hides the Pitmode field entirely, so neither value is
--- meaningful until a power level is chosen.
function VTX.hasPower()
  return VTX.isTuned() and VTX.state.power > 0
end

--- Sync desired values with current state (e.g. on discovery or entering full-screen).
function VTX.syncDesiredFromState()
  local s = VTX.state
  local d = VTX.desired
  d.band = s.band
  d.channel = s.channel
  d.power = s.power
  d.pitmode = s.pitmode and 1 or 0
end

-- ============================================================================
-- Protocol Module: CRSF config protocol, state machine, discovery, write queue
-- ============================================================================

Protocol = {
  -- State machine constants
  STATE_INIT = 0,
  STATE_NO_MODULE = 1,
  STATE_DISCOVER_ROOT = 2,
  STATE_DISCOVER_CHILDREN = 3,
  STATE_DISCOVER_VTX = 4,
  STATE_READY = 5,
  STATE_SENDING = 6,

  -- Current state
  state = 0, -- STATE_INIT
  statusText = "Initializing...",

  -- Discovery
  loadQueue = {},
  rootChildren = {},
  vtxChildren = {},
  fieldTimeout = 0,
  discoveredFields = {},

  -- Write queue
  writeQueue = {},
  writeIdx = 0,
  lastWriteTime = 0,

  -- Folder re-read timer
  lastFolderPoll = 0,
  FOLDER_POLL_INTERVAL = 200, -- 2 seconds
}

-- State query helpers
function Protocol.isReady()
  return Protocol.state == Protocol.STATE_READY
end

function Protocol.isSending()
  return Protocol.state == Protocol.STATE_SENDING
end

function Protocol.isActive()
  return Protocol.state == Protocol.STATE_READY or Protocol.state == Protocol.STATE_SENDING
end

--- True when a CRSF module answered discovery. Weaker than isActive(): the 6POS preset
--- cheatsheet is local radio state read from presets.txt, not VTX telemetry, so it is worth
--- showing before discovery finishes.
function Protocol.hasModule()
  return Protocol.state ~= Protocol.STATE_NO_MODULE
end

-- Response timeout for PARAMETER_READ: 0.5s for local TX module.
function Protocol.fieldResponseTimeout()
  return 50
end

-- ============================================================================
-- Protocol: Parse helpers
-- ============================================================================

--- Parse child IDs from a FOLDER-type PARAMETER_SETTINGS_ENTRY payload.
function Protocol.parseChildIds(data)
  local ids = {}
  local off = 7
  while data[off] ~= nil and data[off] ~= 0 do
    off = off + 1
  end
  off = off + 1 -- skip null terminator
  while data[off] ~= nil and data[off] ~= crsf.CONST.FIELD_LIST_END do
    ids[#ids + 1] = data[off]
    off = off + 1
  end
  return ids
end

--- Parse field name from a PARAMETER_SETTINGS_ENTRY payload.
function Protocol.parseFieldName(data)
  local off = 7
  local startOff = off
  while data[off] ~= nil and data[off] ~= 0 do
    off = off + 1
  end
  local chars = {}
  for i = startOff, off - 1 do
    chars[#chars + 1] = string.char(data[i])
  end
  return table.concat(chars)
end

--- Parse field type from a PARAMETER_SETTINGS_ENTRY payload.
function Protocol.parseFieldType(data)
  return bit32.band(data[6] or 0, 0x7F)
end

-- ============================================================================
-- Protocol: Sending
-- ============================================================================

function Protocol.sendParameterRead(fieldId)
  crsf.push(crsf.CONST.FRAMETYPE_PARAMETER_READ, { crsf.CONST.ADDRESS_TX, crsf.CONST.ADDRESS_HANDSET_ELRS, fieldId, 0 })
end

function Protocol.sendParameterWrite(fieldId, value)
  crsf.push(
    crsf.CONST.FRAMETYPE_PARAMETER_WRITE,
    { crsf.CONST.ADDRESS_TX, crsf.CONST.ADDRESS_HANDSET_ELRS, fieldId, value }
  )
end

-- ============================================================================
-- Protocol: Response handler (registered on singleton dispatcher)
-- ============================================================================

function Protocol.onSettingsEntry(data)
  if data[2] ~= crsf.CONST.ADDRESS_TX then
    return
  end

  local fieldId = data[3]
  local fieldType = Protocol.parseFieldType(data)
  local fieldName = Protocol.parseFieldName(data)

  Protocol.discoveredFields[fieldId] = { name = fieldName, type = fieldType }

  -- Pop the field from load queue if it matches
  if #Protocol.loadQueue > 0 and Protocol.loadQueue[#Protocol.loadQueue] == fieldId then
    Protocol.loadQueue[#Protocol.loadQueue] = nil
    Protocol.fieldTimeout = 0
  end

  local st = Protocol.state

  if st == Protocol.STATE_DISCOVER_ROOT then
    if fieldId == 0 and fieldType == crsf.CONST.FIELD_FOLDER then
      Protocol.rootChildren = Protocol.parseChildIds(data)
      for i = #Protocol.rootChildren, 1, -1 do
        Protocol.loadQueue[#Protocol.loadQueue + 1] = Protocol.rootChildren[i]
      end
      Protocol.state = Protocol.STATE_DISCOVER_CHILDREN
      Protocol.statusText = "Discovering fields..."
    end
  elseif st == Protocol.STATE_DISCOVER_CHILDREN then
    if fieldType == crsf.CONST.FIELD_FOLDER and string.sub(fieldName, 1, 9) == "VTX Admin" then
      VTX.ids.folder = fieldId
      Protocol.vtxChildren = Protocol.parseChildIds(data)
      VTX.parseFolderName(fieldName)
      for i = #Protocol.vtxChildren, 1, -1 do
        Protocol.loadQueue[#Protocol.loadQueue + 1] = Protocol.vtxChildren[i]
      end
      Protocol.state = Protocol.STATE_DISCOVER_VTX
      Protocol.statusText = "Loading VTX fields..."
    end
    if #Protocol.loadQueue == 0 and VTX.ids.folder == nil then
      Protocol.statusText = "VTX Admin not found"
    end
  elseif st == Protocol.STATE_DISCOVER_VTX then
    if fieldName == "Band" or fieldName == "Band/Enable" then
      VTX.ids.band = fieldId
    elseif fieldName == "Channel" then
      VTX.ids.channel = fieldId
    elseif fieldName == "Pwr Lvl" then
      VTX.ids.power = fieldId
    elseif fieldName == "Pitmode" then
      VTX.ids.pitmode = fieldId
    elseif fieldName == "Send VTx" then
      VTX.ids.send = fieldId
    end

    if #Protocol.loadQueue == 0 then
      if VTX.ids.band and VTX.ids.channel and VTX.ids.power and VTX.ids.pitmode and VTX.ids.send then
        Protocol.state = Protocol.STATE_READY
        Protocol.statusText = ""
        VTX.syncDesiredFromState()
      else
        Protocol.statusText = "VTX fields incomplete"
      end
    end
  elseif st == Protocol.STATE_READY then
    if fieldId == VTX.ids.folder then
      VTX.parseFolderName(fieldName)
    end
  end
end

-- Register on the shared CRSF singleton
crsf:registerHandler(crsf.CONST.FRAMETYPE_PARAMETER_SETTINGS_ENTRY, Protocol.onSettingsEntry)

-- ============================================================================
-- Protocol: State machine tick
-- ============================================================================

function Protocol.tick()
  local now = getTime()
  local st = Protocol.state

  if st == Protocol.STATE_INIT then
    if crsf.hasCrsfModule() then
      Protocol.state = Protocol.STATE_DISCOVER_ROOT
      Protocol.statusText = "Discovering..."
      Protocol.loadQueue = { 0 }
      Protocol.fieldTimeout = 0
    else
      Protocol.state = Protocol.STATE_NO_MODULE
      Protocol.statusText = "No CRSF module"
    end
  elseif
    st == Protocol.STATE_DISCOVER_ROOT
    or st == Protocol.STATE_DISCOVER_CHILDREN
    or st == Protocol.STATE_DISCOVER_VTX
  then
    if #Protocol.loadQueue > 0 and now >= Protocol.fieldTimeout then
      local fieldId = Protocol.loadQueue[#Protocol.loadQueue]
      Protocol.sendParameterRead(fieldId)
      Protocol.fieldTimeout = now + Protocol.fieldResponseTimeout()
    end
  elseif st == Protocol.STATE_READY then
    if now - Protocol.lastFolderPoll >= Protocol.FOLDER_POLL_INTERVAL then
      Protocol.lastFolderPoll = now
      Protocol.sendParameterRead(VTX.ids.folder)
    end
  elseif st == Protocol.STATE_SENDING then
    if Protocol.writeIdx <= #Protocol.writeQueue then
      if now - Protocol.lastWriteTime >= 5 then -- 50ms
        local entry = Protocol.writeQueue[Protocol.writeIdx]
        print(table.concat({ "VTXAdmin: writing field=", entry[1], " val=", entry[2] }))
        Protocol.sendParameterWrite(entry[1], entry[2])
        Protocol.lastWriteTime = now
        Protocol.writeIdx = Protocol.writeIdx + 1
      end
    else
      print(table.concat({ "VTXAdmin: write queue complete, ", #Protocol.writeQueue, " entries sent" }))
      Protocol.writeQueue = {}
      Protocol.writeIdx = 0
      Protocol.state = Protocol.STATE_READY
      Protocol.lastFolderPoll = now - Protocol.FOLDER_POLL_INTERVAL + 10
    end
  end
end

-- ============================================================================
-- Protocol: Write queue builder
-- ============================================================================

--- Write changed config fields (band, channel, power, pitmode) to the ELRS module.
--- Does NOT send the "Send VTx" command — call pushToVtx() separately for that.
function Protocol.writeConfig()
  if not Protocol.isReady() then
    print("VTXAdmin: writeConfig() skipped - not ready")
    return
  end

  local s = VTX.state
  local d = VTX.desired
  Protocol.writeQueue = {}

  print(table.concat({
    "VTXAdmin: writeConfig() desired: band=",
    d.band,
    " ch=",
    d.channel,
    " pwr=",
    d.power,
    " pit=",
    tostring(d.pitmode),
  }))
  print(table.concat({
    "VTXAdmin: writeConfig() current: band=",
    s.band,
    " ch=",
    s.channel,
    " pwr=",
    s.power,
    " pit=",
    tostring(s.pitmode),
  }))

  if d.band ~= s.band then
    Protocol.writeQueue[#Protocol.writeQueue + 1] = { VTX.ids.band, d.band }
  end
  if d.channel ~= s.channel then
    Protocol.writeQueue[#Protocol.writeQueue + 1] = { VTX.ids.channel, d.channel }
  end
  if d.power ~= s.power then
    Protocol.writeQueue[#Protocol.writeQueue + 1] = { VTX.ids.power, d.power }
  end

  local desiredPit = d.pitmode
  if type(desiredPit) == "boolean" then
    desiredPit = desiredPit and 1 or 0
  end
  local currentPit = s.pitmode and 1 or 0
  if desiredPit ~= currentPit then
    Protocol.writeQueue[#Protocol.writeQueue + 1] = { VTX.ids.pitmode, desiredPit }
  end

  print(table.concat({ "VTXAdmin: write queue built, ", #Protocol.writeQueue, " field(s)" }))

  if #Protocol.writeQueue > 0 then
    Protocol.writeIdx = 1
    Protocol.lastWriteTime = 0
    Protocol.state = Protocol.STATE_SENDING
  end
end

--- Append the "Send VTx" command to the write queue, pushing config to the VTX.
function Protocol.pushToVtx()
  if not Protocol.isReady() and Protocol.state ~= Protocol.STATE_SENDING then
    print("VTXAdmin: pushToVtx() skipped - not ready")
    return
  end

  print("VTXAdmin: pushToVtx() - queuing Send VTx command")
  Protocol.writeQueue[#Protocol.writeQueue + 1] = { VTX.ids.send, crsf.CONST.CMD_CLICK }

  if Protocol.state ~= Protocol.STATE_SENDING then
    Protocol.writeIdx = 1
    Protocol.lastWriteTime = 0
    Protocol.state = Protocol.STATE_SENDING
  end
end

-- ============================================================================
-- Presets Module: 6POS preset storage, file I/O, quick-change processing
-- ============================================================================

Presets = {
  PATH = "/WIDGETS/ELRSVTXAdmin/presets.txt",

  -- Preset data
  items = {},
  enabled = false,
  source = 0, -- 6POS source ID (0 = not configured)
  autoPushVtx = false, -- auto push to VTX on 6POS change
  pushSource = 0, -- source ID for manual "Send VTx" trigger (0 = not configured)

  -- 6POS processing state
  lastPos = -1,
  stablePos = -1,
  stableTime = 0,
  DEBOUNCE = 20, -- 200ms in getTime() ticks (10ms each)

  -- Push source edge detection state. nil until the first sample has been taken.
  ---@type boolean?
  pushLastHigh = nil,
}

-- ============================================================================
-- Presets: File I/O (key=value format)
-- ============================================================================

--- Parse a "key=value" line using plain string.find (no regex).
--- Returns key, value strings or nil if no '=' found.
local function parseKV(line)
  local eq = string.find(line, "=", 1, true)
  if not eq then
    return nil, nil
  end
  return string.sub(line, 1, eq - 1), string.sub(line, eq + 1)
end

--- Split "band,channel" using plain string.find (no regex).
local function splitBandChannel(val)
  local comma = string.find(val, ",", 1, true)
  if not comma then
    return nil, nil
  end
  return tonumber(string.sub(val, 1, comma - 1)), tonumber(string.sub(val, comma + 1))
end

--- File format: key=value lines (one per line).
--- Keys: enabled, source, autoPushVtx, pushSource, p1..p6 (values: "band,channel").
function Presets.load()
  local p = {}
  local enabled = false
  local source = 0
  local autoPushVtx = false
  local pushSource = 0
  local f = io.open(Presets.PATH, "r")
  if f then
    local data = io.read(f, 512)
    io.close(f)
    if data and #data > 0 then
      -- Split by newlines using plain string.find
      local pos = 1
      while pos <= #data do
        local nl = string.find(data, "\n", pos, true)
        local line
        if nl then
          line = string.sub(data, pos, nl - 1)
          pos = nl + 1
        else
          line = string.sub(data, pos)
          pos = #data + 1
        end
        local key, val = parseKV(line)
        if key == "enabled" then
          enabled = (val == "1")
        elseif key == "source" then
          source = tonumber(val) or 0
        elseif key == "autoPushVtx" then
          autoPushVtx = (val == "1")
        elseif key == "pushSource" then
          pushSource = tonumber(val) or 0
        elseif key and val then
          -- Check for p1..p6 using plain sub
          if string.sub(key, 1, 1) == "p" then
            local idx = tonumber(string.sub(key, 2))
            if idx and idx >= 1 and idx <= 6 then
              local b, ch = splitBandChannel(val)
              if b and ch then
                p[idx] = { band = b, channel = ch }
              end
            end
          end
        end
      end
    end
  end
  -- Fill missing positions with Raceband defaults (R1..R6)
  for i = 1, 6 do
    if not p[i] then
      p[i] = { band = 5, channel = i }
    end
  end
  Presets.items = p
  Presets.enabled = enabled
  Presets.source = source
  Presets.autoPushVtx = autoPushVtx
  Presets.pushSource = pushSource

  print(table.concat({
    "VTXAdmin: presets loaded - enabled=",
    tostring(enabled),
    " source=",
    source,
    " autoPushVtx=",
    tostring(autoPushVtx),
    " pushSource=",
    pushSource,
  }))
  for i = 1, 6 do
    print(table.concat({ "VTXAdmin:   preset ", i, ": band=", p[i].band, " ch=", p[i].channel }))
  end
end

function Presets.save()
  print(table.concat({ "VTXAdmin: saving presets to ", Presets.PATH }))
  local f = io.open(Presets.PATH, "w")
  if f then
    io.write(f, table.concat({ "enabled=", Presets.enabled and "1" or "0", "\n" }))
    io.write(f, table.concat({ "source=", Presets.source, "\n" }))
    io.write(f, table.concat({ "autoPushVtx=", Presets.autoPushVtx and "1" or "0", "\n" }))
    io.write(f, table.concat({ "pushSource=", Presets.pushSource, "\n" }))
    for i = 1, 6 do
      io.write(f, table.concat({ "p", i, "=", Presets.items[i].band, ",", Presets.items[i].channel, "\n" }))
    end
    io.close(f)
    print("VTXAdmin: presets saved OK")
  else
    print(table.concat({ "VTXAdmin: ERROR - could not open ", Presets.PATH, " for writing" }))
  end
end

-- ============================================================================
-- Presets: 6POS quick-change processing
-- ============================================================================

local function mapTo6Pos(value)
  local pos = math.floor((value + 1024) * 6 / 2049) + 1
  if pos < 1 then
    pos = 1
  end
  if pos > 6 then
    pos = 6
  end
  return pos
end

--- Called every background tick. Reads the 6POS source, debounces,
--- and triggers a VTX send on edge-detected position changes.
function Presets.process()
  if not Presets.enabled then
    return
  end
  if Presets.source == 0 then
    return
  end

  local value = getValue(Presets.source)
  if value == nil then
    return
  end

  local pos = mapTo6Pos(value)
  local now = getTime()

  -- Debounce: require stable position for DEBOUNCE ticks
  if pos ~= Presets.stablePos then
    Presets.stablePos = pos
    Presets.stableTime = now
    return
  end
  if now - Presets.stableTime < Presets.DEBOUNCE then
    return
  end

  -- Only consume a position once a write can actually land. writeConfig() drops
  -- everything outside STATE_READY, and lastPos is latched before it is called, so
  -- latching any earlier discards the position permanently -- during a send, and during
  -- discovery whenever it outruns the debounce. Holding until ready is also what makes
  -- the first tick after discovery assert the boot position to the module.
  if not Protocol.isReady() then
    return
  end

  -- Edge-triggered: only send on position change
  if pos == Presets.lastPos then
    return
  end
  Presets.lastPos = pos

  local preset = Presets.items[pos]
  if preset and preset.band > 0 then
    -- Re-base on the module's current state so a 6POS change only ever writes band and
    -- channel. VTX.desired can hold stale power/pitmode: ExpressLRS omits both from the
    -- folder name when power is "-", and nothing re-syncs after a send completes.
    VTX.syncDesiredFromState()
    VTX.desired.band = preset.band
    VTX.desired.channel = preset.channel
    print(table.concat({ "VTXAdmin: 6POS pos=", pos, " -> band=", preset.band, " ch=", preset.channel }))
    Protocol.writeConfig()
    if Presets.autoPushVtx then
      Protocol.pushToVtx()
    end
  else
    print(table.concat({ "VTXAdmin: 6POS pos=", pos, " -> Off (skipped)" }))
  end
end

--- Called every background tick. Edge-detects the pushSource going high
--- and triggers Protocol.pushToVtx() to send the current config to the VTX.
function Presets.processPushSource()
  if Presets.autoPushVtx then
    return
  end
  if Presets.pushSource == 0 then
    return
  end

  local val = getValue(Presets.pushSource)
  if val == nil then
    return
  end

  local high = val > 0
  local wasHigh = Presets.pushLastHigh
  Presets.pushLastHigh = high

  if wasHigh == nil then
    -- First sample after create or reassignment: adopt the level without firing. A
    -- source that is already high was not just moved there by the user.
    return
  end

  -- Edge detection: trigger only on rising edge (low -> high)
  if high and not wasHigh then
    print("VTXAdmin: push source triggered - sending VTx command")
    Protocol.pushToVtx()
  end
end

-- Initialize presets from file
Presets.load()

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
  return VTX.isTuned()
end

--- True when a status message should be shown (loading, error, VTX off).
function VTXDisplay.showStatus()
  return not VTX.isTuned()
end

--- Band + channel string (e.g. "F6", "R4") when VTX is tuned, "" otherwise.
function VTXDisplay.bandChannel()
  if not VTX.isTuned() then
    return ""
  end
  return table.concat({ VTX.state.bandLetter, VTX.state.channel })
end

--- Short status message for non-VTX states, "" when VTX is tuned.
function VTXDisplay.statusText()
  if not Protocol.hasModule() then
    return "No module"
  end
  if not Protocol.isActive() then
    return "Loading..."
  end
  if VTX.state.band == 0 then
    return "VTX Off"
  end
  return ""
end

function VTXDisplay.powerShort()
  if not VTX.hasPower() then
    return ""
  end
  return table.concat({ "P", VTX.state.power })
end

function VTXDisplay.powerLong()
  if not VTX.hasPower() then
    return ""
  end
  return table.concat({ "Power ", VTX.state.power })
end

--- Pit mode state. "" when no power is set: ExpressLRS cannot send pit mode without it.
--- A switch binding names the switch rather than asserting a position the folder name
--- does not carry.
function VTXDisplay.pitText()
  if not VTX.hasPower() then
    return ""
  end
  if VTX.state.pitmode then
    return "Pit Mode On"
  end
  if VTX.state.pitmodeAux then
    return table.concat({ "Pit Mode ", VTX.state.pitmodeAux })
  end
  return "Pit Mode Off"
end

--- As pitText, but reports a disabled VTX instead of falling silent.
function VTXDisplay.pitTextLong()
  if VTX.isDisabled() then
    return "VTX Disabled"
  end
  return VTXDisplay.pitText()
end

--- Terse flag for narrow tiers. Only a confirmed pit mode is worth the width.
function VTXDisplay.pitShort()
  return VTX.state.pitmode and "Pit" or ""
end

--- Red only when pit mode is confirmed on. An aux binding is not an assertion.
function VTXDisplay.pitColor()
  return VTX.state.pitmode and RED or COLOR_THEME_SECONDARY1
end

function VTXDisplay.detailLine()
  if not VTX.hasPower() then
    return ""
  end
  return table.concat({ VTXDisplay.powerShort(), " ", VTXDisplay.pitText() })
end

function VTXDisplay.detailLong()
  if VTX.isDisabled() then
    return "VTX Disabled"
  end
  if not VTX.hasPower() then
    return ""
  end
  return table.concat({ VTXDisplay.powerLong(), "  ", VTXDisplay.pitText() })
end

function VTXDisplay.mainColor()
  if VTX.state.pitmode then
    return RED
  end
  return COLOR_THEME_PRIMARY1
end

function VTXDisplay.build6posLabels(font)
  if not Protocol.hasModule() then
    return {}
  end
  if not Presets.enabled then
    return {}
  end
  local labels = {}
  for i = 1, 6 do
    local idx = i
    labels[#labels + 1] = {
      type = lvgl.LABEL,
      font = font or SMLSIZE,
      color = function()
        return (Presets.lastPos == idx) and COLOR_THEME_PRIMARY1 or COLOR_THEME_DISABLED
      end,
      text = function()
        local p = Presets.items[idx]
        if p.band == 0 then
          return table.concat({ idx, ":--" })
        end
        return table.concat({ idx, ":", VTX.BAND_LETTERS[p.band] or "?", p.channel })
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
    visible = Protocol.hasModule,
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
    return "sd_tall" -- 480x320 (TX16S)
  else
    return "sd" -- 480x272
  end
end

--- Convert Transparency option (0-5) to LVGL opacity (255-0).
local function bgOpacity(opts)
  local t = (opts and opts.Transparency) or 2
  return math.max(0, 255 - 51 * t)
end

local screenId = getScreenId()
local uiPath = table.concat({ "/WIDGETS/ELRSVTXAdmin/ui/", screenId, ".lua" })
local WidgetUI = loadScript(uiPath)({
  crsf = crsf,
  VTX = VTX,
  Protocol = Protocol,
  Presets = Presets,
  bgOpacity = bgOpacity,
  VTXDisplay = VTXDisplay,
  WidgetLayout = WidgetLayout,
})

-- ============================================================================
-- Full-screen row helpers (shared across all screen sizes)
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

local function createToggleRow(container, label, getFn, setFn, visibleFn)
  local ctrl = createRow(container, label, nil, visibleFn)
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

local function buildFullScreen()
  lvgl.clear()

  local d = VTX.desired

  local pg = lvgl.page({
    title = "ExpressLRS",
    subtitle = function()
      if Protocol.isActive() then
        return "VTX Administrator"
      end
      return Protocol.statusText
    end,
    back = function()
      lvgl.exitFullScreen()
    end,
  })

  -- No module — show checklist instead of controls (matches expresslrs.lua NoModuleDialog)
  if not Protocol.hasModule() then
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
    Protocol.writeConfig()
  end)

  createNumberRow(fields, "Channel", 1, 8, function()
    return d.channel
  end, function(v)
    d.channel = v
  end, function(v)
    d.channel = v
    Protocol.writeConfig()
  end)

  createNumberRow(fields, "Power Level", 0, 8, function()
    return d.power
  end, function(v)
    d.power = v
  end, function(v)
    d.power = v
    Protocol.writeConfig()
  end, function(v)
    return v == 0 and "-" or tostring(v)
  end)

  -- Pit mode rides on the power byte, so ExpressLRS hides it while power is "-".
  createToggleRow(fields, "Pit Mode", function()
    return d.pitmode
  end, function(v)
    d.pitmode = v
    Protocol.writeConfig()
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
      if Protocol.isSending() then
        return "Sending..."
      end
      return "Send VTx"
    end,
    w = lvgl.PERCENT_SIZE + 99,
    press = function()
      Protocol.writeConfig()
      Protocol.pushToVtx()
    end,
    active = function()
      return Protocol.isReady()
    end,
  })

  -- 6POS Quick Change section
  createSectionHeader(fields, "6POS Quick Change")

  createToggleRow(fields, "Enabled", function()
    return Presets.enabled and 1 or 0
  end, function(v)
    Presets.enabled = (v == 1)
    Presets.save()
  end)

  createSourceRow(fields, "Source", function()
    return Presets.source
  end, function(v)
    Presets.source = v or 0
    Presets.save()
  end, lvgl.SRC_STICK + lvgl.SRC_POT + lvgl.SRC_SWITCH)

  createToggleRow(fields, "Auto Push to VTX", function()
    return Presets.autoPushVtx and 1 or 0
  end, function(v)
    Presets.autoPushVtx = (v == 1)
    Presets.save()
  end)

  createSourceRow(
    fields,
    "Send VTx Trigger",
    function()
      return Presets.pushSource
    end,
    function(v)
      Presets.pushSource = v or 0
      Presets.pushLastHigh = nil
      Presets.save()
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
        return Presets.items[idx].band + 1
      end,
      set = function(v)
        Presets.items[idx].band = v - 1
        Presets.save()
      end,
    })

    ctrl:numberEdit({
      min = 1,
      max = 8,
      get = function()
        return Presets.items[idx].channel
      end,
      set = function(v)
        Presets.items[idx].channel = v
        Presets.save()
      end,
      visible = function()
        return Presets.items[idx].band > 0
      end,
    })
  end
end

-- ============================================================================
-- Widget lifecycle
-- ============================================================================

local lastBuilt6pos = -1

local wgt = {
  zone = zone,
  options = options,
}

function wgt.background()
  crsf:poll()
  Protocol.tick()
  Presets.process()
  Presets.processPushSource()
end

function wgt.refresh(_event, _touchState)
  wgt.background()
  if lvgl.isFullScreen() and Presets.lastPos ~= lastBuilt6pos then
    lastBuilt6pos = Presets.lastPos
    buildFullScreen()
  end
end

function wgt.update(newOptions)
  wgt.options = newOptions
  if lvgl.isFullScreen() then
    if Protocol.isReady() then
      VTX.syncDesiredFromState()
    end
    buildFullScreen()
    lastBuilt6pos = Presets.lastPos
  else
    lastBuilt6pos = -1
    WidgetUI.build(wgt.zone, wgt.options)
  end
end

-- Initial build
WidgetUI.build(wgt.zone, wgt.options)

return wgt
