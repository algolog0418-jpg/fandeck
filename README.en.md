# FanDeck

By **ALGOLOG**.

A free, open-source fan control and temperature monitor for Apple Silicon Macs.
Built as an alternative to Macs Fan Control / TG Pro, with Activity-Monitor-style
CPU, memory and process views in the same app.

> **Verified on:** M4 Mac mini (Mac16,10), macOS 27.
> Other Macs should work but sensor naming is only confirmed on that model — see
> [Hardware support](#hardware-support).

## Features

| | |
|---|---|
| **Sensors** | Every SMC sensor the Mac exposes (322 on M4 Mac mini), grouped, searchable, with favorites |
| **Fan control** | System auto, fixed RPM, or a **multi-point curve you drag** (most tools only offer a two-point ramp) |
| **Smoothing** | Temperature EMA, hysteresis, and separate ramp-up/ramp-down limits so fan noise doesn't oscillate |
| **Activity** | CPU usage (user/system), memory (used, wired, compressed, pressure), process list with kill |
| **History** | Temperature/RPM/power time series kept by a background helper — survives app restarts. CSV export |
| **Profiles** | Named modes with automatic switching when a given app runs or a sensor crosses a threshold |
| **Safety** | Configurable critical temperature forces fans to maximum regardless of mode |
| **Power** | Reads SMC power rails (system total watts, package power) |
| **CLI** | `fandeck status`, `fandeck set 1800`, `fandeck watch`, `fandeck export out.csv` |
| **Languages** | Korean, English, Japanese, Simplified Chinese — switchable without restart |

## Install

Download the [latest release](https://github.com/algolog0418-jpg/fandeck/releases/latest),
unzip, and move **FanDeck.app** to Applications. Builds are signed ad-hoc, so run once:

```sh
xattr -dr com.apple.quarantine /Applications/FanDeck.app
```

Or build from source, which avoids the quarantine. No Xcode required — only Apple's
Command Line Tools.

```sh
git clone https://github.com/USER/fandeck.git
cd fandeck
Scripts/build.sh
open build/FanDeck.app
```

On first launch the app asks for your administrator password once, then fan control is on.
macOS requires root to write fan registers over SMC; this is the same mechanism commercial
tools use. **Declining still leaves all temperature, CPU and memory monitoring fully working** —
only fan speed changes are unavailable.

### Gatekeeper

Builds are signed ad-hoc, so a copy downloaded from the internet will be quarantined.
Building from source (above) avoids this. If you download a release instead:

```sh
xattr -dr com.apple.quarantine /Applications/FanDeck.app
```

## Understanding the temperature numbers

Apple Silicon exposes **two to three sensors per core**. For performance core 1:

| Key | Meaning | Typical |
|---|---|---|
| `Tp00` | Vicinity — cooler area around the core | 39.5 °C |
| `Tp01` | **Core die** — what other fan tools label "CPU Performance Core 1" | 48.3 °C |
| `Tp02` | Hotspot — hottest point in that core region | 59.6 °C |

FanDeck reports the **core die** as the core temperature, so its numbers match other tools.
Hotspots are listed separately as "… Hotspot", and the synthetic `CPU Hotspot` sensor is
available as a source for thermal protection, where the worst case is the safer input.

Every sensor row shows its raw SMC key, so you can always verify what you are looking at.

## Hardware support

The clustering of core sensors (`Tp00`/`Tp01`/`Tp02` → performance core 1, etc.) was derived
by measurement on an M4 Mac mini. On other Macs:

- Keys that don't exist are skipped — nothing breaks, those groups are simply empty.
- Unrecognized sensors still appear under "Other" with their raw key and value.
- Fan count comes from the SMC (`FNum`), so multi-fan MacBooks are handled.
- Intel Macs use different keys and the `fpe2` fixed-point format; the SMC layer supports it,
  but naming is untested.

**Reports from other models are very welcome** — run `fandeck sensors` and open an issue with
the output plus your `sysctl -n hw.model`.

## Architecture

```
Sources/FanDeckCore   SMC access (C + Swift), sensor catalog, curve engine, system monitor, IPC
Sources/FanDeck       SwiftUI app (window) + AppKit status item
Sources/fandeckd      Background helper running as root: applies curves, records history
Sources/fandeck-cli   Command line interface
```

Writing to the SMC requires root, so a small LaunchDaemon owns fan control and the app talks
to it over a Unix socket (`/var/run/fandeck.sock`, mode 0660, group `admin`). This means curves
keep working when the app is closed and before you log in. **When the helper stops or is
removed it always hands fan control back to macOS** — fans are never left pinned.

Sensor reads need no privileges, so the app reads the SMC directly for display.

## Safety

See [SAFETY.md](SAFETY.md). Short version: thermal protection is on by default, don't turn it
off, and don't pin fans to minimum while running sustained heavy workloads.

**This software comes with no warranty. Use at your own risk.**

## Author

**ALGOLOG** — https://github.com/algolog0418-jpg

## License

MIT © 2026 ALGOLOG — see [LICENSE](LICENSE).
