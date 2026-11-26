// 共用核心（見 CaptiveModels.swift 開頭說明）：網路清單與紀錄兩個畫面，獨立 App 的設定視窗與 MyNetBatt 監控中心共用。
import Combine
import SwiftUI

// MARK: - 網路

struct CaptiveNetworksView: View {
    @ObservedObject var store = CaptiveStore.shared
    @ObservedObject var engine = CaptiveEngine.shared
    @State private var newSSID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("只有清單裡的網路會自動按同意與重新連線。醫院的 Wi‑Fi 加進來就好；若自動找不到按鈕，再用「教學」按一次。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.rules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.router").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("還沒有網路。連上醫院 Wi‑Fi 後，按下面的「加入目前的網路」。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($store.rules) { $rule in
                        CaptiveRuleRow(rule: $rule, isCurrent: engine.currentRule?.id == rule.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            HStack {
                Button {
                    store.addRule(ssid: engine.ssid, portalHost: engine.portalURL?.host)
                    engine.checkNow()
                } label: { Label("加入目前的網路", systemImage: "plus") }
                .disabled(engine.ssid == nil && engine.portalURL == nil)
                Spacer()
                TextField("或輸入 Wi‑Fi 名稱", text: $newSSID)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit(addTyped)
                Button("加入", action: addTyped).disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addTyped() {
        let s = newSSID.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        store.addRule(ssid: s, portalHost: nil)
        newSSID = ""
    }
}

struct CaptiveRuleRow: View {
    @Binding var rule: NetworkRule
    var isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $rule.enabled).labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.displayName).font(.headline)
                    if isCurrent {
                        Text("目前").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                let hosts = rule.hosts
                if !hosts.isEmpty, rule.ssid != nil || hosts.count > 1 {
                    HStack(spacing: 4) {
                        Text("登入頁：\(hosts.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                        Menu {
                            ForEach(hosts, id: \.self) { h in
                                Button("忘記 \(h)") { rule.removeHost(h) }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("同一個網路可能有好幾個登入頁（例如醫院不同區域）。登入成功時會自動記下，最多 \(NetworkRule.maxHosts) 個")
                        .accessibilityLabel(Text("管理登入頁"))
                    }
                }
                Text(rule.steps.isEmpty ? String(localized: "自動找「同意／確認」按鈕") : String(localized: "照教學的 \(rule.steps.count) 個動作：") +
                     rule.steps.map { $0.text.isEmpty ? String(localized: "（按鈕）") : $0.text }.joined(separator: " → "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Toggle("斷線或一直沒網路時，自動重開 Wi‑Fi", isOn: $rule.autoReconnect)
                    .toggleStyle(.checkbox).font(.caption)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("教學…") { CaptiveConfig.openPortal(true, rule.id) }
                    .help("打開登入頁，按一次要按的按鈕")
                if !rule.steps.isEmpty {
                    Button("清除教學") { rule.steps = [] }
                }
                Button(role: .destructive) {
                    CaptiveStore.shared.rules.removeAll { $0.id == rule.id }
                } label: { Text("移除") }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 紀錄

struct CaptiveLogView: View {
    @ObservedObject var log = CaptiveLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(log.entries) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.date, format: .dateTime.month().day().hour().minute().second())
                        .monospacedDigit().foregroundStyle(.secondary)
                    Text(e.text)
                        .foregroundStyle(e.level == .warning ? .orange : (e.level == .success ? .green : .primary))
                        .textSelection(.enabled)
                }
                .font(.callout)
            }
            HStack {
                Button("複製全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.allText(), forType: .string)
                }
                Button("在 Finder 中顯示紀錄檔") {
                    NSWorkspace.shared.activateFileViewerSelecting([log.logFileURL])
                }
                Spacer()
            }
        }
    }
}
