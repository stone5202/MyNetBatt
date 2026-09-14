import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func fetchThunderboltDevices() {
        Task.detached {
            var devices: [ThunderboltDeviceInfo] = []

            func stringValue(_ dict: [String: Any], keys: [String]) -> String {
                for key in keys {
                    if let value = dict[key] as? String, !value.isEmpty { return value }
                    if let value = dict[key] as? NSNumber { return value.stringValue }
                }
                return ""
            }

            func collect(_ object: Any, connection: String) {
                if let dict = object as? [String: Any] {
                    if let items = dict["_items"] as? [Any] {
                        for item in items {
                            if let device = item as? [String: Any] {
                                let name = stringValue(device, keys: ["_name", "device_name_key", "device_name"])
                                let vendor = stringValue(device, keys: ["vendor_name_key", "vendor_name", "manufacturer", "manufacturer_name"])
                                let uid = stringValue(device, keys: ["switch_uid_key", "uid", "device_uid", "serial_num", "serial_num_key"])
                                let firmware = stringValue(device, keys: ["switch_version_key", "firmware_version", "firmware_version_key"])
                                let lower = name.lowercased()
                                let ignore = name.isEmpty || lower.contains("host controller") || lower.contains("usb3.1 bus") || lower.contains("usb 3.1 bus") || lower.contains("appleusb")
                                if !ignore {
                                    devices.append(ThunderboltDeviceInfo(
                                        id: [connection, name, uid, vendor].joined(separator: "|"),
                                        name: name, vendor: vendor.isEmpty ? "未知廠商" : vendor,
                                        uid: uid, firmware: firmware, connection: connection
                                    ))
                                }
                            }
                            collect(item, connection: connection)
                        }
                    }
                    for (key, value) in dict where key != "_items" { collect(value, connection: connection) }
                } else if let array = object as? [Any] {
                    for value in array { collect(value, connection: connection) }
                }
            }

            let tbData = self.runCommandData("/usr/sbin/system_profiler", ["-json", "SPThunderboltDataType"])
            if !tbData.isEmpty,
               let root = try? JSONSerialization.jsonObject(with: tbData) as? [String: Any],
               let buses = root["SPThunderboltDataType"] as? [[String: Any]] {
                for bus in buses { collect(bus, connection: "Thunderbolt / USB4") }
            }

            let usbData = self.runCommandData("/usr/sbin/system_profiler", ["-json", "SPUSBDataType"])
            if !usbData.isEmpty,
               let root = try? JSONSerialization.jsonObject(with: usbData) as? [String: Any],
               let buses = root["SPUSBDataType"] as? [[String: Any]] {
                for bus in buses { collect(bus, connection: "USB-C / USB") }
            }

            var seen = Set<String>()
            let unique = devices.filter { device in
                let key = [device.name, device.uid, device.vendor].joined(separator: "|")
                return seen.insert(key).inserted
            }
            let snapshot = unique

            await MainActor.run {
                self.thunderboltDevices = snapshot
                self.thunderboltStatus = snapshot.isEmpty
                    ? "沒有外接 Thunderbolt / USB-C 設備"
                    : "目前偵測到 \(snapshot.count) 個外接設備"
            }
        }
    }

}
