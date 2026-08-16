# Development

This document covers the internal architecture of the ExpressLRS tools and the CRSF simulator used for testing inside the EdgeTX simulator without real hardware.

## Make targets

Run `make help` to list all targets. The Makefile groups them into three categories:

### Setup

| Target | Purpose |
|--------|---------|
| `install-tools` | Install both `stylua` and `lua-language-server` |
| `install-stylua` | Install [stylua](https://github.com/JohnnyMorganz/StyLua) via `cargo` (requires Rust toolchain). Built with the `lua53` feature for EdgeTX compatibility. |
| `install-luals` | Download [lua-language-server](https://github.com/LuaLS/lua-language-server) `3.17.1` to `bin/lua-language-server/` |

### Quality checks

| Target | Purpose |
|--------|---------|
| `format` | Format all Lua sources in `src/` with `stylua` (config: `.stylua.toml`) |
| `format-check` | Verify formatting without modifying files. Used in CI. |
| `typecheck` | Run `lua-language-server --check .` against the project (config: `.luarc.json`) |
| `check` | Convenience target: runs `format-check` then `typecheck` |

### Deployment

| Target | Purpose |
|--------|---------|
| `sync` | Copy sources to the EdgeTX simulator SD card at `../edgetx-sdcard` via `edgetx-cli dev sync`. Includes dev-only libraries like the CRSF simulator. |
| `push` | Install the package to a connected EdgeTX radio via `edgetx-cli pkg install . --eject`. Excludes dev-only libraries. |

## Architecture

The configuration tool, `SCRIPTS/TOOLS/ExpressLRS/`:

| Module | Purpose |
|--------|---------|
| `main.lua` | Entry point, run-loop orchestrator, and the App policy layer (device switching, folder-ready edges, the synthetic "Other Devices" row types) over a `crsf_session.lua` instance |
| `navigation.lua` | Folder and device navigation stack |
| `ui/lvgl.lua` | Color LCD interface (LVGL dialogs, command pages, warnings) |
| `ui/lcd.lua` | BW LCD interface (text cursor, popups) |

The bind phrase manager, `SCRIPTS/TOOLS/ExpressLRSBind/` (sets the bind phrase / UID over MSP;
the device side requires ExpressLRS 4.1+, and a pre-4.1 device simply never answers -- the tool's
bounded UID retry reports that instead of polling forever):

| Module | Purpose |
|--------|---------|
| `main.lua` | Entry point and the App layer: target selection (TX/RX/Both), phrase-vs-raw-UID parsing, the two-step Both sequence (RX first -- writing its phrase drops it off the link -- then TX), the bounded UID read retry, and the frame router over `crsf.drain` |
| `history_storage.lua` | The last five phrases, newest first, persisted through `file_storage.lua` as indexed keys `h1`..`h5` |
| `ui/lvgl.lua` | Color LCD interface |
| `ui/lcd.lua` | BW LCD interface (line list, phrase editing through `ui/lcd/text_edit.lua`) |

Both tools pick their UI chunk at runtime -- `local useLvgl = (lvgl ~= nil)` -- and load exactly one
of `ui/lvgl.lua` or `ui/lcd.lua`; there are no per-radio builds.

The tools build on the shared `SCRIPTS/ELRS/` library, which the widgets use too:

| Module | Purpose |
|--------|---------|
| `SCRIPTS/ELRS/crsf.lua` | CRSF constants, telemetry transport (`pop`/`drain`/`push`), module detection, derived link state (`hasTelemetry`, refreshed as a drain empties the queue), stateless frame decoders (`decodeDeviceInfo`, `decodeElrsStatus`, `isElrsV1Frame`) |
| `SCRIPTS/ELRS/crsf_params.lua` | Opt-in parameter codec: `PARAMETER_SETTINGS_ENTRY` chunk reassembly over a caller-owned rx table and per-type decode, plus encoders that return `PARAMETER_READ`/`WRITE`, command-step and suppress-critical-errors frames for the caller to push. Loaded by the tool and the VTX Admin widget |
| `SCRIPTS/ELRS/crsf_session.lua` | Opt-in stateful parameter client (`CRSFSession.new`, multi-instance): field store, load queue and retry scheduler, paced write queue, command state machine, and optional device discovery, link status and ELRS 1.x detection. Loaded by the tool and the VTX Admin widget |
| `SCRIPTS/ELRS/msp.lua` | Opt-in MSP-over-CRSF codec: stateless encoders returning `(frameType, payload)` for `MSP_REQ`/`MSP_WRITE` and decoders for single-frame v1 `MSP_RESP`, plus the ELRS `RXTX_CONFIG` UID/phrase helpers. Loaded only by the bind tool |
| `SCRIPTS/ELRS/defer.lua` | Single-slot `setTimeout`/`poll` timer; scheduling replaces the pending callback, which is what cancels a stale retry when a new action starts. Loaded only by the bind tool |
| `SCRIPTS/ELRS/ui/lcd/text_edit.lua` | BW text editor replicating the firmware's `editName()` model-name semantics (rotary cycles the char, ENTER advances, long ENTER toggles case or commits on a space). Loaded only by the bind tool's BW UI. `ui/<display>/` is the library's home for shared UI components, mirroring the tools' own `ui/` split |
| `SCRIPTS/ELRS/ui/lcd/alert.lua` | BW full-screen alert (MIDSIZE title, body lines, optional bottom action labels). Loaded by both tools' BW UIs |
| `SCRIPTS/ELRS/ui/lvgl/dialogs.lua` | The color-LCD startup dialogs a tool can raise before it has a page -- the version gate and the missing-module notice. Both are terminal, so each takes the caller's `onExit` for the close box and the Exit button. Loaded by both tools' LVGL UIs |
| `SCRIPTS/ELRS/loader.lua` | The tools' GC-guarded script loader: a full collection before each `loadScript` keeps fresh-install compile peaks from stacking. The one part consumers bootstrap with a bare `loadScript` |
| `SCRIPTS/ELRS/edgetx_version.lua` | The one home of the minimum EdgeTX requirement (2.11.6 / 2.12.1 / 3.0). Each tool's `main.lua` checks it once and hands `deps.versionOk` to its UI chunk, whose `preCheck` owns the presentation. Keep `min_edgetx_version` in `edgetx.yml` in step |
| `SCRIPTS/ELRS/sensors.lua` | Generic EdgeTX telemetry reader (`getSensorValue` with a cached name-to-ID lookup), not CRSF-specific. Loaded by `crsf.lua`, which exposes it to every consumer as `crsf.getSensorValue`. A cached ID addresses a slot in the model that was loaded when it was resolved, so a consumer that survives a model change must call `crsf.resetSensorCache()` on that edge |
| `SCRIPTS/ELRS/file_storage.lua` | Generic key=value file persistence (`read`/`write`), schema-free. Loaded by the VTX Admin widget and the bind tool |
| `SCRIPTS/ELRS/shim.lua` | `table.concat` polyfill for BW radios |

Frames are consumed pull-style. `crossfireTelemetryPop()` is destructive per script instance, and
the firmware delivers every widget instance its own copy of each incoming frame, so **each script
instance has exactly one draining consumer**: the config tool and the VTX Admin widget drain through
`session:drain()`, the telemetry widget through `Telemetry.drain()`, and the bind tool through
`crsf.drain(App, App.onFrame)`. A future widget needing two consumers must pop once and route the
frames itself. `reassemble()` callers pass the field id they
are waiting for (strict), or `data[3]` to accept any field from their device (`acceptUnsolicited`,
used by VTX Admin so sibling instances stay in sync from each other's answers).

Nothing in `crsf.lua` or `crsf_params.lua` mutates a frame's data table, with one deliberate
exception: the link-layer `readString` in `crsf.lua` converts bytes to chars in place, which is safe
because each frame type has exactly one string-decoding consumer. The codec stays read-only because
`reassemble()`'s single-frame fast path hands the caller's frame back as the decode buffer.

## CRSF Simulator

The `src/SCRIPTS/CRSFSimulator/` library provides a CRSF protocol simulator for development and testing without real hardware. It is declared as a dev-only library in `edgetx.yml` (`dev: true`), so it is included by `edgetx-cli dev sync` but skipped by `edgetx-cli pkg install`.

**Files:** `src/SCRIPTS/CRSFSimulator/csrfsimulator.lua` (the mock), `src/SCRIPTS/CRSFSimulator/shim.lua` (its `table.concat`/`table.remove`/`charsToString` helpers)

The simulator provides a packet-level mock of `crossfireTelemetryPop` and `crossfireTelemetryPush`, allowing the ELRS tool to exercise the full communication flow (device discovery, parameter loading, value writes, ELRS status) inside the EdgeTX simulator. Multiple scenarios are available to simulate different states such as normal operation, disconnected links, model mismatch, and more.

Delivery mirrors the firmware's per-widget queue replication: frames append to a shared log and every consumer (the identity passed to `pop()`) advances its own cursor over it, receiving its own copy of each frame. Several widgets can therefore drain "their" queues concurrently against the one mock, just as they do against the firmware's real per-instance queues.

### How it works

When running in the EdgeTX simulator (version string ends with `-simu`), `SCRIPTS/ELRS/crsf.lua` automatically loads the simulator module from `/SCRIPTS/CRSFSimulator/csrfsimulator.lua` at load time and patches its `pop`, `push`, `getSensorValue` and `hasCrsfModule` functions with the mock implementations. The tool and the widgets both talk to CRSF through that library, so the one mock instance covers all of them.

Run `make sync` (which runs `edgetx-cli dev sync`) to copy the sources -- including the dev-only `CRSFSimulator` library -- onto the simulator SD card. `edgetx-cli pkg install` omits the library automatically, so the simulator is never shipped to real hardware.

### Scenarios

The simulator supports multiple test scenarios, configurable via the `config.scenario` variable at the top of the file:

| Scenario | Description |
|----------|-------------|
| `normal` | TX + RX connected. Happy path with full telemetry and all parameters. `ANT` alternates between 1 and 0 every ~5 seconds so both antenna branches render. |
| `no_telemetry` | TX present but no RX telemetry. Shows "No telemetry" state. |
| `reconnect` | Starts disconnected, transitions to connected after ~5 seconds. |
| `model_mismatch` | TX + RX connected with Model ID mismatch flag. Triggers warning dialog. |
| `armed` | TX + RX connected with "is Armed" warning flag. `ANT` is pinned to 0. |
| `single_antenna` | TX + RX connected on a receiver with one RF path. `2RSS` is pinned to 0, so the telemetry widget reports no diversity. |
| `slow_loading` | Parameter reads delayed by ~2 seconds each. Tests loading UI states. |
| `no_module` | No CRSF module found. Triggers "No Module Found" error dialog. |
| `critical_error` | TX + RX connected with a critical baud-rate error flag. Triggers the warning screen; the suppress write clears it. |

### MSP bind traffic

The mock answers the bind tool's MSP `RXTX_CONFIG` traffic: a UID read (`MSP_REQ`) is served from a
per-device `mspUid` table -- the TX and RX deliberately start with different UIDs so a fresh `normal`
run shows a mismatch that setting both to one phrase visibly fixes -- and a phrase write
(`MSP_WRITE`) rederives the target's UID through a deterministic pseudo-hash, so equal phrases give
equal UIDs (the property the Both flow demonstrates; the bytes need not match the firmware's MD5).
The RX answers only while the scenario keeps it reachable, which is what exercises the tool's
bounded retry, and writes are unacknowledged just like the real firmware. `FRAMETYPE_COMMAND`
bind/unbind requests are log-only.

`config.maxPacketBytes` (default 64, `CRSF_MAX_PACKET_LEN`) is the largest frame the mock handset
link carries. Parameter entries longer than `maxPacketBytes - 8` are chunked exactly as
`CRSFEndpoint::sendParameter` does, so lowering it -- real firmware shrinks it on slow baud rates in
`CRSFHandset::adjustMaxPacketSize` -- exercises chunk reassembly and the follow-up reads.
