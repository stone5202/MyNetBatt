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
struct BatteryHealthEntry: Codable, Identifiable, Equatable {
    /// "yyyy-MM-dd"，與用量紀錄相同的日期 key。
    let day: String
    var health: Int
    var cycles: Int
    var id: String { day }
}
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
    /// 已知的上傳、下載量；舊版紀錄沒有區分方向，兩者相加可能小於 bytes。
    var upload: UInt64 = 0
    var download: UInt64 = 0
}

/// 用量長條圖的一段：某一天（或某個月）某個方向的用量。
struct UsageBarPoint: Identifiable {
    let id: String
    let date: Date
    let kind: String
    let bytes: Double
}

struct ThunderboltDeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let vendor: String
    let uid: String
    let firmware: String
    let connection: String
}

struct StorageVolumeInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let mountPath: String
    let usedBytes: Int64
    let availableBytes: Int64
    let totalBytes: Int64
    let isInternal: Bool
    var isEjectable = false

    var usagePct: Double {
        guard totalBytes > 0 else { return 0 }
        return max(0, min(100, Double(usedBytes) / Double(totalBytes) * 100))
    }
}
