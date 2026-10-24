import Foundation

// MARK: - 周邊電量的取樣與通知

extension SystemMonitor {
    /// IOKit 與配件電源每輪都讀；system_profiler 在有畫面顯示周邊電量時每 30 秒、平常每 5 分鐘讀一次。
    static let peripheralProfilerVisibleInterval: TimeInterval = 30
    static let peripheralProfilerBackgroundInterval: TimeInterval = 300

    func startPeripheralMonitor() {
        Task {
            while !Task.isCancelled {
                fetchPeripheralBatteries()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func fetchPeripheralBatteries(forceProfiler: Bool = false) {
        let interval = batteryViewers.isEmpty ? Self.peripheralProfilerBackgroundInterval : Self.peripheralProfilerVisibleInterval
        let needsProfiler = forceProfiler || lastPeripheralProfilerTime.map { Date().timeIntervalSince($0) >= interval - 1 } ?? true
        if needsProfiler { lastPeripheralProfilerTime = Date() }
        let cached = peripheralProfilerCache
        runExclusive("peripherals") {
            let profiler = needsProfiler
                ? PeripheralBatteryReader.readBluetoothProfiler(run: { self.runCommandData($0, $1) })
                : cached
            let merged = PeripheralBatteryReader.merge(
                profiler: profiler,
                accessories: PeripheralBatteryReader.readAccessoryPowerSources(),
                hid: PeripheralBatteryReader.readHIDDevices()
            )
            await MainActor.run {
                if needsProfiler { self.peripheralProfilerCache = profiler }
                self.assignIfChanged(\.peripherals, merged)
                self.evaluatePeripheralNotifications()
            }
        }
    }

    /// 周邊裝置電量降到 10% 時通知一次，充電回 20% 以上才重新計算；通知關閉時不算已提醒。
    func evaluatePeripheralNotifications() {
        let result = AlertPolicy.peripherals(
            peripherals.map { ($0.name, $0.primaryLevel) }, notified: peripheralLowNotified, enabled: notifyPeripheralLow
        )
        peripheralLowNotified = result.notified
        for name in result.notify {
            let level = peripherals.first { $0.name == name }?.primaryLevel ?? 0
            BatteryNotifier.shared.post(
                id: "peripheral-\(name)", title: String(localized: "周邊裝置電量不足"),
                body: String(localized: "「\(name)」電量剩餘 \(level)%，請記得充電。"),
                sound: notificationSound
            )
        }
    }
}
