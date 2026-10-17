# MyNetBatt

<p align="center">
  <a href="README.md">繁體中文</a> · <strong>English</strong>
</p>

<p align="center">
  <img src="MyNetBatt/MyNetBatt/Assets.xcassets/AppIcon.appiconset/MyNetBatt.png" width="128" alt="MyNetBatt app icon">
</p>

MyNetBatt is a native macOS menu bar system monitor that brings battery, network, system performance, storage, and accessories together in one interface.

> **4.0: a new look, redesigned from the ground up.** The monitor window has been completely redesigned, with a new Overview page, six desktop widgets, accessory battery levels, folder sizes and large files, an English interface, and a welcome tour, while keeping the glass look.
>
> Current version: 4.0 · Interface languages: Traditional Chinese, English

See the [changelog](CHANGELOG.en.md) or [GitHub Releases](https://github.com/stone5202/MyNetBatt/releases) for the changes in each version. The changelog is also available in [Traditional Chinese](CHANGELOG.md).

## Screenshots

<p align="center">
  <img src="docs/screenshots/en/overview.webp" width="90%" alt="MyNetBatt monitor window Overview page">
</p>

<p align="center">
  Monitor window: Overview
</p>

<p align="center">
  <img src="docs/screenshots/en/widget.webp" width="90%" alt="The six MyNetBatt desktop widgets">
</p>

<p align="center">
  Desktop widgets: Battery, Data Usage, App Data Usage, Storage, Wi‑Fi, Accessory Battery
</p>

<p align="center">
  <img src="docs/screenshots/en/network.webp" width="40%" alt="MyNetBatt network popover">
  &nbsp;
  <img src="docs/screenshots/en/battery.webp" width="38%" alt="MyNetBatt battery popover">
</p>

<p align="center">
  Network popover · Battery popover
</p>

<p align="center">
  <img src="docs/screenshots/en/monitor.webp" width="90%" alt="MyNetBatt Battery page with power details and the Charger & Cable card">
</p>

<p align="center">
  <img src="docs/screenshots/en/settings.webp" width="90%" alt="MyNetBatt Settings">
</p>

<p align="center">
  Battery page · Settings
</p>

<p align="center">
  <img src="docs/screenshots/menubar.webp" width="45%" alt="MyNetBatt menu bar items for CPU, memory, storage and network">
</p>

<p align="center">
  Menu bar
</p>

## Project status

MyNetBatt is under active development and maintenance. Its complete source code is available under the MIT License, and community bug reports, feature suggestions, and pull requests are welcome.

- Native Swift and SwiftUI macOS application
- Primarily developed and tested on Apple Silicon
- Includes an Xcode project for local builds
- Includes a Privileged Helper designed around signature validation and least privilege
- Processes and stores most monitoring data locally, with no analytics, advertising, or user-tracking SDKs

## Features

- An Overview page in the monitor window shows battery, network, system, storage, connection, and accessories at a glance
- Battery icon, percentage, real-time network speed, and traffic chart in the menu bar; eight network speed styles (two lines, single line, upload only, download only, combined, speed with today's usage, speed with CPU, speed with memory) and an area, mirrored, or bar traffic chart that can be widened, picked from live previews in Settings
- Optional CPU, memory, and storage usage items in the menu bar
- Battery level, charging state, health, cycle count, temperature, power, and charge duration; the 48-hour chart is coloured by power source and marks charging and on-battery periods
- While plugged in: adapter wattage, actual input power, system load, adapter voltage and current, and conversion loss
- Charger and cable diagnosis: lists the charger's voltage and current profiles and the one in use, reads the cable's e-marker for its power rating and speed, and tells you when the cable is limiting charging
- Records the duration and battery drain of the most recent sleep on battery
- Daily log of battery health and cycle count, viewable over 30 days, 90 days, 1 year, or all time with a day-by-day list
- Notifications for low battery (at several levels you choose), full charge, high battery temperature, health drop, power surge (naming the app using the most CPU), high drain during sleep, and low accessory battery, with a choice of system alert sounds
- Accessory battery for Magic Keyboard, Mouse, and Trackpad, plus AirPods (each bud and the case) and other Bluetooth devices
- macOS Low Power Mode control through a signed Privileged Helper; it can turn on automatically when the battery falls to a threshold and off again when power is connected
- Upload and download speeds, average speed, cumulative traffic, today's hourly usage, interface, local IP, gateway, DNS, and public IP details
- Wi-Fi channel, signal strength, transmit rate, and security
- Daily, weekly, monthly, and yearly network usage per app (helpers and other child processes count towards the app that owns them, and other processes can optionally be listed separately), with upload and download counted separately and a history chart; tracking can be paused
- Live list of apps currently using the network
- Six desktop and Notification Center widgets: Battery, Data Usage, App Data Usage, Storage, Wi-Fi, and Accessory Battery, with selectable theme colors
- Always-on-top float window that can be toggled with a global shortcut, with adjustable background opacity
- Configurable sections in the network and battery popovers
- CPU, GPU, memory (including memory pressure), swap, and storage monitoring, with buttons to eject one or all external volumes
- Folder sizes and files of 100 MB or larger, which can be shown in Finder or moved to the Trash
- Hide the notch with a generated wallpaper that has a black top edge; the original can be restored at any time
- Thunderbolt, USB4, and USB device information; what is connected to each USB-C and MagSafe port, and each cable's type, speed, power rating, and manufacturer
- Theme (auto, light, dark), glass style, and accent color
- Traditional Chinese and English interface, switchable in Settings, and a welcome tour on first launch
- Automatic monitoring refresh after waking from sleep
- Launch-at-login support

## Requirements

- macOS 26.5 or later
- Apple Silicon Mac (the project is currently developed and tested on `arm64`)
- Xcode 26 or later

## Building from source

1. Clone the repository:

   ```bash
   git clone https://github.com/stone5202/MyNetBatt.git
   cd MyNetBatt
   ```

2. Open the project in Xcode:

   ```bash
   open MyNetBatt/MyNetBatt.xcodeproj
   ```

3. Select your Development Team for the `MyNetBatt`, `MyNetBattPrivilegedHelper`, and `MyNetBattWidget` targets.
4. If you use your own signing identity and bundle identifier, update all of the following together:

   - `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` in the Xcode project
   - `MyNetBatt/MyNetBatt/PrivilegedHelperProtocol.swift`
   - `MyNetBatt/PrivilegedHelper/HelperProtocol.swift`
   - The App Group (`<Team ID>.com.stone5202.MyNetBatt`) in both `WidgetSnapshot.swift` files and both `.entitlements` files

5. Select the `MyNetBatt` scheme, then build and run.

You can also build from the command line:

```bash
xcodebuild \
  -project MyNetBatt/MyNetBatt.xcodeproj \
  -scheme MyNetBatt \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

## Privileged Helper

Changing macOS Low Power Mode requires administrator privileges. MyNetBatt uses `SMAppService` so macOS manages the helper bundled inside the app: when enabling it for the first time, allow MyNetBatt in System Settings › General › Login Items & Extensions. After that, changing Low Power Mode does not require a password. The helper is updated together with the app and leaves no extra files on the system.

When upgrading from 3.2 or earlier, the app shows an "Update Helper" button and asks for an administrator password once to remove the old installation.

The helper exposes only methods for reading and changing Low Power Mode. It does not accept arbitrary shell commands, paths, or arguments. The main app and helper mutually verify their signing identifiers and Team ID. See the [Privileged Helper documentation](docs/PRIVILEGED_HELPER_SETUP.md) for the complete design.

## Privacy and network access

- Battery history, per-app network usage, and interface preferences are stored locally in `UserDefaults`.
- MyNetBatt contains no analytics, advertising, or user-tracking SDKs.
- To display the public IP address, the app sends a request to [`https://api.ipify.org`](https://api.ipify.org); that service will naturally receive the source IP address of the request.
- Showing the Wi-Fi network name requires Location access (a macOS requirement) and is requested only when you ask for it; MyNetBatt does not record or transmit your location.
- Storage scans read file sizes only, never file contents. The first scan of Desktop, Documents, and Downloads triggers the standard macOS access prompt.
- Other hardware and system information comes from built-in macOS APIs and command-line tools.

## Project structure

```text
MyNetBatt/
├── MyNetBatt/                 # Main SwiftUI views and system monitoring
├── PrivilegedHelper/          # Low Power Mode XPC helper
├── MyNetBattWidget/           # Desktop widget (WidgetKit extension)
└── MyNetBatt.xcodeproj/       # Xcode project
docs/
├── PRIVILEGED_HELPER_SETUP.md
└── screenshots/               # README application screenshots
```

## Roadmap

Current areas planned for continued improvement include:

- Expanding system and hardware information and improving compatibility across Apple Silicon models
- Improving network traffic and per-app/process statistics and history presentation
- Adding automated tests and build validation to make releases more reliable
- Continuing to review Privileged Helper security boundaries, signature validation, and least-privilege design
- Improving documentation, debugging information, and issue and pull-request workflows
- Evaluating open-source development workflows that use AI to assist code analysis, testing, documentation, and maintenance

The roadmap may change based on macOS updates, user feedback, and development progress. Feature suggestions are welcome through GitHub issues.

## Contributing

Issues and pull requests are welcome. Before submitting a change, please make sure that:

- The project builds successfully with the current `MyNetBatt` scheme
- `xcuserdata`, `.DS_Store`, DerivedData, and other local artifacts are not committed
- Changes to helper identifiers or signing requirements are applied consistently to the main app, helper, and documentation

## License

This project is available under the [MIT License](LICENSE).
