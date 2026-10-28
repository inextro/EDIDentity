# EDIDentity

Two identical monitors on a Mac keep swapping places? EDIDentity gives one of them its own identity.

## The problem

macOS remembers display arrangement by each monitor's EDID: vendor, model, and a **numeric serial number**. Some monitors ship with the same numeric serial in every unit (the real, unique serial is only in the alphanumeric field). With two of them, macOS cannot tell which is which, so every time you dock, the left and right screens may come up swapped.

Swapping them back with a tool like `displayplacer` fixes the picture but changes which display is main, and Spaces gets confused: desktops end up assigned to the wrong display, and Mission Control stops accepting clicks on one screen.

## How it works

EDIDentity reads each external display's EDID, finds the target by its alphanumeric serial, and applies a copy of that EDID with a different numeric serial (checksum fixed). macOS then sees two distinct monitors and remembers their positions itself, so nothing ever needs swapping.

The override uses `IOAVServiceSetVirtualEDIDMode`, a private IOKit function on Apple Silicon. It is **volatile**: nothing is written to the monitor, and the factory EDID comes back on reconnect, sleep and reboot. `edidentity watch` runs as a LaunchAgent and re-applies the override whenever that happens. It waits until the display configuration has been quiet for a few seconds, because changing a display's identity while macOS is still waking up can leave it without a Space (windows show, but no wallpaper or menu bar). If that still happens, `watch` notices, restores the factory EDID and applies the override again.

## Requirements

- Apple Silicon Mac (tested on M4, macOS 27)
- Xcode Command Line Tools (`swiftc`)

## Install

```sh
swiftc -O Sources/main.swift -o build/edidentity
./build/edidentity list
```

```
macOS serials: [877350490, 877350490]
S27R35A  alphanumeric=H4UR202005  serial=877350490
S27R35A  alphanumeric=H4UR201985  serial=877350490
```

Pick one of the two alphanumeric serials and install:

```sh
./scripts/install.sh H4UR201985
```

This installs `~/.local/bin/edidentity` and a LaunchAgent (`com.inextro.edidentity`) that starts at login. The display flickers once and macOS detects it as a new monitor; arrange your displays once in System Settings → Displays and macOS keeps that arrangement from then on.

By default the new numeric serial is derived from the alphanumeric one. Pass a second argument to choose it yourself: `./scripts/install.sh H4UR201985 201985`.

### Keeping the order after reboot

Even with the override, macOS can bring the monitors up swapped after a reboot: it arranges the displays before the LaunchAgent has applied the override, and keeps that arrangement afterwards. Pass `--order` with the alphanumeric serials from left to right, and `watch` moves them back whenever they come up in another order:

```sh
./scripts/install.sh H4UR201985 201985 --order H4UR202005,H4UR201985
```

This moves displays, so whichever lands in the main slot becomes main, and Mission Control may show a stray desktop on the other display. Remove it in Mission Control (hover it and click ×). Because `watch` enforces the order, it also undoes any other left-to-right order you set in System Settings; reinstall without `--order` to stop that.

## Commands

| Command | |
|---|---|
| `edidentity list` | external displays with their EDID serials |
| `edidentity apply --target <serial> [--serial <n>]` | apply the override once |
| `edidentity reset --target <serial>` | restore the factory EDID |
| `edidentity arrange --order <serial>,<serial>` | place the displays left to right in that order, once |
| `edidentity watch --target <serial> [--serial <n>] [--order <serials>]` | keep running and re-apply on reconnect; with `--order`, also keep that order |

Log: `~/Library/Logs/edidentity.log`

## Uninstall

```sh
edidentity reset --target H4UR201985   # optional, reconnecting also restores it
./scripts/uninstall.sh
```

## Caveats

- Private API: a macOS update may change or remove it.
- `watch` applies at most 3 times in 2 minutes, so a display that rejects the override cannot flicker in a loop. Rearranging has the same limit.
- Each re-apply looks like a reconnect to macOS, so the target display gets a fresh Space after wake. Windows that were on it may move to the other display.
- `edidentity list` also reports displays that have no Space.
- Only the numeric serial changes. Modes, resolution and color are untouched.

## License

MIT
