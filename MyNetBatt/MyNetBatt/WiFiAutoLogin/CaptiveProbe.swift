// 共用核心（見 CaptiveModels.swift 開頭說明）
import Foundation

nonisolated enum CaptiveProbeResult: Equatable {
    case online
    case captive(URL?)          // 被登入頁攔下；URL 是轉址目標（有的話）
    case offline(String)        // 連不出去（逾時、DNS 失敗…）
    case inconclusive(String)   // 檢查本身有問題（伺服器錯誤、被系統擋），不算斷線也不算被攔
    case cancelled              // 檢查被取消，結果不採用

    var label: String {
        switch self {
        case .online: return String(localized: "已連網")
        case .captive(let u): return String(localized: "需要登入（\(u?.host ?? String(localized: "未知登入頁"))）")
        case .offline(let why): return String(localized: "沒有網路（\(why)）")
        case .inconclusive(let why): return String(localized: "無法判斷（\(why)）")
        case .cancelled: return String(localized: "已取消")
        }
    }
}

/// 用 Apple 的連網檢查網址判斷是不是被登入頁攔下。不跟隨轉址，才拿得到登入頁網址。
nonisolated enum CaptiveProbe {
    static let defaultURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!

    /// 用綁 Wi‑Fi 介面的連線檢查（見 ScopedHTTP）：macOS 偵測到登入頁時一般連線會被擋成「未連線」，
    /// 綁介面的才拿得到登入頁。不跟隨轉址，才拿得到登入頁網址。
    /// 綁介面的檢查逾時／連不上／查不到主機時，再用系統一般路線（會走代理伺服器）檢查一次，
    /// 避免「只能經代理上網」的網路被當成斷線而一直重開 Wi‑Fi。
    static func check(_ url: URL) async -> CaptiveProbeResult {
        let scoped = await checkScoped(url)
        guard needsSystemRouteCheck(scoped) else { return scoped }
        return combine(scoped: scoped, system: await checkSystemRoute(url))
    }

    static func checkScoped(_ url: URL) async -> CaptiveProbeResult {
        do {
            // 檢查網址本身就是本機（測試用設定）才允許連本機
            let r = try await ScopedHTTP.request(url, allowLoopback: url.host.map(ScopedHTTP.isLoopback) ?? false,
                                                 timeout: 6, maxBytes: 64 * 1024)
            return classify(status: r.status, location: r.header("location"), body: r.text, base: url)
        } catch let e as ScopedHTTPError {
            switch e {
            case .cancelled: return .cancelled
            case .timedOut: return .offline(String(localized: "逾時"))
            case .dnsFailed: return .offline(String(localized: "找不到主機"))
            case .networkDown: return .offline(String(localized: "未連線"))
            case .refused: return .offline(String(localized: "連不上主機"))
            case .badResponse, .incomplete, .tooLarge: return .inconclusive(String(localized: "回應格式不對"))
            case .invalidURL, .loopbackBlocked: return .inconclusive(String(localized: "檢查網址不對"))
            case .other(let why): return .offline(why)
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .offline(error.localizedDescription)
        }
    }

    /// 綁介面檢查的結果是不是「可能只是走不到」：逾時、連不上、查不到主機（被擋成「未連線」的不算）
    static func needsSystemRouteCheck(_ r: CaptiveProbeResult) -> Bool {
        guard case .offline(let why) = r else { return false }
        return why != String(localized: "未連線")
    }

    /// 合併兩種檢查（純函式）：系統路線通了就算有網路／被攔；系統路線也不通就維持原本的結果。
    static func combine(scoped: CaptiveProbeResult, system: CaptiveProbeResult) -> CaptiveProbeResult {
        switch system {
        case .online, .captive: return system
        default: return scoped
        }
    }

    nonisolated private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let systemSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 8
        c.waitsForConnectivity = false
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    /// 系統一般路線（URLSession，會套用代理伺服器設定）
    static func checkSystemRoute(_ url: URL) async -> CaptiveProbeResult {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
        req.setValue(ScopedHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await systemSession.data(for: req, delegate: NoRedirect())
            guard let http = resp as? HTTPURLResponse else { return .offline(String(localized: "回應格式不對")) }
            return classify(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"),
                            body: String(decoding: data.prefix(64 * 1024), as: UTF8.self), base: url)
        } catch let e as URLError where e.code == .cancelled {
            return .cancelled
        } catch {
            return .offline(error.localizedDescription)
        }
    }

    /// 純函式，方便測試。只有「明確被攔」的證據才回 captive，伺服器故障回 inconclusive。
    static func classify(status: Int, location: String?, body: String, base: URL) -> CaptiveProbeResult {
        if status == 204 {
            // 只有 generate_204 這類端點的 204 才代表正常
            return base.path.contains("generate_204") ? .online : .inconclusive(String(localized: "檢查網址回 204"))
        }
        if (200..<300).contains(status) {
            let compact = body.replacingOccurrences(of: "\\s", with: "", options: .regularExpression).lowercased()
            if compact.count < 300, compact.contains("<body>success</body>") || compact == "success" { return .online }
            return .captive(findClientRedirect(in: body, base: base))
        }
        if [301, 302, 303, 307, 308].contains(status) {
            if let loc = location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty,
               let u = URL(string: loc, relativeTo: base)?.absoluteURL,
               let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil {
                return .captive(u)
            }
            return .inconclusive(String(localized: "轉址網址無效（\(status)）"))
        }
        if status == 511 { return .captive(findClientRedirect(in: body, base: base)) }
        // 401、403、407、5xx…：頁面裡有轉址才當成登入頁，否則是伺服器的問題
        if let u = findClientRedirect(in: body, base: base) { return .captive(u) }
        return .inconclusive(String(localized: "伺服器回應 \(status)"))
    }

    /// 找 <meta http-equiv="refresh" content="0;url=..."> 或 location.href='...' 之類的轉址。
    static func findClientRedirect(in body: String, base: URL) -> URL? {
        let patterns = [
            #"(?i)<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["'][^"']*?url\s*=\s*([^"'>\s]+)"#,
            #"(?i)(?:window\.|document\.)?location(?:\.href)?\s*=\s*["']([^"']+)["']"#,
            #"(?i)location\.replace\(\s*["']([^"']+)["']"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(body.startIndex..., in: body)
            if let m = re.firstMatch(in: body, range: range), m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: body) {
                let s = String(body[r]).replacingOccurrences(of: "&amp;", with: "&")
                if let u = URL(string: s, relativeTo: base)?.absoluteURL, u.scheme?.hasPrefix("http") == true { return u }
            }
        }
        return nil
    }
}
