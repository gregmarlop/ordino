# Ordino

A lightweight macOS menu bar system monitor.

## Why This Exists

Most system monitors are either resource hogs themselves or require complex installations. Ordino is different—it's a single Swift file that compiles to a native macOS app, using minimal resources while providing real-time system stats right in your menu bar.

Built for developers and power users who want to keep an eye on their system without opening Activity Monitor every five minutes.

## Features

- **CPU usage** — Real-time percentage via `host_processor_info()`
- **GPU usage** — Parsed from `ioreg` (Apple Silicon & Intel)
- **RAM usage** — Active + wired + compressed memory
- **Network speed** — Upload/download in Mb/s via `getifaddrs()`
- **Public IP** — Fetched from [ip.me](https://ip.me) (Proton/Swiss, privacy-focused)
- **Auto-detect interface** — Automatically picks the interface with most traffic
- **Localized** — English and Spanish based on system language
- **macOS native** — No dependencies, compiles with just `swiftc`

## Installation

```bash
git clone https://github.com/gregmarlop/ordino.git
cd ordino
chmod +x build.sh && ./build.sh
open Ordino.app
```

Or [download the latest release](https://github.com/gregmarlop/ordino/releases).

To install permanently:

```bash
cp -r Ordino.app /Applications/
```

To launch at login: **System Settings → General → Login Items → Add Ordino**

## Build Requirements

- macOS 12+ (Monterey or later)
- Xcode Command Line Tools (`xcode-select --install`)

## Usage

Once running, Ordino lives in your menu bar:

```
CPU  5%  GPU  8%  RAM 45%  ↓  0.50Mb  ↑  0.10Mb
```

Click to access the menu:

```
Interface     ▶  ✓ Auto-detect
                 ─────────
                 Wi-Fi (en0)
                 Ethernet Adapter (en4)

Show          ▶  ✓ CPU
                 ✓ GPU
                 ✓ RAM
                 ─────────
                 ✓ Download
                 ✓ Upload
                 ─────────
                   IP
─────────
Quit          ⌘Q
```

## Configuration

All options are accessible via the menu. Toggle any stat on/off to customize your view.

| Option | Description | Default |
|--------|-------------|---------|
| CPU | Show CPU usage percentage | ✓ On |
| GPU | Show GPU usage percentage | ✓ On |
| RAM | Show RAM usage percentage | ✓ On |
| Download | Show download speed (Mb/s) | ✓ On |
| Upload | Show upload speed (Mb/s) | ✓ On |
| IP | Show public IP address | Off |

### Interface Selection

| Mode | Behavior |
|------|----------|
| Auto-detect | Picks interface with most traffic each second |
| Manual | Lock to specific interface (Wi-Fi, Ethernet) |

## Technical Details

### Update Intervals

| Metric | Interval | Method |
|--------|----------|--------|
| CPU | 1s | `host_processor_info()` |
| RAM | 1s | `vm_statistics64()` |
| Network | 1s | `getifaddrs()` / `if_data` |
| GPU | 3s | `ioreg` (background thread) |
| Public IP | 5min | `ip.me` API (cached) |

### Why These Choices?

- **GPU every 3s**: Calling `ioreg` is expensive. 3 seconds is a good balance.
- **IP every 5min**: Your public IP rarely changes. No need to hammer the API.
- **Monospaced digits**: Uses `NSFont.monospacedDigitSystemFont` to prevent UI jumping when numbers change (e.g., `8%` → `10%`).

### Network Speed Filtering

Values over 10 Gbps are filtered as counter errors. This prevents absurd spikes when:
- Switching between interfaces in auto mode
- System wakes from sleep
- Counter overflow

## Privacy

- **No telemetry** — Ordino sends no data anywhere
- **No analytics** — What happens on your Mac stays on your Mac
- **Public IP** — Only fetched from [ip.me](https://ip.me) (Proton, Switzerland) when you explicitly enable it
- **Local only** — All system stats are read locally via macOS APIs

## Limitations

- **GPU on some Macs**: Not all Macs expose GPU utilization via `ioreg`. May show 0%.
- **Virtual interfaces**: Filtered out. Only shows interfaces with actual traffic.
- **Network counters**: Based on bytes since boot. First reading after launch may be inaccurate.
- **Apple Silicon**: Works, but GPU reporting varies by chip generation.

## File Structure

```
Ordino/
├── ordino.swift    # All source code (~400 lines)
├── Info.plist      # App bundle configuration
├── build.sh        # Build script
└── README.md       # This file
```

## Credits

- Network stats approach inspired by [Stats](https://github.com/exelban/stats)
- Public IP service by [Proton](https://proton.me) via [ip.me](https://ip.me)

## Contributing

Found a bug? [Open an issue](https://github.com/gregmarlop/ordino/issues).

Want a feature? [Submit a PR](https://github.com/gregmarlop/ordino/pulls).

## License

MIT License

## Author

Gregori M.

---

*Ordino: Because your menu bar shouldn't need 200MB of RAM to show you how much RAM you have.*
