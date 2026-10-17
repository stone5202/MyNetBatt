import SwiftUI

// MARK: - 關於
struct AboutView: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        PageScroll {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                Text("MyNetBatt").font(.system(size: 30, weight: .bold))
                Text("版本 \(AppInfo.version)（\(AppInfo.build)）").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Text("電池、網路、系統效能與周邊裝置，一眼看完。")
                    .font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { NotificationCenter.default.post(name: .showWhatsNew, object: nil) } label: {
                        Label("新功能", systemImage: "sparkles")
                    }
                    Button { NotificationCenter.default.post(name: .showOnboarding, object: nil) } label: {
                        Label("重新顯示導覽", systemImage: "hand.wave")
                    }
                    Link(destination: AppInfo.releasesURL) { Label("檢查更新", systemImage: "arrow.down.circle") }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)

            Panel(title: "隱私", symbol: "hand.raised.fill", color: .blue) {
                VStack(alignment: .leading, spacing: 10) {
                    privacyLine("lock.fill", "所有資料只存在這台 Mac 上，不會上傳，也沒有任何分析或追蹤。")
                    privacyLine("network", "唯一的對外連線是向 api.ipify.org 查詢公網 IP，結果顯示在網路頁。")
                    privacyLine("folder", "儲存空間掃描只讀取檔案大小，不讀取檔案內容。")
                    privacyLine("location", "定位權限只用來讓 macOS 提供 Wi‑Fi 名稱，App 不會取得或記錄位置。")
                }
            }

            Panel(title: "支援", symbol: "questionmark.bubble.fill", color: .teal) {
                VStack(alignment: .leading, spacing: 8) {
                    Link(destination: AppInfo.repositoryURL) { Label("專案網頁", systemImage: "safari") }
                    Link(destination: AppInfo.issuesURL) { Label("回報問題或建議", systemImage: "envelope") }
                    Link(destination: AppInfo.releasesURL) { Label("更新紀錄", systemImage: "list.bullet.rectangle") }
                }
            }

            Text("© 2026 stone5202. All rights reserved.")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private func privacyLine(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Notification.Name {
    static let showWhatsNew = Notification.Name("MyNetBattShowWhatsNew")
    static let showOnboarding = Notification.Name("MyNetBattShowOnboarding")
}
