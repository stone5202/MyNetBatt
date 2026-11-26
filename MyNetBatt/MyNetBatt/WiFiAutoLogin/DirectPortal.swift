// 共用核心（見 CaptiveModels.swift 開頭說明）
import Foundation

/// 不開網頁，直接讀登入頁、找出同意按鈕、送出表單。
///
/// macOS 跳出系統登入視窗時，WKWebView 的連線也會被擋，只有綁 Wi‑Fi 介面的連線能通（見 ScopedHTTP）。
/// 這裡只處理「按一下同意就好」而且每一步都看得懂的登入頁（例如 FortiGate 的使用條款頁）；
/// 有任何看不懂或有歧義的地方（不認得的按鈕程式、必填欄位、付費選項…）就不送，回 nil 交給原本的網頁方式。
nonisolated enum DirectPortal {

    struct Submission: Equatable, Sendable {
        let url: URL
        let method: String            // GET／POST
        let fields: [Field]
        let buttonText: String

        struct Field: Equatable, Sendable {
            let name: String
            let value: String
        }

        var encodedFields: String {
            fields.map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&")
        }
    }

    enum Plan: Equatable, Sendable {
        case submit(Submission)
        case needsInput(String)
        case unsupported(String)      // 交給網頁方式
    }

    // MARK: - 打分（和 PortalScript 的 POS／HARD_NEG 同一套字詞）

    static let positive: [(String, Int)] = [
        ("同意並連線", 14), ("同意並上網", 14), ("我同意", 12), ("同意", 10), ("接受", 9), ("開始上網", 12), ("免費上網", 11),
        ("立即上網", 11), ("馬上上網", 11), ("我要上網", 11), ("上網", 7), ("連線", 8), ("連接", 7), ("確認", 8), ("確定", 8),
        ("登入", 6), ("進入", 5), ("繼續", 5), ("下一步", 5), ("送出", 4), ("提交", 4),
        ("i agree", 12), ("agree", 10), ("accept", 9), ("connect", 8), ("get online", 10), ("go online", 10), ("confirm", 8),
        ("login", 6), ("log in", 6), ("sign in", 5), ("continue", 5), ("proceed", 5), ("browse", 5), ("submit", 4), ("start", 4),
        ("ok", 4), ("next", 3), ("enter", 3), ("go", 2),
    ]
    static let hardNegative = ["不同意", "不接受", "不要", "不用", "拒絕", "取消", "登出", "返回", "付費", "收費", "付款", "購買", "儲值", "加值", "升級", "訂閱", "元", "nt$", "$",
                               "decline", "disagree", "reject", "cancel", "logout", "log out", "sign out", "back", "pay", "purchase", "buy", "upgrade", "subscribe", "premium", "paid"]
    /// 勾選方塊：看起來是同意條款才勾
    static let agreePattern = "同意|接受|閱讀|已讀|知悉|了解|瞭解|遵守|條款|規範|agree|accept|consent|terms"
    /// 勾選方塊：這些字出現就絕不勾（付費、加購、行銷…）
    static let checkboxNegative = "不同意|不接受|付費|收費|付款|購買|加購|加值|儲值|升級|訂閱|電子報|行銷|廣告|優惠|第三方|合作夥伴|提供.{0,6}(個人|個資)|分享|記住|元|\\$|nt\\$|pay|paid|purchase|buy|upgrade|premium|subscribe|newsletter|marketing|advert|partner|third.party|share|remember"

    /// 英文字要整個字比對（"go" 不能比到 "google"），中文直接包含。
    static func score(_ text: String) -> Int {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 40 else { return 0 }
        if hardNegative.contains(where: { contains(t, $0) }) { return -100 }
        return positive.filter { contains(t, $0.0) }.map(\.1).max() ?? 0
    }

    private static func contains(_ text: String, _ word: String) -> Bool {
        if word.unicodeScalars.allSatisfy({ $0.isASCII }) && word.first?.isLetter == true {
            let p = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: word) + "(?![a-z])"
            return text.range(of: p, options: .regularExpression) != nil
        }
        return text.contains(word)
    }

    // MARK: - 解析登入頁（純函式，方便測試）

    /// 解析的頁面最多看這麼多字（避免異常頁面拖慢）
    static let maxParseLength = 256 * 1024

    static func plan(html rawHTML: String, pageURL: URL) -> Plan {
        // 註解裡的標記不算數
        let html = String(rawHTML.prefix(maxParseLength))
            .replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
        let forms = matches(#"(?is)<form\b([^>]*)>(.*?)</form>"#, in: html)
        guard !forms.isEmpty else { return .unsupported(String(localized: "頁面沒有表單")) }
        let scripts = matches(#"(?is)<script\b[^>]*>(.*?)</script>"#, in: html).map { $0[1] }.joined(separator: "\n")
        // <label for="id">文字</label>
        var labelFor: [String: String] = [:]
        for m in matches(#"(?is)<label\b([^>]*)>(.*?)</label>"#, in: html) {
            if let f = attributes(m[1])["for"], !f.isEmpty { labelFor[f, default: ""] += " " + plainText(m[2]) }
        }

        var best: (score: Int, plan: Plan)?
        var needs: String?
        formLoop: for f in forms {
            let attrs = attributes(f[1]), inner = f[2]
            // 表單外用 form="id" 掛進來的欄位看不到，整個表單交回網頁方式
            if let id = attrs["id"], !id.isEmpty,
               html.range(of: #"(?i)\bform\s*=\s*["']?"# + NSRegularExpression.escapedPattern(for: id) + #"["'\s>]"#, options: .regularExpression) != nil {
                continue
            }
            var fields: [Submission.Field] = []

            // 有密碼欄：要使用者自己登入（先看，不管它排在帳號欄前面還是後面）
            if matches(#"(?is)<input\b([^>]*)>"#, in: inner).contains(where: { (attributes($0[1])["type"] ?? "").lowercased() == "password" }) {
                needs = String(localized: "密碼")
                continue
            }

            // 一般欄位
            for m in matches(#"(?is)<input\b([^>]*)>"#, in: inner) {
                let a = attributes(m[1])
                if a["disabled"] != nil { continue }
                let type = (a["type"] ?? "text").lowercased()
                let name = a["name"] ?? ""
                switch type {
                case "hidden":
                    if !name.isEmpty { fields.append(.init(name: name, value: a["value"] ?? "")) }
                case "password":
                    needs = String(localized: "密碼")
                    continue formLoop
                case "checkbox", "radio", "submit", "button", "image", "reset":
                    break
                default:
                    continue formLoop   // 要填東西（帳號、手機、檔案…）：交給網頁方式或使用者
                }
            }
            if inner.range(of: #"(?i)<textarea\b"#, options: .regularExpression) != nil { continue }
            for m in matches(#"(?is)<select\b([^>]*)>(.*?)</select>"#, in: inner) {
                let a = attributes(m[1])
                guard a["disabled"] == nil, let name = a["name"], !name.isEmpty else { continue }
                if a["required"] != nil { continue formLoop }      // 必填的選單要使用者自己選
                let options = matches(#"(?is)<option\b([^>]*)>(.*?)</option>"#, in: m[2])
                guard let opt = options.first(where: { attributes($0[1])["selected"] != nil }) ?? options.first else { continue }
                fields.append(.init(name: name, value: attributes(opt[1])["value"] ?? plainText(opt[2])))
            }

            // 勾選方塊：讀完整的標籤文字；同意條款才勾，付費／行銷之類絕不勾；看不懂又必填就不送
            for m in matches(#"(?is)<input\b([^>]*)>"#, in: inner) {
                let a = attributes(m[1])
                guard (a["type"] ?? "").lowercased() == "checkbox", a["disabled"] == nil else { continue }
                let name = a["name"] ?? ""
                var label = [name, a["id"] ?? "", a["value"] ?? "", a["aria-label"] ?? "", a["title"] ?? ""].joined(separator: " ")
                if let id = a["id"], let t = labelFor[id] { label += " " + t }
                if let wrap = wrappingLabel(of: m[0], in: inner) { label += " " + wrap }
                label += " " + plainText(textAfter(m[0], in: inner, limit: 120))
                let l = label.lowercased()
                let negative = l.range(of: checkboxNegative, options: .regularExpression) != nil
                let agree = l.range(of: agreePattern, options: .regularExpression) != nil
                let preChecked = a["checked"] != nil
                if negative {
                    if preChecked || a["required"] != nil { continue formLoop }   // 預先勾好或必勾的付費／行銷項目：交給使用者
                    continue
                }
                if agree || preChecked {
                    guard !name.isEmpty else { if a["required"] != nil { continue formLoop }; continue }
                    fields.append(.init(name: name, value: a["value"] ?? "on"))
                } else if a["required"] != nil {
                    continue formLoop
                }
            }

            // 候選按鈕（停用、隱藏的不算）
            var candidates: [(text: String, attrs: [String: String], isButtonTag: Bool)] = []
            for m in matches(#"(?is)<button\b([^>]*)>(.*?)</button>"#, in: inner) {
                candidates.append((plainText(m[2]), attributes(m[1]), true))
            }
            for m in matches(#"(?is)<input\b([^>]*)>"#, in: inner) {
                let a = attributes(m[1])
                let type = (a["type"] ?? "").lowercased()
                if type == "submit" || type == "button" || type == "image" {
                    candidates.append((a["value"] ?? a["alt"] ?? "", a, false))
                }
            }
            candidates = candidates.filter { !isHiddenOrDisabled($0.attrs) }
            let scored = candidates.map { ($0, score($0.text)) }.filter { $0.1 > 0 }
            guard let pick = scored.max(by: { $0.1 < $1.1 }) else { continue }
            let (btn, s) = pick

            // 按鈕按下去會做什麼：只接受看得懂的
            var final = fields
            let type = (btn.attrs["type"] ?? (btn.isButtonTag ? "submit" : "")).lowercased()
            let nativeSubmit = type == "submit" || type == "image"
            if let onclick = btn.attrs["onclick"], !onclick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let sets = simulateOnclick(onclick, scripts: scripts, nativeSubmit: nativeSubmit) else { continue }
                for (k, v) in sets {
                    if let i = final.firstIndex(where: { $0.name == k }) { final[i] = .init(name: k, value: v) }
                    else { final.append(.init(name: k, value: v)) }
                }
            } else if !nativeSubmit {
                continue        // type=button 又沒有 onclick：瀏覽器按了也不會送出
            }
            if nativeSubmit, let n = btn.attrs["name"], !n.isEmpty {
                final.append(.init(name: n, value: btn.attrs["value"] ?? ""))
            }

            // 送到哪裡：協定、主機、連接埠都要和登入頁一樣
            let actionText = btn.attrs["formaction"] ?? attrs["action"] ?? ""
            guard let action = actionText.isEmpty ? pageURL : URL(string: actionText, relativeTo: pageURL)?.absoluteURL,
                  sameOrigin(action, pageURL) else { continue }
            let methodText = btn.attrs["formmethod"] ?? attrs["method"] ?? "get"
            let method = methodText.uppercased() == "POST" ? "POST" : "GET"
            let sub = Submission(url: action, method: method, fields: final, buttonText: btn.text)
            if best == nil || s > best!.score { best = (s, .submit(sub)) }
        }
        if let best { return best.plan }
        if let needs { return .needsInput(needs) }
        return .unsupported(String(localized: "看不懂這個登入頁"))
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let sa = a.scheme?.lowercased(), let sb = b.scheme?.lowercased(), sa == sb,
              let ha = a.host?.lowercased(), let hb = b.host?.lowercased(), ha == hb,
              let pa = ScopedHTTP.effectivePort(a), let pb = ScopedHTTP.effectivePort(b), pa == pb else { return false }
        return true
    }

    static func isHiddenOrDisabled(_ a: [String: String]) -> Bool {
        if a["disabled"] != nil || a["hidden"] != nil || (a["aria-hidden"] ?? "").lowercased() == "true" { return true }
        let style = (a["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        return style.contains("display:none") || style.contains("visibility:hidden")
    }

    private static func wrappingLabel(of tag: String, in html: String) -> String? {
        for m in matches(#"(?is)<label\b[^>]*>(.*?)</label>"#, in: html) where m[1].contains(tag) {
            return plainText(m[1])
        }
        return nil
    }

    private static func textAfter(_ tag: String, in html: String, limit: Int) -> String {
        guard let r = html.range(of: tag) else { return "" }
        let rest = html[r.upperBound...]
        // 到下一個欄位為止
        let stop = rest.range(of: #"(?i)<(input|button|select|textarea|form)\b"#, options: .regularExpression)?.lowerBound ?? rest.endIndex
        return String(rest[..<stop].prefix(limit))
    }

    /// 模擬簡單的 onclick（每一句都要看得懂，否則回 nil）：
    /// - `sb('1')` 搭配 `function sb(v){ document.forms[0].answer.value = v; document.forms[0].submit(); }`
    /// - `this.form.answer.value='1'; this.form.submit()`、`return true`
    /// nativeSubmit：按鈕本身會送出（type=submit）；不是的話一定要看到 submit() 才算。回傳要改的欄位。
    static func simulateOnclick(_ onclick: String, scripts: String, nativeSubmit: Bool) -> [(String, String)]? {
        var sets: [(String, String)] = []
        var submitted = false, cancelsNative = false
        guard run(statements(of: onclick), param: nil, arg: nil, scripts: scripts, depth: 0,
                  sets: &sets, submitted: &submitted, cancelsNative: &cancelsNative) else { return nil }
        if nativeSubmit {
            if cancelsNative && !submitted { return nil }
        } else if !submitted {
            return nil
        }
        return sets
    }

    private static func statements(of js: String) -> [String] {
        js.components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let fieldRef = #"(?:this\.form|document\.forms\[\s*\d+\s*\]|document\.forms\.[A-Za-z_$][\w$]*|document\.getElementById\(\s*['"][^'"]+['"]\s*\)|[A-Za-z_$][\w$]*)"#

    private static func run(_ stmts: [String], param: String?, arg: String?, scripts: String, depth: Int,
                            sets: inout [(String, String)], submitted: inout Bool, cancelsNative: inout Bool) -> Bool {
        guard depth < 3 else { return false }
        for st in stmts {
            if st.range(of: "^" + fieldRef + #"\.submit\(\s*\)$"#, options: .regularExpression) != nil { submitted = true; continue }
            if st.range(of: #"^return\s+true$"#, options: .regularExpression) != nil { continue }
            if st.range(of: #"^return\s+false$"#, options: .regularExpression) != nil { cancelsNative = true; continue }
            // 欄位指定：X.answer.value = 'v' ／ = param ／ X['answer'].value = ／ getElementsByName('answer')[0].value =
            let target = #"^(?:"# + fieldRef + #"\.([A-Za-z_$][\w$]*)|"# + fieldRef + #"\[\s*['"]([^'"]+)['"]\s*\]|document\.getElementsByName\(\s*['"]([^'"]+)['"]\s*\)\[\s*0\s*\])\.value\s*=\s*(.+)$"#
            if let m = matches(target, in: st).first {
                guard let name = [m[1], m[2], m[3]].first(where: { !$0.isEmpty }) else { return false }
                let rhs = m[4].trimmingCharacters(in: .whitespaces)
                if let lit = matches(#"^(['"])(.*)\1$"#, in: rhs).first { sets.append((name, lit[2])) }
                else if let param, rhs == param, let arg { sets.append((name, arg)) }
                else { return false }
                continue
            }
            // 呼叫頁面上的函式：fn('1') 或 fn()
            if let call = matches(#"^(?:return\s+)?([A-Za-z_$][\w$]*)\s*\(\s*(?:(['"])(.*?)\2)?\s*\)$"#, in: st).first {
                let fn = call[1]
                guard let def = matches(#"(?s)function\s+"# + NSRegularExpression.escapedPattern(for: fn) + #"\s*\(\s*([A-Za-z_$][\w$]*)?\s*\)\s*\{(.*?)\}"#, in: scripts).first else { return false }
                let p = def[1].isEmpty ? nil : def[1]
                guard run(statements(of: def[2]), param: p, arg: call[2].isEmpty ? nil : call[3], scripts: scripts, depth: depth + 1,
                          sets: &sets, submitted: &submitted, cancelsNative: &cancelsNative) else { return false }
                continue
            }
            return false   // 看不懂的一句
        }
        return true
    }

    // MARK: - 實際執行

    /// 讀登入頁 → 送出表單 → 確認連網。整次最多 deadline 秒。
    /// 回 nil：沒有送出任何東西（看不懂或讀不到），可以交給網頁方式。
    /// 一旦送出了（即使沒收到回應），就不回 nil，避免網頁方式再按一次。
    @MainActor
    static func run(startURL: URL, probeURL: URL, shouldContinue: @escaping () -> Bool,
                    log: (String) -> Void, deadline seconds: TimeInterval = 40) async -> AgentOutcome? {
        let deadline = Date().addingTimeInterval(seconds)
        func remaining(_ cap: TimeInterval) -> TimeInterval { max(0.5, min(cap, deadline.timeIntervalSinceNow)) }
        // 只有連網檢查網址本身是本機（測試）時才允許連本機；正式環境被轉到 127.0.0.1 一律拒絕
        let allowLoopback = probeURL.host.map(ScopedHTTP.isLoopback) ?? false
        var cookies: [String: String] = [:]
        func keepCookies(_ r: ScopedHTTPResponse) {
            for c in r.setCookies {
                let pair = c.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                if let eq = pair.firstIndex(of: "=") {
                    let k = pair[..<eq].trimmingCharacters(in: .whitespaces), v = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !k.isEmpty { cookies[k] = v }
                }
            }
        }

        // 1. 跟著轉址找到真正的登入頁（HTTP 3xx、或只有 window.location 的小頁面）
        var url = startURL
        var page: ScopedHTTPResponse?
        var retries = 0
        for _ in 0..<8 {
            guard Date() < deadline else { log(String(localized: "直接讀登入頁逾時，改用網頁方式")); return nil }
            let r: ScopedHTTPResponse
            do {
                r = try await ScopedHTTP.request(url, cookies: cookies, allowLoopback: allowLoopback, timeout: remaining(8))
            } catch {
                // 剛連上 Wi‑Fi、系統正在切換登入頁狀態時，連線可能短暫不通：等一下重試（最多兩次）
                if retries < 2, let e = error as? ScopedHTTPError, e == .networkDown || e == .timedOut, Date() < deadline {
                    retries += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard shouldContinue() else { return .cancelled }
                    continue
                }
                log(String(localized: "直接讀登入頁失敗（\(String(describing: error))），改用網頁方式"))
                return nil
            }
            keepCookies(r)
            if [301, 302, 303, 307, 308].contains(r.status), let loc = r.header("location"),
               let next = URL(string: loc, relativeTo: url)?.absoluteURL {
                url = next; continue
            }
            if r.body.count < 2048, let next = CaptiveProbe.findClientRedirect(in: r.text, base: url) {
                url = next; continue
            }
            page = r
            break
        }
        guard let page, (200..<300).contains(page.status) else {
            log(String(localized: "直接讀登入頁失敗（\(page.map { "HTTP \($0.status)" } ?? String(localized: "轉址太多次"))），改用網頁方式"))
            return nil
        }
        guard shouldContinue() else { return .cancelled }

        // 2. 找按鈕與要送的欄位（解析不在主執行緒做）
        let html = page.text, pageURL = page.url
        let planned = await Task.detached(priority: .userInitiated) { plan(html: html, pageURL: pageURL) }.value
        let sub: Submission
        switch planned {
        case .needsInput(let f): return .needsInput(f)
        case .unsupported(let why):
            log(String(localized: "直接送出不適用（\(why)），改用網頁方式"))
            return nil
        case .submit(let s): sub = s
        }
        guard shouldContinue(), Date() < deadline else { return .cancelled }

        // 3. 送出
        log(String(localized: "按下「\(sub.buttonText)」"))
        let data = Data(sub.encodedFields.utf8)
        do {
            var r: ScopedHTTPResponse
            if sub.method == "POST" {
                r = try await ScopedHTTP.request(sub.url, method: "POST", body: data, cookies: cookies,
                                                 allowLoopback: allowLoopback, timeout: remaining(10))
            } else {
                var c = URLComponents(url: sub.url, resolvingAgainstBaseURL: true)
                c?.percentEncodedQuery = sub.encodedFields
                guard let u = c?.url else { return nil }
                r = try await ScopedHTTP.request(u, cookies: cookies, allowLoopback: allowLoopback, timeout: remaining(10))
            }
            // 送出後同一個登入頁再轉址一兩次（例如到「登入成功」頁）的話跟過去，其他地方不跟
            for _ in 0..<2 {
                keepCookies(r)
                guard [301, 302, 303, 307, 308].contains(r.status), let loc = r.header("location"),
                      let next = URL(string: loc, relativeTo: r.url)?.absoluteURL, sameOrigin(next, sub.url),
                      Date() < deadline else { break }
                r = try await ScopedHTTP.request(next, cookies: cookies, allowLoopback: allowLoopback, timeout: remaining(8))
            }
        } catch let e as ScopedHTTPError where e.neverSent {
            log(String(localized: "送出同意失敗（\(String(describing: e))），改用網頁方式"))
            return nil
        } catch {
            // 可能已經送到（例如逾時）：不再交給網頁方式重按，繼續確認是否已連網
            log(String(localized: "送出同意後沒有收到回應（\(String(describing: error))）"))
        }

        // 4. 確認連網（防火牆放行通常要一兩秒）；確認後再檢查一次還是同一個網路
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard shouldContinue() else { return .cancelled }
            let ok = await CaptiveProbe.check(probeURL) == .online
            guard shouldContinue() else { return .cancelled }
            if ok { return .success(sub.buttonText) }
        }
        return .failed(String(localized: "已送出同意，但網路還沒恢復"))
    }

    // MARK: - 小工具

    static func matches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    /// 屬性名稱轉小寫，值已做 HTML 字元參照解碼
    static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for m in matches(#"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#, in: s) {
            let k = m[1].lowercased()
            if out[k] == nil { out[k] = decode([m[2], m[3], m[4]].first(where: { !$0.isEmpty }) ?? "") }
        }
        return out
    }

    static func plainText(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decode(noTags).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "middot": "·", "hellip": "…", "ndash": "–", "mdash": "—",
    ]

    /// HTML 字元參照解碼：&amp; &#38; &#x26; 等（只解一次，&amp;lt; 會變成 &lt;）
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let ent = String(s[s.index(after: i)..<semi])
                var rep: String?
                if ent.hasPrefix("#x") || ent.hasPrefix("#X") {
                    rep = UInt32(ent.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if ent.hasPrefix("#") {
                    rep = UInt32(ent.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    rep = namedEntities[ent]
                }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    static func encode(_ s: String) -> String {
        // 只留 ASCII 英數字（中文等一律編碼）
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        return (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: "%20", with: "+")
    }
}
