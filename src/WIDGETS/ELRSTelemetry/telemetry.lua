---------------------------------------------------------------------------
-- ELRS Telemetry State                                                  --
-- Loaded via loadScript() from ELRSTelemetry/main.lua with (crsf);      --
-- returns the Telemetry singleton.                                      --
--                                                                       --
-- Everything the widget knows about the link, in one owner: the frame   --
-- drain, the DEVICE_INFO cache and the RF mode tables it selects, the   --
-- model-match status and the rules for when it may be asked for, the    --
-- per-tick sensor snapshot, and every value derived from it.            --
--                                                                       --
-- All of that describes the radio's link, not a widget instance, so it  --
-- is loaded once per Lua state and shared by every instance. Three      --
-- things follow, and none of them are optional:                         --
--                                                                       --
-- 1. drain() runs per instance, every frame, ungated. Each widget       --
--    instance owns a private pop queue in the firmware, so skipping it  --
--    for the instances that did not sample this tick would leave those  --
--    queues to fill and overflow.                                       --
-- 2. update() samples once per tick however many instances call it.     --
--    Without that, the headroom smoother would step once per instance   --
--    per frame and settle N times faster on a screen with N widgets.    --
-- 3. The frame handlers stay pure assignment. Every instance is         --
--    delivered its own copy of each frame, so on a radio this singleton --
--    decodes the same frame N times; a counter here would be N times    --
--    wrong on hardware and right in the simulator.                      --
--                                                                       --
-- Per background tick: Telemetry.drain() to ingest the queue (which     --
-- also refreshes crsf.hasTelemetry as it empties), then                 --
-- Telemetry.update() to sample and pump the outgoing requests.          --
---------------------------------------------------------------------------

local crsf = ...

local RfModes = loadScript("/WIDGETS/ELRSTelemetry/rf_modes.lua")()

local Telemetry = {}

-- ============================================================================
-- State
-- ============================================================================

-- Sensor snapshot, refilled once per tick by update(). The table identity
-- never changes, so consumers may cache a reference.
Telemetry.link = {}

-- Smoothed signal headroom as a percentage of the current RF mode's usable
-- range, or nil while that range is unknown. Recomputed once per tick.
---@type number?
Telemetry.headroomPct = nil

-- Detected battery cell count, or nil while no plausible pack voltage has
-- been seen. Locks on once the same count survives a few readings.
---@type number?
Telemetry.cellCnt = nil

-- Last known GPS position. Deliberately survives a dropout -- it is what you
-- read when looking for a model that stopped answering -- so only a model
-- change clears it.
---@type {lat: number, lon: number}|nil
Telemetry.gps = nil

-- Model match comes from the ELRS_STATUS answers updateModelMatch() asks for.
-- The module recomputes the flag as it answers and never sends one unasked, so
-- the value is exactly as old as the last answer.
---@type boolean?
Telemetry.modelMismatch = nil

-- Model this state belongs to, so create() can tell a model change from a
-- second widget being placed on the model already loaded.
---@type string?
Telemetry.modelId = nil

-- Cell count detection working state.
---@type number?
Telemetry._cellCntCnt = nil
Telemetry._cellLastV = nil

-- Running smoother state for headroomPct.
---@type number?
Telemetry._smoothHead = nil

-- Device info cache (populated by the DEVICE_INFO handler): name, isElrs.
-- Neither is displayed: name is the "already answered" latch that stops the
-- ping, isElrs is the gate on rule 2 below.
Telemetry._device = {}

-- Device info polling
Telemetry._lastDevPoll = 0

-- ELRS status polling
Telemetry._lastStatusPoll = 0

-- Set once an ELRS_STATUS answer has arrived, so a match is asked about once
-- rather than polled. Cleared on any hasTelemetry edge in update(), and by
-- resetModelMatch() on widget create.
---@type boolean?
Telemetry._statusAnswered = nil

-- hasTelemetry as last seen by update(), to detect connection edges.
Telemetry._wasConnected = false

-- getTime() of the last sample, for the once-per-tick guard in update().
---@type number?
Telemetry._sampledAt = nil

-- ============================================================================
-- Queries
-- ============================================================================

--- Whether a CRSF/ELRS module is available at all.
function Telemetry.hasModule()
  return crsf.hasCrsfModule()
end

--- Whether the link is up, i.e. the receiver is answering.
function Telemetry.isConnected()
  return crsf.hasTelemetry
end

--- True when a connected link is reporting a model mismatch.
--- modelMismatch arrives in the same ELRS_STATUS frame as hasTelemetry, so it
--- only means anything while connected: ungated, a stale flag paints a label
--- RED under text reading "--".
function Telemetry.isMismatch()
  return crsf.hasTelemetry and Telemetry.modelMismatch
end

-- The link's state as one value, worst first. The view turns it into words in
-- one place and into a colour in another; both index this, so the status line
-- and the status LED cannot end up disagreeing about what the link is doing.
Telemetry.STATUS = {
  NO_MODULE = 1,
  NO_TELEMETRY = 2,
  MISMATCH = 3,
  OK = 4,
}

--- Where the link currently sits on the STATUS ladder.
function Telemetry.statusLevel()
  local STATUS = Telemetry.STATUS
  if not Telemetry.hasModule() then
    return STATUS.NO_MODULE
  end
  if not Telemetry.isConnected() then
    return STATUS.NO_TELEMETRY
  end
  if Telemetry.modelMismatch then
    return STATUS.MISMATCH
  end
  return STATUS.OK
end

--- RSSI of the antenna currently in use, or nil while unknown.
function Telemetry.activeRssi()
  local link = Telemetry.link
  return (link.ant == 1) and link.rssi2 or link.rssi1
end

--- dB the active antenna sits above the RF mode's rated sensitivity floor, or
--- nil while either end is unknown. This is the number the headroom bar draws
--- and the full-screen page prints: RSSI on its own says nothing until you
--- know what the receiver can still hear at.
function Telemetry.marginDb()
  local rssi = Telemetry.activeRssi()
  local sens = Telemetry.link.sens
  if rssi == nil or sens == nil then
    return nil
  end
  return rssi - sens
end

--- Whether the RX reports a second antenna.
--- An RX only writes uplink_RSSI_2 when it has two RF paths -- a dual-radio RX
--- fills it every packet, a switched-antenna RX once it first selects antenna 2.
--- A single-antenna RX never touches it, so it arrives as 0 dBm, impossible for
--- a real signal. Same test ExpressLRS uses on the TX module's own screens.
function Telemetry.hasDiversity()
  local rssi2 = Telemetry.link.rssi2
  return rssi2 ~= nil and rssi2 ~= 0
end

--- Packet-rate name for the current RF mode, e.g. "250Hz".
function Telemetry.rfModeName()
  local rfmd = Telemetry.link.rfmd
  if rfmd == nil then
    return nil
  end
  return RfModes.name(rfmd)
end

-- ============================================================================
-- Derived state
-- ============================================================================

--- Cell count detection heuristic.
local function checkCellCount(v)
  -- once the cell count is the same X times in a row, stop updating
  if (Telemetry._cellCntCnt or 0) > 5 then
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
    Telemetry._cellCntCnt = 0
  else
    -- The value has to change to count as an update
    if Telemetry._cellLastV == v then
      return
    end
    Telemetry._cellLastV = v
    Telemetry._cellCntCnt = Telemetry._cellCntCnt + 1
  end
end

-- Above this the receiver is saturated and more signal buys nothing, so it is
-- where the headroom scale tops out rather than the strongest RSSI seen.
-- Public because it is the headroom bar's right endpoint, and a layout file
-- printing its own -50 would be a second copy of the same decision.
Telemetry.RSSI_CEILING = -50
local RSSI_CEILING = Telemetry.RSSI_CEILING

--- Recompute the smoothed signal headroom from the snapshot.
-- 0% puts the active antenna exactly on the RF mode's rated floor and 100%
-- puts it at the ceiling, so the scale recalibrates with the packet rate: the
-- same -80 dBm is comfortable at 25Hz and marginal at F1000.
-- Unknown at either end means there is no scale to place RSSI on, and a bar
-- drawn against a guessed floor would be worse than no bar.
local function updateHeadroom()
  local rssi = Telemetry.activeRssi()
  local sens = Telemetry.link.sens
  if rssi == nil or sens == nil then
    Telemetry.headroomPct = nil
    Telemetry._smoothHead = nil
    return
  end
  if rssi > RSSI_CEILING then
    rssi = RSSI_CEILING
  elseif rssi < sens then
    -- The floor is a rating, not a wall: a receiver still reports RSSI below
    -- the figure it is rated to. Clamping keeps the percentage on scale.
    rssi = sens
  end
  local pct = math.floor(100 * (rssi - sens) / (RSSI_CEILING - sens) + 0.5)
  local smooth = Telemetry._smoothHead or pct
  if pct > smooth then
    pct = smooth + ((pct > smooth + 8) and 4 or 1)
  elseif pct < smooth then
    pct = smooth - ((pct < smooth - 8) and 4 or 1)
  end
  Telemetry._smoothHead = pct
  Telemetry.headroomPct = pct
end

--- Latch the last known GPS position, ignoring the "no fix" readings.
local function updateGps()
  local gps = crsf.getSensorValue("GPS")
  if gps and gps ~= 0 then
    Telemetry.gps = gps
  end
end

-- ============================================================================
-- Resets
-- ============================================================================

--- Clear the state that belongs to one connection, on the falling edge.
--- Cell count and headroom smoothing re-detect on the next battery instead of
--- latching forever. gps is deliberately kept.
local function resetConnection()
  Telemetry._smoothHead = nil
  Telemetry.headroomPct = nil
  Telemetry.cellCnt = nil
  Telemetry._cellCntCnt = nil
  Telemetry._cellLastV = nil
end

--- Forget the model-match verdict, so the next tick asks for a fresh one.
-- Cheap, idempotent and self-repairing, so create() may call it every time.
function Telemetry.resetModelMatch()
  Telemetry.modelMismatch = nil
  Telemetry._statusAnswered = nil
end

--- Forget everything that belongs to the model that was loaded before.
-- This singleton lives in the widget Lua state, which only a boot or a resume
-- from shutdown rebuilds, while widget instances are rebuilt on every model
-- change -- so without this the previous model's aircraft would be on screen:
-- its last GPS position in particular, indistinguishable from a live fix.
-- The device cache and the RF tables stay; the module did not change.
--
-- Clearing _sampledAt is load-bearing. create() runs per instance, so if a
-- sibling already sampled this tick, the update() that follows this reset
-- would be swallowed by the guard and paint a cleared snapshot for one frame.
function Telemetry.resetModel()
  resetConnection()
  Telemetry.resetModelMatch()
  Telemetry.gps = nil
  Telemetry._wasConnected = false
  Telemetry._sampledAt = nil
  crsf.resetSensorCache()
end

-- ============================================================================
-- Outgoing requests
-- ============================================================================

--- Ask the TX module for its DEVICE_INFO if it is not cached yet.
-- Addressed to the module itself, so it stays off the air. EdgeTX pings once
-- at module init, but that answer lands before any widget's Lua queue exists
-- (queues are created lazily on the first crossfireTelemetryPop), so widgets
-- must ask themselves. Rate-limited to at most once per second, permanently
-- quiet once answered.
local function requestDeviceInfo()
  if Telemetry._device.name then
    return
  end
  local now = getTime()
  if now - Telemetry._lastDevPoll < 100 then
    return
  end
  Telemetry._lastDevPoll = now
  crsf:pingDevices(crsf.CONST.ADDRESS_TX)
end

-- Weakest link a status request will be spent on (rule 4 below).
local MODEL_MATCH_MIN_RSSI = -70

--- Whether a status request is worth the frame it costs, right now.
-- requestElrsStatus() is answered locally by the module, but the push still
-- replaces one RC-channels frame on the handset->module UART, so every rule
-- below weighs one answer against one frame. All of them must hold.
local function canRequestStatus(now)
  -- 1. Connected. The module reports no model-match verdict without a link,
  --    and the answer would carry nothing to display.
  if not crsf.hasTelemetry then
    return false
  end
  -- 2. ExpressLRS. The fieldId=0 request is an ELRS convention; a TBS module
  --    answers device pings but never this, and would be asked forever.
  if not Telemetry._device.isElrs then
    return false
  end
  -- 3. No answer yet, or the last one was a mismatch. One answer settles a
  --    match, but the module recomputes the flag as it answers and announces
  --    nothing on its own, while every way out of a mismatch -- receiver
  --    number, model select, the tool's Model Match switch, a rebind -- is
  --    applied over a link the handset never sees drop. Latching there would
  --    pin the warning on screen for the rest of the session.
  if Telemetry._statusAnswered and not Telemetry.modelMismatch then
    return false
  end
  -- 4. Strong link. A mismatch is caught next to the quad; out at range every
  --    RC-channels frame is worth more than the answer is. Read from the
  --    snapshot this tick's sample already filled.
  local rssi = Telemetry.activeRssi()
  if rssi == nil or rssi <= MODEL_MATCH_MIN_RSSI then
    return false
  end
  -- 5. At most once per second, which is as fresh as an answer gets: the
  --    module latches its own packet counters on a 1 s watchdog.
  return now - Telemetry._lastStatusPoll >= 100
end

--- Keep modelMismatch current, one request per second at the very most.
local function updateModelMatch()
  local now = getTime()
  if not canRequestStatus(now) then
    return
  end
  Telemetry._lastStatusPoll = now
  crsf:requestElrsStatus()
end

-- ============================================================================
-- Per-tick pump
-- ============================================================================

-- getTime() ticks every 10 ms and the widget loop runs every 50 ms, so a
-- window of 3 ticks deduplicates the instances of one frame without ever
-- swallowing the next frame -- an equality test would miss an instance loop
-- that straddles a tick boundary.
local SAMPLE_INTERVAL = 3

--- Sample every sensor and recompute everything derived from them, once per
--- tick however many instances call this.
--- Call right after drain() so the tick's frames are ingested and
--- hasTelemetry is current. Any hasTelemetry edge wipes the per-connection
--- state before updateModelMatch() runs: a stale modelMismatch can neither
--- survive a disconnect nor suppress the next connection's status poll via a
--- late-arriving answer. hasTelemetry only refreshes as a drain empties the
--- queue, so a dying connection's ELRS_STATUS always lands before the edge is
--- observed here.
function Telemetry.update()
  local now = getTime()
  if now - (Telemetry._sampledAt or -SAMPLE_INTERVAL) < SAMPLE_INTERVAL then
    return
  end
  Telemetry._sampledAt = now

  local link = Telemetry.link
  link.tpwr = crsf.getSensorValue("TPWR")
  link.rfmd = crsf.getSensorValue("RFMD")
  link.rssi1 = crsf.getSensorValue("1RSS")
  link.rssi2 = crsf.getSensorValue("2RSS")
  link.rqly = crsf.getSensorValue("RQly")
  link.ant = crsf.getSensorValue("ANT")
  link.tqly = crsf.getSensorValue("TQly")
  link.trss = crsf.getSensorValue("TRSS")
  link.vbat = crsf.getSensorValue("RxBt")
  link.curr = crsf.getSensorValue("Curr")
  link.fm = crsf.getSensorValue("FM")
  link.sats = crsf.getSensorValue("Sats")
  link.gspd = crsf.getSensorValue("GSpd")
  link.alt = crsf.getSensorValue("Alt")
  -- Resolved here rather than at every read: the floor only moves when the
  -- packet rate does, and the view asks for it several times a frame.
  link.sens = link.rfmd and RfModes.floor(link.rfmd)

  local connected = crsf.hasTelemetry
  if connected ~= Telemetry._wasConnected then
    Telemetry._wasConnected = connected
    Telemetry.resetModelMatch()
    if not connected then
      resetConnection()
    end
  end

  if connected then
    updateGps()
    updateHeadroom()
    if link.vbat then
      checkCellCount(link.vbat)
    end
  end

  requestDeviceInfo()
  updateModelMatch()
end

-- ============================================================================
-- Frame handlers
-- ============================================================================

-- DEVICE_INFO handler: caches module identity and selects the RF tables
local function onDeviceInfo(data)
  local info = crsf:decodeDeviceInfo(data)
  if info == nil or info.id ~= crsf.CONST.ADDRESS_TX then
    return -- short frame (the ping retries) or not the TX module
  end
  Telemetry._device.name = info.name
  Telemetry._device.isElrs = info.isElrs
  RfModes.select(info.vMaj)
end

-- ELRS_STATUS handler: latches the answer and updates modelMismatch
local function onElrsStatus(data)
  local status = crsf:decodeElrsStatus(data)
  if status == nil or status.id ~= crsf.CONST.ADDRESS_TX then
    return
  end
  Telemetry._statusAnswered = true
  Telemetry.modelMismatch = status.modelMismatch
end

--- Route one frame into the state. Frames of other types are dropped: this
-- singleton is its widget's only queue consumer (pop is destructive per
-- instance), and the firmware delivers every instance its own copy of each
-- frame. Assignment only -- see invariant 3 in the header.
function Telemetry:_onFrame(command, data)
  if command == crsf.CONST.FRAMETYPE_DEVICE_INFO then
    onDeviceInfo(data)
  elseif command == crsf.CONST.FRAMETYPE_ELRS_STATUS then
    onElrsStatus(data)
  end
end

--- Drain the calling script instance's pop queue into the state.
function Telemetry.drain()
  crsf.drain(Telemetry, Telemetry._onFrame)
end

-- ============================================================================
-- Return singleton
-- ============================================================================

return Telemetry
