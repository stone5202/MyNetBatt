import AppKit

// MARK: - 抹黑劉海
/// 以目前的桌布產生一張上緣塗黑（選單列高度）的新桌布並套用，讓劉海和選單列融成一整條黑色。
/// macOS 的桌布是「每個螢幕、每個桌面空間」各自設定，App 只能讀寫目前桌面空間的桌布。
/// 所以每一張產生的桌布都各自記住它取代的原桌布與縮放方式：不同桌面空間各套用一次後，
/// 還原時依目前這張產生圖找回它自己的原桌布；清理時也只刪除這次被取代的那一張。

/// 被取代的原桌布與它的縮放方式。
nonisolated struct NotchOriginal: Codable, Equatable {
    var path: String
    var scaling: Int?
    var allowClipping: Bool?
}

/// 讀寫桌布的介面；實際使用 NSWorkspace，測試時換成假的桌面。
@MainActor
protocol DesktopPictureAccess {
    func currentImage(screen: String) -> URL?
    func currentOriginal(screen: String) -> NotchOriginal?
    func setImage(_ url: URL, screen: String, scaling: Int?, allowClipping: Bool?) throws
}

@MainActor
final class NotchWallpaperEngine {
    static let mapKey = "notchWallpaperMap"

    let folder: URL
    let defaults: UserDefaults
    let desktop: DesktopPictureAccess
    /// 讀取原桌布並產生上緣塗黑的圖（JPEG）；讀不到時回傳 nil。
    let render: (_ source: URL, _ pixelSize: CGSize, _ barHeight: CGFloat) -> Data?

    init(folder: URL, defaults: UserDefaults, desktop: DesktopPictureAccess,
         render: @escaping (_ source: URL, _ pixelSize: CGSize, _ barHeight: CGFloat) -> Data?) {
        self.folder = folder
        self.defaults = defaults
        self.desktop = desktop
        self.render = render
    }

    struct Target {
        let screen: String
        let pixelSize: CGSize
        let barHeight: CGFloat
    }

    /// 產生圖的檔名 → 它取代的原桌布。
    var map: [String: NotchOriginal] {
        get {
            guard let data = defaults.data(forKey: Self.mapKey),
                  let decoded = try? JSONDecoder().decode([String: NotchOriginal].self, from: data) else { return [:] }
            return decoded
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.mapKey) }
    }

    func isGenerated(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    func isApplied(screens: [String]) -> Bool {
        screens.contains { desktop.currentImage(screen: $0).map(isGenerated) ?? false }
    }

    /// 回傳錯誤訊息；成功時為 nil。
    func apply(_ targets: [Target]) -> String? {
        guard !targets.isEmpty else { return String(localized: "找不到螢幕。") }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        var entries = map
        defer { map = entries }
        for target in targets {
            guard let current = desktop.currentImage(screen: target.screen) else {
                return String(localized: "讀不到目前的桌布。")
            }
            // 已經套用過時，以這張產生圖記下的原桌布重新產生（例如解析度改變後），原桌布仍是同一張。
            let replacingGenerated = isGenerated(current)
            let original: NotchOriginal
            if replacingGenerated {
                guard let saved = entries[current.lastPathComponent] else {
                    return String(localized: "找不到原本的桌布檔案，請到「系統設定 › 桌布」重新選擇。")
                }
                original = saved
            } else {
                original = desktop.currentOriginal(screen: target.screen) ?? NotchOriginal(path: current.path)
            }
            guard let data = render(URL(fileURLWithPath: original.path), target.pixelSize, target.barHeight) else {
                return String(localized: "目前的桌布是動態或影片桌布，無法轉換。請先在「系統設定 › 桌布」換成一般圖片。")
            }
            // 檔名要每次不同，系統才不會沿用快取的舊圖。
            let name = "\(target.screen)-\(UUID().uuidString.prefix(8)).jpg"
            let url = folder.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
                try desktop.setImage(url, screen: target.screen, scaling: Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue), allowClipping: true)
            } catch {
                try? FileManager.default.removeItem(at: url)
                return error.localizedDescription
            }
            entries[name] = original
            // 只刪這次被取代的那一張；其他桌面空間仍在用的產生圖不動。
            if replacingGenerated {
                entries[current.lastPathComponent] = nil
                try? FileManager.default.removeItem(at: current)
            }
        }
        return nil
    }

    /// 換回目前桌面空間的原桌布；原始檔案已經不存在時保留目前的桌布並回報。
    func restore(screens: [String]) -> String? {
        var entries = map
        var missing = false
        defer { map = entries }
        for screen in screens {
            guard let current = desktop.currentImage(screen: screen), isGenerated(current) else { continue }
            guard let original = entries[current.lastPathComponent],
                  FileManager.default.fileExists(atPath: original.path) else {
                missing = true
                continue
            }
            do {
                try desktop.setImage(URL(fileURLWithPath: original.path), screen: screen, scaling: original.scaling, allowClipping: original.allowClipping)
            } catch {
                return error.localizedDescription
            }
            entries[current.lastPathComponent] = nil
            try? FileManager.default.removeItem(at: current)
        }
        return missing ? String(localized: "找不到原本的桌布檔案，請到「系統設定 › 桌布」重新選擇。") : nil
    }
}

/// 實際的桌面：以螢幕編號對應 NSScreen，透過 NSWorkspace 讀寫桌布。
@MainActor
struct WorkspaceDesktop: DesktopPictureAccess {
    static func key(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display-\(number.uint32Value)"
        }
        return screen.localizedName.replacingOccurrences(of: "/", with: "-")
    }

    private func screen(_ key: String) -> NSScreen? {
        NSScreen.screens.first { Self.key(for: $0) == key }
    }

    func currentImage(screen key: String) -> URL? {
        screen(key).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    func currentOriginal(screen key: String) -> NotchOriginal? {
        guard let screen = screen(key), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        return NotchOriginal(
            path: url.path,
            scaling: (options[.imageScaling] as? NSNumber)?.intValue,
            allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue
        )
    }

    func setImage(_ url: URL, screen key: String, scaling: Int?, allowClipping: Bool?) throws {
        guard let screen = screen(key) else { return }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling { options[.imageScaling] = NSNumber(value: scaling) }
        if let allowClipping { options[.allowClipping] = NSNumber(value: allowClipping) }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }
}

@MainActor
enum NotchWallpaper {
    /// 產生的桌布放在 Application Support。
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyNetBatt/Wallpapers", isDirectory: true)
    }

    /// 有劉海的螢幕；沒有時（外接螢幕、舊機型）也允許套用到主螢幕，選單列一樣會變成全黑。
    static var notchScreens: [NSScreen] { NSScreen.screens.filter { $0.safeAreaInsets.top > 0 } }

    static var hasNotch: Bool { !notchScreens.isEmpty }

    private static var targetScreens: [NSScreen] {
        let screens = notchScreens
        if !screens.isEmpty { return screens }
        return NSScreen.main.map { [$0] } ?? []
    }

    private static var engine: NotchWallpaperEngine {
        NotchWallpaperEngine(folder: folder, defaults: .standard, desktop: WorkspaceDesktop()) { source, size, bar in
            loadImage(source).flatMap { render($0, pixelSize: size, barHeight: bar) }
        }
    }

    /// 目前桌面空間的桌布是否是這個功能產生的。
    static var isApplied: Bool { engine.isApplied(screens: targetScreens.map(WorkspaceDesktop.key)) }

    static func apply() -> String? {
        engine.apply(targetScreens.map { screen in
            let scale = screen.backingScaleFactor
            return NotchWallpaperEngine.Target(
                screen: WorkspaceDesktop.key(for: screen),
                pixelSize: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale),
                barHeight: menuBarHeight(for: screen) * scale
            )
        })
    }

    static func restore() -> String? {
        engine.restore(screens: targetScreens.map(WorkspaceDesktop.key))
    }

    /// 選單列高度：有劉海的螢幕以安全區域為準，其餘以可見範圍推算，選單列自動隱藏時用標準高度。
    private static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height > 0 ? height : NSStatusBar.system.thickness
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 等比例填滿螢幕（超出的部分裁掉，和系統「填滿螢幕」相同），再把上緣塗黑。
    static func render(_ image: CGImage, pixelSize: CGSize, barHeight: CGFloat) -> Data? {
        let width = Int(pixelSize.width.rounded()), height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        let imageSize = CGSize(width: image.width, height: image.height)
        let fill = max(pixelSize.width / imageSize.width, pixelSize.height / imageSize.height)
        let drawn = CGSize(width: imageSize.width * fill, height: imageSize.height * fill)
        context.draw(image, in: CGRect(
            x: (pixelSize.width - drawn.width) / 2, y: (pixelSize.height - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        ))
        // CGContext 的原點在左下角，選單列在最上方。多塗 1 像素，避免縮放後露出一條亮線。
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: pixelSize.height - barHeight - 1, width: pixelSize.width, height: barHeight + 1))
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    }
}
