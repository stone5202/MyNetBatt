import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 資料結構與監控邏輯
struct TrafficData: Identifiable { let id = UUID(); let time: Date; let downloadSpeed: Double; let uploadSpeed: Double }
struct BatteryData: Identifiable, Codable { var id = UUID(); let time: Date; let level: Int }
struct SimpleData: Identifiable { let id = UUID(); let time: Date; let value: Double }

struct AppNetworkUsage: Identifiable {
    let id: String
    let name: String
    let pid: Int?
    let downloadSpeed: Double
    let uploadSpeed: Double
    let totalDownload: UInt64
    let totalUpload: UInt64

    var isActive: Bool { downloadSpeed + uploadSpeed > 1024 }
}

struct AppDataUsageItem: Identifiable {
    let id: String
    let name: String
    let bytes: UInt64
    let pid: Int?
}

struct ThunderboltDeviceInfo: Identifiable {
    let id: String
    let name: String
    let vendor: String
    let uid: String
    let firmware: String
    let connection: String
}

struct StorageVolumeInfo: Identifiable {
    let id: String
    let name: String
    let mountPath: String
    let usedBytes: Int64
    let availableBytes: Int64
    let totalBytes: Int64
    let isInternal: Bool

    var usagePct: Double {
        guard totalBytes > 0 else { return 0 }
        return max(0, min(100, Double(usedBytes) / Double(totalBytes) * 100))
    }
}
