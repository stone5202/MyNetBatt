// 共用核心（見 CaptiveModels.swift 開頭說明）
import Foundation
import WebKit

enum AgentOutcome {
    case success(String?)        // 按下的按鈕文字（已經連網就是 nil）
    case needsInput(String)      // 登入頁要輸入資料（密碼、手機…）
    case noButton([String])      // 找不到可以按的按鈕；附上頁面上看到的按鈕文字
    case failed(String)
    case cancelled               // 暫停、換網路或規則被關掉
}

/// 開一個看不見的網頁，載入登入頁、自動勾選與按按鈕，直到連網檢查通過。
@MainActor
final class PortalAgent: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView!
    private var lastNavigationEvent = Date()
    private var lastError: String?
    private var finishedOnce = false

    /// 最後停在的登入頁網域（成功時記進規則）
    var finalHost: String? { webView.url?.host }

    /// persistent：手動登入視窗用一般的資料存放區；背景自動登入用不保存的（不帶 cookie、不留資料）。
    static func makeConfiguration(persistent: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = persistent ? .default() : .nonPersistent()
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // 視窗不在畫面上時也不要降速
        config.preferences.inactiveSchedulingPolicy = .none
        return config
    }

    override init() {
        super.init()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: Self.makeConfiguration(persistent: false))
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// shouldContinue：每一步之前問一次，回 false（暫停、換網路）就停下。整體最多約 60 秒。
    func run(startURL: URL, steps: [LearnedStep], probeURL: URL,
             shouldContinue: @escaping () -> Bool, log: (String) -> Void) async -> AgentOutcome {
        let deadline = Date().addingTimeInterval(60)
        var lastClicked: String?
        var noneStreak = 0
        var clicks = 0
        var lastCandidates: [String] = []
        var doneSteps: [Int] = []
        var clickCount: [String: Int] = [:]
        defer { webView.stopLoading() }

        webView.load(URLRequest(url: startURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15))

        while Date() < deadline {
            await waitUntilIdle(timeout: min(10, max(0, deadline.timeIntervalSinceNow)))
            try? await Task.sleep(nanoseconds: 800_000_000)   // 讓頁面上的 JavaScript 畫出按鈕
            guard shouldContinue() else { return .cancelled }

            if await CaptiveProbe.check(probeURL) == .online { return .success(lastClicked) }
            guard shouldContinue(), Date() < deadline else { break }
            if !finishedOnce, let err = lastError { return .failed(String(localized: "登入頁打不開：\(err)")) }

            let obj = await PortalScript.run(in: webView, steps: steps, done: doneSteps)
            let action = obj["action"] as? String ?? "none"

            switch action {
            case "ticked":
                log(String(localized: "勾選了 \(obj["count"] as? Int ?? 1) 個同意方塊"))
                try? await Task.sleep(nanoseconds: 600_000_000)
            case "clicked":
                let text = obj["text"] as? String ?? ""
                let via = (obj["via"] as? String) == "learned" ? String(localized: "（教學記下的按鈕）") : ""
                if let step = obj["step"] as? Int { doneSteps.append(step) }
                // 同一顆按鈕最多按 2 次，避免重複送出
                let n = (clickCount[text] ?? 0) + 1
                clickCount[text] = n
                log(String(localized: "按下「\(text.isEmpty ? String(localized: "按鈕") : text)」\(via)"))
                lastClicked = text
                clicks += 1
                noneStreak = 0
                lastNavigationEvent = Date()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if n >= 2 { return await finish(lastClicked: lastClicked, clicks: clicks, candidates: lastCandidates,
                                                probeURL: probeURL, until: deadline, shouldContinue: shouldContinue) }
            case "needsInput":
                return .needsInput(obj["text"] as? String ?? String(localized: "資料"))
            default:
                lastCandidates = obj["candidates"] as? [String] ?? []
                noneStreak += 1
                // 按過之後頁面可能顯示「登入成功」就沒按鈕了，交給最後的確認
                if noneStreak >= 3 { return await finish(lastClicked: lastClicked, clicks: clicks, candidates: lastCandidates,
                                                         probeURL: probeURL, until: deadline, shouldContinue: shouldContinue) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        return await finish(lastClicked: lastClicked, clicks: clicks, candidates: lastCandidates,
                            probeURL: probeURL, until: deadline, shouldContinue: shouldContinue)
    }

    /// 最後確認網路有沒有恢復（最多再等 10 秒，不超過整體時限太多）。
    private func finish(lastClicked: String?, clicks: Int, candidates: [String], probeURL: URL,
                        until deadline: Date, shouldContinue: () -> Bool) async -> AgentOutcome {
        let end = min(Date().addingTimeInterval(10), deadline.addingTimeInterval(10))
        repeat {
            guard shouldContinue() else { return .cancelled }
            if await CaptiveProbe.check(probeURL) == .online { return .success(lastClicked) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        } while Date() < end
        if clicks == 0 { return .noButton(candidates) }
        return .failed(String(localized: "按了「\(lastClicked ?? String(localized: "按鈕"))」但還是沒有網路"))
    }

    private func waitUntilIdle(timeout: TimeInterval) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !webView.isLoading && Date().timeIntervalSince(lastNavigationEvent) > 0.8 { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastNavigationEvent = Date()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastNavigationEvent = Date()
        finishedOnce = true
        lastError = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastNavigationEvent = Date()
        if (error as NSError).code != NSURLErrorCancelled { lastError = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lastNavigationEvent = Date()
        if (error as NSError).code != NSURLErrorCancelled { lastError = error.localizedDescription }
    }

    /// 醫院登入頁常用自簽憑證。背景這裡只按同意、不填資料、不帶 cookie（不保存的資料存放區），所以接受。
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }

    // MARK: - WKUIDelegate（登入頁的 alert／confirm／新視窗）

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        // 「確定要同意嗎？」這類才按確定；付費、登出、分享資料等一律取消
        return PortalScript.shouldAcceptConfirm(message)
    }
}
