// 共用核心（見 CaptiveModels.swift 開頭說明）
import Combine
import SwiftUI
import WebKit

/// 看得到的登入頁視窗：手動登入，或開「教學模式」記下要按的按鈕。
@MainActor
final class PortalWindowModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    @Published var learning = false
    @Published var captured: [LearnedStep] = []
    @Published var capturedHost: String?
    @Published var urlText = ""
    @Published var isLoading = false
    @Published var online = false
    @Published var savedMessage: String?
    /// 教學要存到哪個網路（從設定某一列進來就是那一列；從選單進來是開始教學時連著的網路）
    @Published var targetRuleID: UUID?
    @Published var targetSSID: String?
    @Published var targetHost: String?
    private var allowedBadCertHosts: Set<String> = []

    var targetName: String {
        if let id = targetRuleID, let r = CaptiveStore.shared.rules.first(where: { $0.id == id }) { return r.displayName }
        return targetSSID ?? targetHost ?? capturedHost ?? String(localized: "目前的網路")
    }

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: PortalWindowModel?
        init(_ t: PortalWindowModel) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(c, didReceive: message)
        }
    }

    override init() {
        let config = PortalAgent.makeConfiguration(persistent: true)
        // 錄製程式放在 App 自己的隔離世界：頁面的程式看不到，也送不出假的教學訊息
        let script = WKUserScript(source: PortalScript.learnRecorder, injectionTime: .atDocumentEnd,
                                  forMainFrameOnly: false, in: PortalScript.world)
        config.userContentController.addUserScript(script)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakHandler(self), contentWorld: PortalScript.world, name: "walLearn")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func loadPortal() {
        savedMessage = nil
        let start = CaptiveEngine.shared.portalURL ?? CaptiveEngine.shared.probeURL
        webView.load(URLRequest(url: start, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15))
    }

    func reload() { webView.reload() }

    func startLearning(ruleID: UUID?) {
        captured = []
        capturedHost = nil
        savedMessage = nil
        targetRuleID = ruleID
        // 開始教學時就固定是哪個網路，存檔時不再看當下連著誰
        targetSSID = CaptiveEngine.shared.ssid
        targetHost = CaptiveEngine.shared.portalURL?.host
        learning = true
    }

    func save() {
        let engine = CaptiveEngine.shared
        let store = CaptiveStore.shared
        let rule: NetworkRule
        if let id = targetRuleID, let i = store.ruleIndex(id: id) {
            store.rules[i].steps = captured
            if let h = capturedHost { store.rules[i].addHost(h) }
            rule = store.rules[i]
        } else {
            rule = store.saveSteps(captured, ssid: targetSSID, portalHost: capturedHost ?? targetHost)
        }
        learning = false
        savedMessage = String(localized: "已記下 \(captured.count) 個動作，之後「\(rule.displayName)」會照這樣自動按。")
        CaptiveLog.shared.add(String(localized: "教學完成：「\(rule.displayName)」記下 \(captured.count) 個動作"), .success)
        engine.checkNow()
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit 一律在主執行緒呼叫
        MainActor.assumeIsolated { self.handle(message.body) }
    }

    private func handle(_ body: Any) {
        guard learning, let dict = body as? [String: Any] else { return }
        let kind = dict["kind"] as? String ?? "click"
        let selector = dict["selector"] as? String ?? ""
        let text = dict["text"] as? String ?? ""
        let page = dict["page"] as? String ?? ""
        guard !selector.isEmpty else { return }
        // 點 label 時會連續收到兩次同一個方塊
        if let last = captured.last, last.selector == selector, last.kind == kind { return }
        captured.append(LearnedStep(kind: kind, selector: selector, text: text))
        if capturedHost == nil, let h = URL(string: page)?.host, h != CaptiveEngine.shared.probeURL.host {
            capturedHost = h
        }
    }

    // MARK: 導覽

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        urlText = webView.url?.absoluteString ?? ""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        urlText = webView.url?.absoluteString ?? ""
        Task {
            let r = await CaptiveProbe.check(CaptiveEngine.shared.probeURL)
            self.online = (r == .online)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        if (error as NSError).code != NSURLErrorCancelled { urlText = String(localized: "打不開：\(error.localizedDescription)") }
    }

    /// 手動視窗可能要你輸入資料，所以憑證照系統檢查；不通過時先問你要不要繼續。
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        if SecTrustEvaluateWithError(trust, nil) { return (.performDefaultHandling, nil) }
        let host = challenge.protectionSpace.host
        if allowedBadCertHosts.contains(host) { return (.useCredential, URLCredential(trust: trust)) }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = String(localized: "「\(host)」的安全憑證無效")
        a.informativeText = String(localized: "醫院、飯店的登入頁常用自簽憑證，只按「同意」通常沒關係；但若不確定這是不是正確的 Wi‑Fi，請不要在這頁輸入帳號密碼或個人資料。")
        a.addButton(withTitle: String(localized: "取消"))
        a.addButton(withTitle: String(localized: "仍要繼續"))
        if a.runModal() == .alertSecondButtonReturn {
            allowedBadCertHosts.insert(host)
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let a = NSAlert()
        a.messageText = message
        a.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: String(localized: "確定"))
        a.addButton(withTitle: String(localized: "取消"))
        return a.runModal() == .alertFirstButtonReturn
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PortalView: View {
    @ObservedObject var model: PortalWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.online ? "checkmark.circle.fill" : "network")
                    .foregroundStyle(model.online ? .green : .secondary)
                Text(model.urlText.isEmpty ? String(localized: "載入中…") : model.urlText)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { model.loadPortal() } label: { Label("重新開登入頁", systemImage: "arrow.clockwise") }
                if model.learning {
                    Button("取消教學") { model.learning = false; model.captured = [] }
                } else {
                    Button { model.startLearning(ruleID: nil) } label: { Label("教學模式", systemImage: "hand.tap") }
                        .help("在登入頁上按一次「同意／確認」，App 會記住要按哪一顆")
                }
            }
            .padding(10)

            if model.learning {
                learnBar
            } else if let msg = model.savedMessage {
                banner(msg, systemImage: "checkmark.seal.fill", color: .green)
            } else if model.online {
                banner(String(localized: "目前已經可以上網。要教學的話，等登入頁出現時再按「教學模式」。"), systemImage: "wifi", color: .green)
            }
            Divider()
            WebViewHost(webView: model.webView)
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private func banner(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(color.opacity(0.12))
    }

    private var learnBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill").foregroundStyle(.orange)
                Text("教學「\(model.targetName)」：請在下面的登入頁照平常那樣勾選、按「同意／確認」，我會記住你按的地方（不會記你輸入的帳號密碼）。按完再按「儲存」。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            if !model.captured.isEmpty {
                ForEach(Array(model.captured.enumerated()), id: \.element.id) { i, step in
                    HStack(spacing: 6) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: step.kind == "check" ? "checkmark.square" : "cursorarrow.click")
                        Text(step.text.isEmpty ? String(localized: "（沒有文字）") : step.text).lineLimit(1)
                        Text(step.selector).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .font(.callout)
                }
            }
            HStack {
                Spacer()
                Button("清除") { model.captured = [] }.disabled(model.captured.isEmpty)
                Button("儲存") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.captured.isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
