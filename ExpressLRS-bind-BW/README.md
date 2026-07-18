# ExpressLRS-bind — Color & Black-and-White EdgeTX

[![EdgeTX](https://img.shields.io/badge/EdgeTX-2.11%2B-2563eb?logo=lua&logoColor=white)](https://edgetx.org/)
[![ExpressLRS](https://img.shields.io/badge/ExpressLRS-4.1%2B-0ea5e9)](https://www.expresslrs.org/)
[![Displays](https://img.shields.io/badge/display-LVGL%20%7C%20B%26W-111827)](#compatibility)
[![Language](https://img.shields.io/badge/Lua-5.2-2c2d72?logo=lua&logoColor=white)](https://www.lua.org/)

Set or switch an ExpressLRS binding phrase directly from an EdgeTX handset — including radios with a monochrome display and no `lvgl` API.

This port keeps the original color-screen LVGL interface intact and automatically falls back to a classic `lcd` interface on black-and-white radios.

> [!IMPORTANT]
> This is a community compatibility port, not an official ExpressLRS release. Bench-test it on your exact radio and module before relying on it in the field.

## Highlights

- One Lua tool for **color LVGL** and **black-and-white LCD** radios.
- Set the binding phrase on a **transmitter module** or a connected **receiver**.
- Request and display the current six-byte UID.
- Send a bind command to a receiver in bind mode.
- Unbind a connected receiver.
- Store up to **five binding-phrase presets**.
- Select saved phrases instead of entering them again.
- Edit text character-by-character with the radio encoder, using the familiar EdgeTX workflow.
- Compatibility shims for B&W radios that do not provide the full Lua `table` library.

## Compatibility

| Component | Target |
|---|---|
| ExpressLRS | 4.1.0 or newer; the handset bindphrase command was introduced with ExpressLRS 4.1 |
| EdgeTX | Designed around the 2.11+ Lua APIs; 2.11.6+ or 2.12.1+ is recommended |
| Color radios | Uses the original `lvgl` interface when `lvgl` is available |
| B&W radios | Uses `lcd`, virtual key events and the rotary encoder |
| Display sizes | Layouts account for common 128×64, 212×64 and 212×96-style monochrome screens |

Hardware and firmware combinations vary. The B&W path has been syntax-checked and exercised in a mocked EdgeTX environment, but it has not been validated on every physical handset.

## Installation

1. Back up the existing versions of these files on the radio SD card.
2. Copy the included `SCRIPTS` directory to the root of the SD card and allow the folders to merge.
3. Confirm the final paths:

```text
/SCRIPTS/TOOLS/ExpressLRS-bind.lua
/SCRIPTS/ELRS/crsf.lua
/SCRIPTS/ELRS/shim.lua
```

> [!NOTE]
> Remove or rename the old `/SCRIPTS/TOOLS/elrs-bind.lua` after installing. Keeping both files may create duplicate entries in the Tools menu and make it easy to launch the old version accidentally. Existing presets are preserved because the history file remains `/SCRIPTS/ELRS/elrs-bind.txt`.

4. Enable the internal or external module using the CRSF protocol.
5. Open the EdgeTX **Tools** menu and run **ExpressLRS-bind**.

Only the files above are required. The `WIDGETS` directory is not used by this tool.

## Black-and-white controls

### Menu

| Control | Action |
|---|---|
| Rotate encoder / `NEXT` / `PREV` | Move through menu items |
| `ENT` | Open or execute the selected item |
| `RTN` | Exit the tool or return from a subpage |

### Binding-phrase editor

1. Rotate the encoder to select a character position.
2. Press `ENT` to edit that position.
3. Rotate the encoder to choose a character.
4. Press `ENT` to accept it and move forward.
5. Select `DELETE` to remove the current character.
6. Press `RTN` while changing a character to leave character-edit mode.
7. Press `RTN` again to accept the edited text and return to the menu.
8. On radios that expose a long-return event, hold `RTN` to cancel the whole edit and restore the original phrase.

Editing only changes the phrase currently held by the tool. Use **Save preset** to store it without transmitting, or **Set phrase** to send it and add it to history.

## Menu actions

| Item | Description |
|---|---|
| **Target** | Switch between the TX module and receiver |
| **Phrase** | Open the encoder-driven text editor |
| **Set phrase** | Send the current phrase to the selected target and save it in history |
| **Save preset** | Save the current phrase without sending it |
| **Saved phrases** | Load one of the five most recently used phrases |
| **Request UID** | Read the current UID from the selected target |
| **Send bind command** | Ask the TX module to bind a receiver currently in bind mode |
| **Unbind receiver** | Disconnect a connected receiver from its current binding |
| **Status** | Show the most recent operation result or UID |

## Preset storage

The tool stores up to five unique phrases, newest first, in:

```text
/SCRIPTS/ELRS/elrs-bind.txt
```

The history filename intentionally remains `elrs-bind.txt` so existing presets survive the tool rename. For compatibility with the original script, the tool can also fall back to the legacy relative path `elrs-bind.txt` when the preferred file cannot be opened.

Saving a phrase that already exists moves it to the top instead of creating a duplicate.

## Package layout

```text
README.md
SCRIPTS/
├── ELRS/
│   ├── crsf.lua
│   └── shim.lua
└── TOOLS/
    └── ExpressLRS-bind.lua
```

`crsf.lua` contains a small compatibility adjustment so radios missing `table.concat` or `table.remove` can use the equivalents supplied by `shim.lua`.

## Upstream background

The bindphrase-from-handset functionality was released with ExpressLRS 4.1.0. The original LVGL utility was developed by **CapnBry**. This port adds a monochrome UI while retaining the original LVGL path and CRSF/MSP behavior. The EdgeTX tool and script file are named **ExpressLRS-bind**.

<details>

### ExpressLRS 4.1.0 release highlight

[ExpressLRS 4.1.0 bindphrase release highlight](https://github.com/expresslrs/expresslrs/releases)

### Original LVGL bindphrase tool pull request

[Original LVGL bindphrase tool pull request](https://github.com/ExpressLRS/Lua-Scripts/pull/10)

</details>

## Attribution

- **Original LVGL bindphrase tool:** CapnBry
- **ExpressLRS and protocol implementation:** ExpressLRS contributors
- **EdgeTX Lua APIs:** EdgeTX contributors
- **Black-and-white compatibility port:** prepared with ChatGPT (OpenAI) from the supplied project sources

The compatibility port does not replace or remove upstream authorship. Keep all original copyright and licensing notices when redistributing modified files.

## Troubleshooting

### The script still says LVGL is required

The radio is probably loading an older copy of `elrs-bind.lua` or `ExpressLRS-bind.lua`. Verify that the modified file is located at exactly:

```text
/SCRIPTS/TOOLS/ExpressLRS-bind.lua
```

Power-cycle the radio after replacing files.

### The tool opens but actions are unavailable

Check that a CRSF/ExpressLRS module is enabled in the current EdgeTX model. Receiver actions additionally require telemetry from a connected receiver.

### A phrase can be edited but not sent to the receiver

Select **Receiver** as the target and make sure the receiver is connected. When no receiver is connected, use **Send bind command** with the receiver already in bind mode.

### Presets do not survive a restart

Confirm that the SD card is writable and that `/SCRIPTS/ELRS/` exists. Check for `elrs-bind.txt` in that directory.

### UID remains on “Updating…”

Verify CRSF telemetry, the selected target and ExpressLRS firmware compatibility. The tool retries UID requests until a valid response is received or another action clears the pending request.

## Responsible testing

Before flying, verify that the expected receiver responds, confirm the UID where practical, and perform the usual range and failsafe checks. Test binding operations on the bench with propellers removed.
