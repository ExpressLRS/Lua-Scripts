# Development

This document covers the internal architecture of the ExpressLRS configuration tool and the CRSF simulator used for testing inside the EdgeTX simulator without real hardware.

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

| Module | Purpose |
|--------|---------|
| `main.lua` | Entry point and run-loop orchestrator |
| `protocol.lua` | CRSF frame parsing, device discovery, parameter read/write |
| `navigation.lua` | Folder and device navigation stack |
| `shim.lua` | Polyfills for BW radios missing standard Lua functions |
| `ui/lvgl.lua` | Color LCD interface (LVGL dialogs, command pages, warnings) |
| `ui/lcd.lua` | BW LCD interface (text cursor, popups) |

## CRSF Simulator

The `src/SCRIPTS/CRSFSimulator/` library provides a CRSF protocol simulator for development and testing without real hardware. It is declared as a dev-only library in `edgetx.yml` (`dev: true`), so it is included by `edgetx-cli dev sync` but skipped by `edgetx-cli pkg install`.

**File:** `src/SCRIPTS/CRSFSimulator/csrfsimulator.lua`

The simulator provides a packet-level mock of `crossfireTelemetryPop` and `crossfireTelemetryPush`, allowing the ELRS tool to exercise the full communication flow (device discovery, parameter loading, value writes, ELRS status) inside the EdgeTX simulator. Multiple scenarios are available to simulate different states such as normal operation, disconnected links, model mismatch, and more.

### How it works

When the tool detects it is running in the EdgeTX simulator (version string ends with `-simu`), `main.lua` automatically loads the simulator module from `/SCRIPTS/CRSFSimulator/csrfsimulator.lua` and patches the protocol's `pop`, `push`, and `hasCrsfModule` functions with the mock implementations.

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
