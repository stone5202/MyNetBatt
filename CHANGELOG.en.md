# Changelog

[繁體中文](CHANGELOG.md) · [**English**](CHANGELOG.en.md)

This document summarizes the major changes in each MyNetBatt release. Versions before 3.0 were uploaded by replacing earlier copies, so their original per-version Git history can no longer be fully recovered. Changes from 1.0 through 2.x are therefore consolidated from the source code that can still be verified, without attributing uncertain details to individual releases.

## [3.5.1] - 2026-10-04

### Fixes and improvements

- App names in the network popover's active network list are no longer truncated, and the empty space below the list is reduced.
- Updated the README screenshots.

## [3.5] - 2026-10-04

### New features

- Added a Settings tab to the main window for menu bar, float window, shortcut, notification, and data-reset options; the existing switches on each page and popover remain.
- Float window: always on top and draggable, showing network speed, battery level, CPU, and memory, with adjustable size, opacity, background blur, border, and shadow.
- Global shortcuts for showing or hiding the float window and opening the main window.
- Battery notifications for low battery and fully charged, with an optional sound.
- Wi-Fi details: channel, signal strength, transmit rate, security, and MAC address. Showing the network name requires Location access, which is requested only when you click "Show Wi-Fi name".
- Copy buttons next to the local IP, public IP, and MAC address.
- Live list of apps currently using the network, with their upload and download speeds.
- External volumes can be ejected from the storage list.
- The memory card now shows memory pressure.
- Shows the start and end level and the duration of the current or last charge.

### Menu bar and appearance

- Menu bar network speed can show upload and download, upload only, or download only, with optional arrows and a wide or compact width.
- The battery icon now matches the size of the system battery icon and fills continuously with the actual percentage; the previous smaller icon is still available in Settings.
- Added a theme option (auto, light, dark) and an accent color.

### Data usage

- Added month and year periods: daily detail is kept for 31 days, plus monthly totals for 12 months.
- Upload and download are recorded separately per app; records from before the upgrade only have a total and are shown as unclassified.
- A history chart is shown for the week, month, and year periods.
- Data usage and battery history can be reset from the Settings tab.

## [3.4] - 2026-10-02

### Performance and power usage

- Cut background CPU usage by about another 70% (90-second average on a fresh launch with no windows open: 4.22% to 1.24%).
- The network and battery popovers now build their views when opened and release them when closed, so charts no longer re-render in the background.
- Adopted Swift Observation: each view re-renders only when the data it uses changes, so the menu bar no longer redraws for unrelated updates, and unchanged samples no longer trigger redraws.
- CPU usage is now calculated from the previous sample instead of waiting 150 ms each time, and reflects the full 2-second interval.
- Disk capacity is refreshed every 30 seconds and immediately when a disk is mounted or ejected.
- Network details are refreshed when the network changes instead of running several system commands every 30 seconds.
- The 48-hour battery history is saved at most every 10 minutes and when the app quits.

## [3.3.1] - 2026-10-02

### Fixes and improvements

- The battery icon now always shows a bolt while external power is connected; it no longer disappears when the battery is full or macOS pauses charging.
- Per-app network usage is now sampled every 2 seconds only while the network popover or network page is open, and every 60 seconds otherwise, further reducing power usage. Daily and weekly totals continue to accumulate.
- Prevented duplicate instances: if MyNetBatt is already running, a newly launched copy quits automatically instead of adding a second set of menu bar items.

## [3.3] - 2026-10-02

### Privileged Helper and security

- The Low Power Mode helper is now managed by macOS ServiceManagement (`SMAppService`). The helper ships inside the app and updates with it; it is no longer copied to `/Library`, and the AppleScript installation flow is gone.
- When enabling it for the first time, allow MyNetBatt in System Settings › General › Login Items & Extensions. After that, changing Low Power Mode does not require a password.
- Hardened Runtime is now enabled for the main app, matching the helper's code signing design and meeting notarization requirements.
- Added a helper version check: if an older helper is still running after an app update, it is replaced automatically. The helper exits after 60 seconds of inactivity.

### Fixes and improvements

- If the helper cannot be started, the app now registers it again and retries automatically, showing progress while it works.
- Administrator authorization for removing the old helper now runs in the background, so the interface no longer freezes while waiting for the password.
- Low Power Mode state now follows system notifications instead of polling every second.
- Helper registration, repair, and toggle results are written to the unified log for easier troubleshooting.
- Removed iOS/visionOS settings left over from the Xcode template; the app and helper now both require macOS 26.5.

### Upgrade notes

- When upgrading from 3.2 or earlier, click "Update Helper" on the Battery page and enter an administrator password once to remove the old installation, then allow MyNetBatt in System Settings.

## [3.2] - 2026-10-02

### Performance and power usage

- Greatly reduced MyNetBatt's own power usage: background CPU usage dropped from about 24% to about 4%, and memory from about 82 MB to about 31 MB.
- The main window is now created when opened and released when closed, so the 48-hour battery chart no longer re-renders in the background.
- CPU model, memory, swap, GPU, battery, and network counters are now read directly through system APIs, cutting spawned helper processes from about 400 to about 45 per minute.
- Thunderbolt/USB devices now refresh when a device is connected or disconnected instead of being fully rescanned every 10 seconds.
- The public IP is now refreshed only when the network changes or on manual refresh; battery health is refreshed every 10 minutes.
- Slow sampling rounds no longer overlap, and per-app network usage history is written less often.

### Fixes and improvements

- Battery health now consistently uses the Maximum Capacity reported by macOS, matching System Settings.
- Per-app network usage history now always uses Gregorian date keys, so switching the system calendar no longer deletes or strands old records.
- A slow helper start on the first Low Power Mode toggle is no longer reported as "not responding".
- The Launch at Login switch now reverts to the actual state when registration fails.
- Fixed a command execution pattern in the Privileged Helper that could hang, and a system resource leak during long-running sessions.

## [3.1] - 2026-09-21

### Added

- Added a configurable low-battery warning threshold from 5% to 50% in 5% increments, with a default of 20%.
- The menu bar, battery popover, and battery details now turn red when the Mac is unplugged and the battery falls below the selected threshold.
- The warning threshold is stored locally and restored automatically on the next launch.

### Fixes and improvements

- Ignore incorrect 0% battery samples produced while macOS is waking or battery data is temporarily unavailable, preventing distorted history charts.
- Automatically remove invalid 0% samples previously saved by older builds.
- Refined the warning controls to keep the battery popover compact and easier to read.

## [3.0] - 2026-09-16

Version 3.0 is a major architecture and feature update that turns the monitoring features accumulated in earlier releases into a more complete and maintainable native macOS menu bar utility.

### Battery and power

- Expanded battery telemetry with charge level, charging state, health, cycle count, temperature, power, and historical trends in one place.
- Added storage and charting for up to 48 hours of battery history.
- Added support for reading and switching macOS Low Power Mode.
- Introduced a signed Privileged Helper and XPC communication flow. Administrator approval is required during installation or repair, but not for everyday Low Power Mode switching afterward.
- Added helper status checks, stale-installation detection, and a self-service repair interface, with signing identifier and Team ID validation between the app and helper.

### Network monitoring

- Added real-time upload and download speeds, traffic charts, active interface details, local IP address, gateway, DNS, and public IP address.
- Added daily and weekly network usage statistics and sorting for individual apps and processes.
- Improved traffic baseline calculations and data refreshes when network interfaces change.

### System and device information

- Added CPU, GPU, memory, swap, and storage monitoring.
- Added Mac model, processor, and graphics information.
- Added organized details for Thunderbolt, USB4, and USB devices.
- Monitoring baselines are now reset and system data is refreshed in stages after waking from sleep.

### Interface and architecture

- Redesigned the battery and network popovers and introduced a sidebar-based monitoring center.
- Added independent controls for the menu bar battery icon, percentage, network speed, and traffic chart.
- Added launch-at-login support and local persistence for display preferences and monitoring history.
- Split the original single-file implementation into separate views, models, collectors, and helper modules for easier maintenance and future expansion.

## [1.0–2.x] - Consolidated early release history

MyNetBatt established its core monitoring experience in version 1.0. Later 1.x and 2.x updates were uploaded by replacing earlier versions, so the verifiable changes from this period are consolidated below:

- Created a native SwiftUI macOS menu bar app with a Traditional Chinese interface.
- Added menu bar battery icon and percentage displays, real-time network speed, and a compact traffic graph.
- Added quick battery and network popovers, along with detailed pages for battery, network, and system performance.
- Added essential battery information and trends, network interface and traffic data, and system information including CPU, memory, swap, and storage usage.
- Added visibility controls for individual monitoring modules, persistent preferences, and launch-at-login support.

[3.4]: https://github.com/stone5202/MyNetBatt/releases/tag/v3.4
[3.3.1]: https://github.com/stone5202/MyNetBatt/releases/tag/v3.3.1
[3.3]: https://github.com/stone5202/MyNetBatt/releases/tag/v3.3
[3.2]: https://github.com/stone5202/MyNetBatt/releases/tag/v3.2
[3.1]: https://github.com/stone5202/MyNetBatt/releases/tag/v3.1
[3.0]: https://github.com/stone5202/MyNetBatt/releases/tag/v3.0
[1.0–2.x]: https://github.com/stone5202/MyNetBatt/releases/tag/v1.0
