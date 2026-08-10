# ExpressLRS Lua Scripts

Lua configuration tool for ExpressLRS on EdgeTX radios. Works on both black & white LCD and color LCD radios.

The package also includes two color-LCD widgets: the **ELRS Telemetry Widget** and the **VTX Administrator Widget**.

## Features

- Configure packet rate, telemetry ratio, switch mode, model match, antenna mode, TX power, WiFi connectivity, and more
- Compatible with **ExpressLRS v3.5.4+**

## Installation

Copy the contents of the `src/` directory to the **root** of your radio's SD card, preserving the directory structure. Delete any old ELRS scripts (`ELRS.lua`, `elrsV2.lua`, `elrsV3.lua`, `expresslrs.lua` and their `.luac` counterparts) from `SCRIPTS/TOOLS/`.

When done, your SD card should contain:

```
SCRIPTS/
  ELRS/
    crsf.lua                  -- shared CRSF protocol library
    shim.lua                  -- BW compatibility shim
  TOOLS/
    ExpressLRS/
      main.lua                -- entry point
      protocol.lua            -- CRSF protocol handling
      navigation.lua          -- folder navigation
      ui/
        lvgl.lua              -- color LCD UI (LVGL)
        lcd.lua               -- black & white LCD UI
WIDGETS/
  ELRSTelemetry/
    main.lua
    loadable.lua
    ui/
      ...
  ELRSVTXAdmin/
    main.lua
    loadable.lua
    presets.txt
    ui/
      ...
```

The shared library `SCRIPTS/ELRS/` is required by the configuration tool and both widgets.

### Install with edgetx-cli

You can also install this package using [edgetx-cli](https://github.com/jurgelenas/edgetx-cli):

```sh
edgetx-cli pkg install ExpressLRS/Lua-Scripts
```

Use the `--eject` flag to automatically unmount the SD card after installation.

## ExpressLRS Configuration Tool

The main tool (`SCRIPTS/TOOLS/ExpressLRS/`) lets you configure your ExpressLRS transmitter and receiver settings directly from your radio.

<img src="screenshots/tool_main_bw.png" width="256" alt="ExpressLRS Configuration Tool"><br/>

<img src="screenshots/tool_main.png" width="472" alt="ExpressLRS Configuration Tool">

## Widgets

Both widgets running side-by-side on the home screen:

<img src="screenshots/widgets.png" width="472" alt="ELRS Widgets">

## ELRS Telemetry Widget

The telemetry widget (`WIDGETS/ELRSTelemetry/`) displays real-time link statistics on your home screen: link quality, RSSI, range, RF mode, TX power, battery voltage, current, GPS, and flight mode. It supports multiple screen resolutions (800x480, 480x320, 480x272, 320x480, 320x240).

<img src="screenshots/widget_telemetry_fullscren.png" width="472" alt="ELRS Telemetry Widget">

## VTX Administrator Widget

The VTX Administrator widget (`WIDGETS/ELRSVTXAdmin/`) provides control over your video transmitter settings -- band, channel, power level, and pit mode -- directly from your radio telemetry screen. It also supports 6POS quick change for rapid VTX channel switching via a 6POS switch.

<img src="screenshots/widget_vtxadmin_fullscreen.png" width="472" alt="VTX Administrator Widget">

## Development

See [docs/development.md](docs/development.md) for the tool's internal architecture and the CRSF simulator used for testing inside the EdgeTX simulator.

## Compatibility

| Radio type | Firmware | ExpressLRS |
|------------|----------|------------|
| Black & white LCD | EdgeTX 2.11.6+, 2.12.1+, or 3.0+ | v3.5.4+ |
| Color LCD | EdgeTX 2.11.6+, 2.12.1+, or 3.0+ | v3.5.4+ |
