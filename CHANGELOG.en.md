# Changelog

[繁體中文](CHANGELOG.md) · [**English**](CHANGELOG.en.md)

This document summarizes the major changes in each MyNetBatt release. Versions before 3.0 were uploaded by replacing earlier copies, so their original per-version Git history can no longer be fully recovered. Changes from 1.0 through 2.x are therefore consolidated from the source code that can still be verified, without attributing uncertain details to individual releases.

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

[3.1]: https://github.com/stone5202/MyNetBatt/releases/tag/v3.1
[3.0]: https://github.com/stone5202/MyNetBatt/releases/tag/v3.0
[1.0–2.x]: https://github.com/stone5202/MyNetBatt/releases/tag/v1.0
