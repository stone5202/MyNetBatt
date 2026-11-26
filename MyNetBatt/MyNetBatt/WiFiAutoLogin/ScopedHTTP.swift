// 共用核心（見 CaptiveModels.swift 開頭說明）
import Foundation
import Network

/// 綁在 Wi‑Fi 介面上的簡易 HTTP 連線。
///
/// macOS 偵測到登入頁（captive portal）時，會讓一般 App 的連線全部變成「沒有網路路線」
/// （URLSession 得到 -1009、WKWebView 也載不到），只有綁定 Wi‑Fi 介面的連線能通（系統的 captiveagent 也是這樣）。
/// 所以連網檢查與直接送出登入表單都走這裡。
/// 連 127.0.0.1／localhost 只在 allowLoopback（測試用的模擬登入頁）時允許，而且不綁介面。
nonisolated struct ScopedHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]   // 名稱一律小寫；同名的用 ", " 接起來
    let setCookies: [String]        // Set-Cookie 另外保留（值裡可能有逗號）
    let body: Data
    let url: URL

    var text: String { String(decoding: body, as: UTF8.self) }
    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

nonisolated enum ScopedHTTPError: Error, Equatable {
    case networkDown        // 介面沒有網路（被系統擋、Wi‑Fi 正在重連）——連線沒建立
    case dnsFailed          // 連線沒建立
    case refused            // 連線沒建立
    case timedOut           // 可能已經送出（不知道）
    case cancelled
    case badResponse
    case incomplete         // 回應不完整（長度不符、chunked 沒結尾）
    case tooLarge
    case invalidURL
    case loopbackBlocked
    case other(String)

    /// 這個錯誤代表請求一定沒送到伺服器（可以安心改用別的方式重試）
    var neverSent: Bool {
        switch self {
        case .networkDown, .dnsFailed, .refused, .invalidURL, .loopbackBlocked: return true
        default: return false
        }
    }
}

nonisolated enum ScopedHTTP {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "::1" || h == "0.0.0.0" || h.hasPrefix("127.")
    }

    /// 有效連接埠：網址沒寫就用預設；超出 1～65535 回 nil（不能讓網路給的值把 App 弄當）。
    static func effectivePort(_ url: URL) -> Int? {
        let p = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return (1...65535).contains(p) ? p : nil
    }

    /// 送出請求的目標（保持網址原本的百分比編碼，不把 %20 解成空格）
    static func requestTarget(_ url: URL) -> String {
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        if let q = url.query(percentEncoded: true) { path += "?" + q }
        return path
    }

    /// 不跟隨轉址；回應最多讀 maxBytes（超過算失敗）。HTTP/1.0＋Connection: close，
    /// 依 Content-Length／chunked 判斷收完就結束，不必等對方關線。
    static func request(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil,
                        cookies: [String: String] = [:], allowLoopback: Bool = false,
                        timeout: TimeInterval = 6, maxBytes: Int = 512 * 1024) async throws -> ScopedHTTPResponse {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, let port = effectivePort(url),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw ScopedHTTPError.invalidURL }
        let loopback = isLoopback(host)
        if loopback && !allowLoopback { throw ScopedHTTPError.loopbackBlocked }
        let tls = scheme == "https"

        let params: NWParameters = tls ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : .tcp
        if !loopback { params.requiredInterfaceType = .wifi }

        let defaultPort = (tls && port == 443) || (!tls && port == 80)
        var head = "\(method) \(requestTarget(url)) HTTP/1.0\r\n"
        head += "Host: \(host)\(defaultPort ? "" : ":\(port)")\r\n"
        head += "User-Agent: \(userAgent)\r\n"
        head += "Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n"
        if !cookies.isEmpty {
            head += "Cookie: " + cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") + "\r\n"
        }
        if let body {
            head += "Content-Type: \(contentType ?? "application/x-www-form-urlencoded")\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        let payload = Data(head.utf8) + (body ?? Data())
        let headOnly = method == "HEAD"

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let box = ResultBox()
        let queue = DispatchQueue(label: "ScopedHTTP")

        let raw: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                box.set(cont)
                queue.asyncAfter(deadline: .now() + max(0.5, timeout)) {
                    box.finish(.failure(ScopedHTTPError.timedOut)); conn.cancel()
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        conn.send(content: payload, completion: .contentProcessed { err in
                            if let err { box.finish(.failure(map(err))); conn.cancel() }
                        })
                        receive(conn, into: Data(), maxBytes: maxBytes, headOnly: headOnly, box: box)
                    case .waiting(let err):
                        // 跟 URLSession 的 waitsForConnectivity = false 一樣：不等，直接當失敗
                        box.finish(.failure(map(err))); conn.cancel()
                    case .failed(let err):
                        box.finish(.failure(map(err))); conn.cancel()
                    case .cancelled:
                        box.finish(.failure(ScopedHTTPError.cancelled))
                    default: break
                    }
                }
                conn.start(queue: queue)
            }
        } onCancel: {
            box.finish(.failure(ScopedHTTPError.cancelled)); conn.cancel()
        }
        return try parse(raw, url: url, headOnly: headOnly)
    }

    private static func receive(_ conn: NWConnection, into buffer: Data, maxBytes: Int, headOnly: Bool, box: ResultBox) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > maxBytes {
                box.finish(.failure(ScopedHTTPError.tooLarge)); conn.cancel()
            } else if isComplete || isMessageComplete(buf, headOnly: headOnly) {
                box.finish(.success(buf)); conn.cancel()
            } else if let err {
                // 對方直接 RST 收尾：收到的若剛好完整就用，不完整交給 parse 判斷（會回 incomplete）
                box.finish(buf.isEmpty ? .failure(map(err)) : .success(buf)); conn.cancel()
            } else {
                receive(conn, into: buf, maxBytes: maxBytes, headOnly: headOnly, box: box)
            }
        }
    }

    static func map(_ e: NWError) -> ScopedHTTPError {
        switch e {
        case .posix(let code):
            switch code {
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ENOTCONN, .EADDRNOTAVAIL: return .networkDown
            case .ETIMEDOUT: return .timedOut
            case .ECONNREFUSED: return .refused
            case .ECANCELED: return .cancelled
            default: return .other("POSIX \(code.rawValue)")
            }
        case .dns: return .dnsFailed
        case .tls(let s): return .other("TLS \(s)")
        default: return .other("\(e)")
        }
    }

    // MARK: - 解析（純函式，方便測試）

    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// 收到的資料是否已經是一則完整回應（不必等對方關線）。
    static func isMessageComplete(_ raw: Data, headOnly: Bool = false) -> Bool {
        guard let r = raw.range(of: headerEnd), let head = try? parseHead(raw[raw.startIndex..<r.lowerBound]) else { return false }
        if headOnly || head.status == 204 || head.status == 304 || (100..<200).contains(head.status) { return true }
        let body = raw[r.upperBound...]
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true { return dechunk(Data(body)) != nil }
        if let len = head.headers["content-length"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), len >= 0 {
            return body.count >= len
        }
        return false   // 沒有長度：讀到對方關線為止
    }

    private static func parseHead(_ d: Data) throws -> (status: Int, headers: [String: String], cookies: [String]) {
        var lines = String(decoding: d, as: UTF8.self).components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { throw ScopedHTTPError.badResponse }
        var headers: [String: String] = [:]
        var cookies: [String] = []
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = l[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if k == "set-cookie" { cookies.append(v) }
            headers[k] = headers[k].map { $0 + ", " + v } ?? v
        }
        return (status, headers, cookies)
    }

    /// 拆 HTTP 回應。長度對不上、chunked 沒有結尾的一律當不完整（不拿半份頁面去送表單）。
    static func parse(_ raw: Data, url: URL, headOnly: Bool = false) throws -> ScopedHTTPResponse {
        guard let r = raw.range(of: headerEnd) else { throw ScopedHTTPError.incomplete }
        let head = try parseHead(raw[raw.startIndex..<r.lowerBound])
        var body = Data(raw[r.upperBound...])
        if headOnly || head.status == 204 || head.status == 304 {
            body = Data()
        } else if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let d = dechunk(body) else { throw ScopedHTTPError.incomplete }
            body = d
        } else if let lenText = head.headers["content-length"] {
            guard let len = Int(lenText.trimmingCharacters(in: .whitespaces)), len >= 0 else { throw ScopedHTTPError.badResponse }
            guard body.count >= len else { throw ScopedHTTPError.incomplete }
            body = body.prefix(len)
        }
        return ScopedHTTPResponse(status: head.status, headers: head.headers, setCookies: head.cookies, body: body, url: url)
    }

    /// chunked 解碼；資料不完整、長度不合理、沒有結尾的 0 區塊都回 nil。不做可能溢位的加法。
    static func dechunk(_ d: Data) -> Data? {
        var out = Data()
        var i = d.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard i < d.endIndex, let r = d.range(of: crlf, in: i..<d.endIndex) else { return nil }
            let sizeText = String(decoding: d[i..<r.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { return nil }
            if size == 0 { return out }
            let start = r.upperBound
            let remaining = d.distance(from: start, to: d.endIndex)
            guard size <= remaining - 2 else { return nil }      // 區塊本身＋結尾 CRLF 都要在
            let end = d.index(start, offsetBy: size)
            out.append(d[start..<end])
            i = d.index(end, offsetBy: 2)
        }
    }
}

/// 只讓 continuation 被 resume 一次（逾時、取消、完成可能同時發生）。
nonisolated private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Data, Error>?
    private var pending: Result<Data, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let p = pending { pending = nil; lock.unlock(); c.resume(with: p); return }
        cont = c
        lock.unlock()
    }

    func finish(_ r: Result<Data, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        if let c = cont { cont = nil; lock.unlock(); c.resume(with: r); return }
        pending = r          // 還沒拿到 continuation（例如一開始就被取消）：先存著
        lock.unlock()
    }
}
