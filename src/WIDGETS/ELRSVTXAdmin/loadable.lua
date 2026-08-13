---------------------------------------------------------------------------
-- VTX Administrator Widget - Core                                       --
-- Loaded via loadScript() from ELRSVTXAdmin/main.lua                    --
--                                                                       --
-- Home of the VTXAdmin component: client of the ELRS TX module's VTX    --
-- Administrator over the CRSF config protocol (PARAMETER_READ/WRITE).   --
-- Field IDs are discovered at runtime by name -- never hardcoded.       --
--                                                                       --
-- Wires the components around it -- ui/display.lua, ui/fullscreen.lua   --
-- and a screen-specific minimized layout from ui/ picked by LCD_W/LCD_H --
-- -- then runs the widget lifecycle. Loaded fresh per widget instance,  --
-- so every table here is per-instance state, except PresetsStorage:     --
-- main.lua hands every instance the same store, whose latch table is    --
-- how the 6POS automation consumes an edge exactly once per radio.      --
---------------------------------------------------------------------------

local zone, options, crsf, CRSFSession, PresetsStorage = ...

-- ============================================================================
-- VTXAdmin: client of the ELRS "VTX Administrator" service on the TX module
-- Discovery state machine, current/desired VTX state, write policy,
-- 6POS quick-change and push-trigger automation
-- ============================================================================

-- Every widget instance owns a CRSF parameter session in passive fan-out
-- mode: any field from the TX module is accepted, so sibling instances see
-- every response they did not request themselves.
local session

local VTXAdmin = {
  -- State machine phase constants. "phase" rather than "state": VTXAdmin.state
  -- below is the VTX state parsed from the folder name.
  PHASE_INIT = 0,
  PHASE_NO_MODULE = 1,
  PHASE_DISCOVER_ROOT = 2,
  PHASE_DISCOVER_CHILDREN = 3,
  PHASE_DISCOVER_VTX = 4,
  PHASE_READY = 5,
  PHASE_SENDING = 6,

  -- Current state machine phase
  phase = 0, -- PHASE_INIT

  -- Previous tick timestamp, to detect suspension: a standalone tool pauses
  -- widget scripts, and whatever it changed needs one read-back on resume.
  lastTick = 0,

  -- 6POS debounce window. The processing state itself -- consumed position,
  -- collection, push trigger level -- lives on PresetsStorage.latch, shared
  -- across widget instances.
  DEBOUNCE = 20, -- 200ms in getTime() ticks (10ms each)

  -- Field IDs (discovered at runtime)
  ids = {
    folder = nil,
    band = nil,
    channel = nil,
    power = nil,
    pitmode = nil,
    send = nil,
  },

  -- Band lookup tables. BAND_LETTERS is 1-based: band 0 has no letter, and its label
  -- differs by context ("Off" for a disabled VTX, "--" for an unused 6POS preset slot).
  BAND_LETTERS = { "A", "B", "E", "F", "R", "L" },
  BAND_VALUES = { Off = 0, A = 1, B = 2, E = 3, F = 4, R = 5, L = 6 },

  -- Status line shown by the UI until discovery finishes
  statusText = "Initializing...",

  -- Current VTX state (parsed from folder name). Stable table identity:
  -- mutated in place, never replaced -- UI closures capture a reference.
  state = {
    band = 0, -- 0=Off, 1=A, 2=B, 3=E, 4=F, 5=R, 6=L
    bandLetter = "?",
    channel = 0,
    power = 0,
    pitmode = false, -- true only when pit mode is confirmed on
    pitmodeAux = nil, -- switch name when pit mode is bound to an aux switch
  },

  -- Desired VTX state (edited by user in full-screen UI). Same stable
  -- identity contract as state.
  desired = {
    band = 5, -- Raceband
    channel = 1,
    power = 0,
    pitmode = 0,
  },
}

--- Parse "VTX Admin (R:4:2:P)" into VTXAdmin.state fields.
-- ExpressLRS writes "VTX Admin (BAND:CHANNEL[:POWER[:PITMODE]])": band Off drops the whole
-- suffix, power "-" drops both power and pit mode, pit mode Off drops itself. PITMODE is "P"
-- when set to On, or the aux label ("AUX1\192".."AUX10\193", \192/\193 = up/down arrow) when
-- bound to a switch. The name carries only the binding, never the switch position, so an aux
-- binding sets pitmodeAux and leaves pitmode false.
local function parseFolderName(name)
  local s = VTXAdmin.state
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
  s.band = VTXAdmin.BAND_VALUES[parts[1]] or 0
  s.channel = tonumber(parts[2]) or 0
  s.power = tonumber(parts[3]) or 0
  if #parts < 4 then
    s.pitmode = false
    s.pitmodeAux = nil
  elseif parts[4] == "P" then
    s.pitmode = true
    s.pitmodeAux = nil
  else
    -- Strip the trailing up/down arrow: the shared decoder translates the
    -- firmware's one-byte arrows into the (multi-byte) CHAR_UP/CHAR_DOWN
    -- glyphs before the name reaches us.
    s.pitmode = false
    local part = parts[4]
    if CHAR_UP and string.sub(part, -#CHAR_UP) == CHAR_UP then
      s.pitmodeAux = string.sub(part, 1, -#CHAR_UP - 1)
    elseif CHAR_DOWN and string.sub(part, -#CHAR_DOWN) == CHAR_DOWN then
      s.pitmodeAux = string.sub(part, 1, -#CHAR_DOWN - 1)
    else
      s.pitmodeAux = string.sub(part, 1, -2)
    end
  end
  return true
end

--- True when the VTX is tuned to a band.
function VTXAdmin.isTuned()
  return VTXAdmin.isActive() and VTXAdmin.state.band > 0
end

--- True when the module is up but the VTX band is set to Off.
function VTXAdmin.isDisabled()
  return VTXAdmin.isActive() and VTXAdmin.state.band == 0
end

--- True when a power level is set. ExpressLRS omits power and pit mode from the VTX Admin
--- folder name when power is "-", and hides the Pitmode field entirely, so neither value is
--- meaningful until a power level is chosen.
function VTXAdmin.hasPower()
  return VTXAdmin.isTuned() and VTXAdmin.state.power > 0
end

--- Sync desired values with current state (e.g. on discovery or entering full-screen).
function VTXAdmin.syncDesiredFromState()
  local s = VTXAdmin.state
  local d = VTXAdmin.desired
  d.band = s.band
  d.channel = s.channel
  d.power = s.power
  d.pitmode = s.pitmode and 1 or 0
end

-- ============================================================================
-- VTXAdmin: state machine query helpers
-- ============================================================================

function VTXAdmin.isReady()
  return VTXAdmin.phase == VTXAdmin.PHASE_READY
end

function VTXAdmin.isSending()
  return VTXAdmin.phase == VTXAdmin.PHASE_SENDING
end

function VTXAdmin.isActive()
  return VTXAdmin.phase == VTXAdmin.PHASE_READY or VTXAdmin.phase == VTXAdmin.PHASE_SENDING
end

--- True when a CRSF module answered discovery. Weaker than isActive(): the 6POS preset
--- cheatsheet is local radio state read from presets.txt, not VTX telemetry, so it is worth
--- showing before discovery finishes.
function VTXAdmin.hasModule()
  return VTXAdmin.phase ~= VTXAdmin.PHASE_NO_MODULE
end

-- ============================================================================
-- VTXAdmin: field handler (session onFieldUpdate callback)
-- ============================================================================

local function onField(field)
  local fieldId = field.id
  local fieldName = field.name

  if VTXAdmin.phase == VTXAdmin.PHASE_DISCOVER_ROOT then
    if fieldId == 0 and field.type == crsf.CONST.FIELD_FOLDER then
      -- The session auto-queues the root children off this entry
      VTXAdmin.phase = VTXAdmin.PHASE_DISCOVER_CHILDREN
      VTXAdmin.statusText = "Discovering fields..."
    end
  elseif VTXAdmin.phase == VTXAdmin.PHASE_DISCOVER_CHILDREN then
    if field.type == crsf.CONST.FIELD_FOLDER and string.sub(fieldName, 1, 9) == "VTX Admin" then
      VTXAdmin.ids.folder = fieldId
      parseFolderName(fieldName)
      session:loadFolder(fieldId)
      VTXAdmin.phase = VTXAdmin.PHASE_DISCOVER_VTX
      VTXAdmin.statusText = "Loading VTX fields..."
    elseif not session:isLoading() and VTXAdmin.ids.folder == nil then
      VTXAdmin.statusText = "VTX Admin not found"
    end
  elseif VTXAdmin.phase == VTXAdmin.PHASE_DISCOVER_VTX then
    if fieldName == "Band" or fieldName == "Band/Enable" then
      VTXAdmin.ids.band = fieldId
    elseif fieldName == "Channel" then
      VTXAdmin.ids.channel = fieldId
    elseif fieldName == "Pwr Lvl" then
      VTXAdmin.ids.power = fieldId
    elseif fieldName == "Pitmode" then
      VTXAdmin.ids.pitmode = fieldId
    elseif fieldName == "Send VTx" then
      VTXAdmin.ids.send = fieldId
    end

    if not session:isLoading() then
      if
        VTXAdmin.ids.band
        and VTXAdmin.ids.channel
        and VTXAdmin.ids.power
        and VTXAdmin.ids.pitmode
        and VTXAdmin.ids.send
      then
        VTXAdmin.phase = VTXAdmin.PHASE_READY
        VTXAdmin.statusText = ""
        VTXAdmin.syncDesiredFromState()
      else
        VTXAdmin.statusText = "VTX fields incomplete"
      end
    end
  elseif VTXAdmin.phase == VTXAdmin.PHASE_READY then
    if fieldId == VTXAdmin.ids.folder then
      parseFolderName(fieldName)
    end
  end
end

session = CRSFSession.new({
  acceptUnsolicited = true,
  responseTimeout = 50, -- always the local TX module
  onFieldUpdate = onField,
})

-- ============================================================================
-- VTXAdmin: 6POS quick-change and push-trigger automation
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

--- Runs every tick. Reads the 6POS source, debounces, and applies the matching
--- preset when the consumed (collection, position) pair changes. The state
--- lives on the shared latch so an edge produces one write per radio, not one
--- per instance: widget callbacks run sequentially in one Lua state, so the
--- first instance that can act consumes the edge and the rest see none.
local function process6Pos()
  if not PresetsStorage.enabled then
    return
  end
  if PresetsStorage.source == 0 then
    return
  end

  local value = getValue(PresetsStorage.source)
  if value == nil then
    return
  end

  local latch = PresetsStorage.latch
  local pos = mapTo6Pos(value)
  local now = getTime()

  -- Debounce: require stable position for DEBOUNCE ticks. Shared: the source
  -- is radio state, so one debounce serves every instance.
  if pos ~= latch.stablePos then
    latch.stablePos = pos
    latch.stableTime = now
    return
  end
  if now - latch.stableTime < VTXAdmin.DEBOUNCE then
    return
  end

  -- Only consume a position once THIS instance can write. writeConfig() drops
  -- everything outside the ready phase, and the latch is taken before it is
  -- called, so latching any earlier discards the edge permanently -- for every
  -- instance at once. Holding until ready is also what makes the first tick
  -- after discovery assert the boot position to the module.
  if not VTXAdmin.isReady() then
    return
  end

  -- Edge-triggered: send when either half of the (collection, position) pair
  -- the module is holding changes. Picking a different collection retunes the
  -- VTX without touching the switch.
  if pos == latch.lastPos and PresetsStorage.collection == latch.lastCollection then
    return
  end
  latch.lastPos = pos
  latch.lastCollection = PresetsStorage.collection

  -- An unused slot leaves the VTX untouched rather than turning it off. The
  -- latch is already taken, so this is deliberate: the skip does not retry.
  local preset = PresetsStorage.items[pos]
  if not preset or preset.band == 0 then
    return
  end

  VTXAdmin.applyPreset(preset.band, preset.channel)
  if PresetsStorage.autoPushVtx then
    VTXAdmin.pushToVtx()
  end
end

--- Runs every tick. Edge-detects the pushSource going high and triggers
--- pushToVtx() to send the current config to the VTX. The state lives on the
--- shared latch so a rising edge fires one push per radio, not one per
--- instance.
local function processPushTrigger()
  if PresetsStorage.autoPushVtx then
    return
  end
  if PresetsStorage.pushSource == 0 then
    return
  end

  local val = getValue(PresetsStorage.pushSource)
  if val == nil then
    return
  end

  local latch = PresetsStorage.latch
  local high = val > 0

  -- The level latch is only meaningful for the source it was sampled from: a
  -- reassignment adopts the new source's level without firing. A source that
  -- is already high was not just moved there by the user. This also seeds the
  -- latch on the first sample after boot.
  if PresetsStorage.pushSource ~= latch.pushSourceSeen then
    latch.pushSourceSeen = PresetsStorage.pushSource
    latch.pushLastHigh = high
    return
  end

  -- Only consume once THIS instance can send (the same gate pushToVtx
  -- applies): latching earlier would eat the rising edge for every instance
  -- while nobody could act on it.
  if not VTXAdmin.isReady() and not VTXAdmin.isSending() then
    return
  end

  local wasHigh = latch.pushLastHigh
  latch.pushLastHigh = high

  -- Edge detection: trigger only on rising edge (low -> high)
  if high and not wasHigh then
    VTXAdmin.pushToVtx()
  end
end

-- ============================================================================
-- VTXAdmin: state machine tick
-- ============================================================================

function VTXAdmin.tick()
  local now = getTime()

  -- A tick gap over a second means the widget was suspended — a standalone
  -- tool had the screen and may have changed the module config — so read the
  -- folder back once on resume. The bounded refresh slot retries a lost
  -- frame without ever polling: every push replaces one RC-channels frame
  -- on the handset->module UART, so the folder is only read when something
  -- can have changed it.
  if VTXAdmin.lastTick > 0 and now - VTXAdmin.lastTick > 100 and VTXAdmin.phase == VTXAdmin.PHASE_READY then
    session:refreshField(VTXAdmin.ids.folder, 0, 3)
  end
  VTXAdmin.lastTick = now

  if VTXAdmin.phase == VTXAdmin.PHASE_INIT then
    if crsf.hasCrsfModule() then
      VTXAdmin.phase = VTXAdmin.PHASE_DISCOVER_ROOT
      VTXAdmin.statusText = "Discovering..."
      session:reloadAll()
    else
      VTXAdmin.phase = VTXAdmin.PHASE_NO_MODULE
      VTXAdmin.statusText = "No CRSF module"
    end
  elseif VTXAdmin.phase == VTXAdmin.PHASE_SENDING and not session:isWriting() then
    print("VTXAdmin: write queue drained")
    VTXAdmin.phase = VTXAdmin.PHASE_READY
    -- Read the folder back ~100ms after the last write so the module has
    -- applied the change; the simulator defers folder-name updates ~20ms.
    session:refreshField(VTXAdmin.ids.folder, 10, 3)
  end

  session:tick()

  -- After the session pump, matching the write-queue timing the automation
  -- had as separate background() calls: writes it queues go out next tick.
  process6Pos()
  processPushTrigger()
end

-- ============================================================================
-- VTXAdmin: write queue builder
-- ============================================================================

--- Write changed config fields (band, channel, power, pitmode) to the ELRS module.
--- Does NOT send the "Send VTx" command — call pushToVtx() separately for that.
function VTXAdmin.writeConfig()
  if not VTXAdmin.isReady() then
    print("VTXAdmin: writeConfig() skipped - not ready")
    return
  end

  local s = VTXAdmin.state
  local d = VTXAdmin.desired

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

  local wrote = 0
  if d.band ~= s.band then
    session:writeField({ id = VTXAdmin.ids.band, value = d.band })
    wrote = wrote + 1
  end
  if d.channel ~= s.channel then
    session:writeField({ id = VTXAdmin.ids.channel, value = d.channel })
    wrote = wrote + 1
  end
  if d.power ~= s.power then
    session:writeField({ id = VTXAdmin.ids.power, value = d.power })
    wrote = wrote + 1
  end

  local desiredPit = d.pitmode
  local currentPit = s.pitmode and 1 or 0
  if desiredPit ~= currentPit then
    session:writeField({ id = VTXAdmin.ids.pitmode, value = desiredPit })
    wrote = wrote + 1
  end

  print(table.concat({ "VTXAdmin: writeConfig() wrote ", wrote, " field(s)" }))

  if wrote > 0 then
    VTXAdmin.phase = VTXAdmin.PHASE_SENDING
  end
end

--- Write a preset's band and channel on top of the module's current state.
--- Re-basing on state means a preset only ever writes band and channel:
--- desired can hold stale power/pitmode -- ExpressLRS omits both from the
--- folder name when power is "-", and nothing re-syncs after a send completes.
function VTXAdmin.applyPreset(band, channel)
  VTXAdmin.syncDesiredFromState()
  VTXAdmin.desired.band = band
  VTXAdmin.desired.channel = channel
  VTXAdmin.writeConfig()
end

--- Send the "Send VTx" command, pushing config to the VTX.
function VTXAdmin.pushToVtx()
  if not VTXAdmin.isReady() and VTXAdmin.phase ~= VTXAdmin.PHASE_SENDING then
    print("VTXAdmin: pushToVtx() skipped - not ready")
    return
  end

  print("VTXAdmin: pushToVtx() - sending Send VTx command")
  session:writeField({ id = VTXAdmin.ids.send, value = crsf.CONST.CMD_CLICK })
  VTXAdmin.phase = VTXAdmin.PHASE_SENDING
end

-- ============================================================================
-- Display components
-- ============================================================================

local VTXDisplay, WidgetLayout = loadScript("/WIDGETS/ELRSVTXAdmin/ui/display.lua")(VTXAdmin, PresetsStorage)
local FullScreenUI = loadScript("/WIDGETS/ELRSVTXAdmin/ui/fullscreen.lua")(VTXAdmin, PresetsStorage)

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
local uiPath = table.concat({ "/WIDGETS/ELRSVTXAdmin/ui/", screenId, ".lua" })
local WidgetUI = loadScript(uiPath)({
  VTXAdmin = VTXAdmin,
  bgOpacity = bgOpacity,
  VTXDisplay = VTXDisplay,
  WidgetLayout = WidgetLayout,
})

-- ============================================================================
-- Widget lifecycle
-- ============================================================================

local wgt = {
  zone = zone,
  options = options,
}

function wgt.background()
  session:drain()
  VTXAdmin.tick()
end

function wgt.refresh(_event, _touchState)
  wgt.background()
end

-- The full-screen page is built once, on entry. Everything it shows updates in
-- place from there: every value is a per-frame callback or a control that polls
-- its get() -- see the ui/fullscreen.lua header for the constraint that keeps
-- that true.
function wgt.update(newOptions)
  wgt.options = newOptions
  if lvgl.isFullScreen() then
    if VTXAdmin.isReady() then
      VTXAdmin.syncDesiredFromState()
    end
    FullScreenUI.build()
  else
    WidgetUI.build(wgt.zone, wgt.options)
  end
end

-- Initial build
WidgetUI.build(wgt.zone, wgt.options)

return wgt
