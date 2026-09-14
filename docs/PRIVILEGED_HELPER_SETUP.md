# MyNetBatt 第一階段：Privileged Helper + 低耗電模式控制

這一階段把低耗電模式控制從 `AppleScript / osascript / sudo` 改成 macOS 13+ 的 `SMAppService + LaunchDaemon + NSXPCConnection` 架構。

## Bundle Identifier

```text
主 App:      com.stone5202.MyNetBatt
Helper:      com.stone5202.MyNetBatt.PrivilegedHelper
Mach Service: com.stone5202.MyNetBatt.PrivilegedHelper
```

這些識別碼已同步到 Xcode project、XPC code-signing requirement 與 LaunchDaemon plist。

## project.pbxproj 已經配置完成

`feature/privileged-helper-low-power` 分支的 `MyNetBatt/MyNetBatt.xcodeproj/project.pbxproj` 已經直接加入以下設定，不需要再手動 File → New → Target：

- `MyNetBattPrivilegedHelper` Command Line Tool Target
- Helper Product `MyNetBattPrivilegedHelper`
- Helper source group `PrivilegedHelper`
- Helper Debug / Release Build Configuration
- Helper Bundle Identifier `com.stone5202.MyNetBatt.PrivilegedHelper`
- Helper entitlements `PrivilegedHelper/MyNetBattPrivilegedHelper.entitlements`
- macOS-only SDK / supported platform
- 主 App → Helper Target Dependency
- `Embed Privileged Helper` Copy Files phase
  - Destination: Wrapper
  - Subpath: `Contents/MacOS`
  - Code Sign On Copy: enabled
- `Embed LaunchDaemon` Copy Files phase
  - Destination: Wrapper
  - Subpath: `Contents/Library/LaunchDaemons`
- 主 App entitlements `MyNetBatt/MyNetBatt.entitlements`
- 主 App `ENABLE_APP_SANDBOX = NO`

Build 後預期 App bundle 結構：

```text
MyNetBatt.app/
└── Contents/
    ├── MacOS/
    │   ├── MyNetBatt
    │   └── MyNetBattPrivilegedHelper
    └── Library/
        └── LaunchDaemons/
            └── com.stone5202.MyNetBatt.PrivilegedHelper.plist
```

## Repository 內的 Helper 檔案

主 App：

```text
MyNetBatt/MyNetBatt/PrivilegedHelperProtocol.swift
MyNetBatt/MyNetBatt/PrivilegedHelperManager.swift
MyNetBatt/MyNetBatt/MyNetBatt.entitlements
```

Helper：

```text
MyNetBatt/PrivilegedHelper/main.swift
MyNetBatt/PrivilegedHelper/HelperProtocol.swift
MyNetBatt/PrivilegedHelper/HelperService.swift
MyNetBatt/PrivilegedHelper/MyNetBattPrivilegedHelper.entitlements
```

LaunchDaemon：

```text
MyNetBatt/LaunchDaemons/com.stone5202.MyNetBatt.PrivilegedHelper.plist
```

## 你仍需要在 Xcode 確認的項目

因為 Development Team 屬於你的 Apple Developer 帳號資訊，Repository 沒有硬編碼 Team ID。Pull 分支後請在 Xcode 確認：

1. 選 `MyNetBatt` Target → Signing & Capabilities。
2. Team 選擇你自己的 Apple Development Team。
3. 選 `MyNetBattPrivilegedHelper` Target → Signing & Capabilities / Build Settings。
4. Helper 也使用同一個 Team。
5. 確認主 App Bundle Identifier 為 `com.stone5202.MyNetBatt`。
6. 確認 Helper Bundle Identifier 為 `com.stone5202.MyNetBatt.PrivilegedHelper`。

主 App 與 Helper 必須使用相容的 Apple Development 簽章，因為 XPC 會驗證 signing identifier。

## 建議第一次測試

先執行：

```text
Product → Clean Build Folder
```

然後 Run MyNetBatt。

進入：

```text
控制中心 → 電池與電源狀態
```

右上角低耗電模式區域會根據 Helper 狀態顯示：

```text
尚未啟用控制
等待系統核准
已開啟
已關閉
```

第一次按「啟用控制」時，App 會使用：

```swift
SMAppService.daemon(
    plistName: "com.stone5202.MyNetBatt.PrivilegedHelper.plist"
).register()
```

若 macOS 回報 `requiresApproval`，請到：

```text
系統設定 → 一般 → 登入項目與延伸功能
```

允許 MyNetBatt 的背景項目，再回到 App 按重新檢查。

## 實際資料流

```text
BatteryDetailView
    ↓
PrivilegedHelperManager
    ↓
SMAppService
    ↓
LaunchDaemon
    ↓
NSXPCConnection(options: .privileged)
    ↓
MyNetBattPrivilegedHelper
    ↓
/usr/bin/pmset -a lowpowermode 1 / 0
```

讀取低耗電模式則使用：

```text
pmset -g batt
pmset -g custom
```

## 安全設計

Helper 不接受任意 command、path 或 arguments。XPC protocol 只暴露：

```swift
getLowPowerMode(...)
setLowPowerMode(_:...)
```

主 App 要求 Helper signing identifier：

```text
com.stone5202.MyNetBatt.PrivilegedHelper
```

Helper 要求主 App signing identifier：

```text
com.stone5202.MyNetBatt
```

LaunchDaemon `AssociatedBundleIdentifiers`：

```text
com.stone5202.MyNetBatt
```

## 如果 Build 失敗

先檢查：

- Xcode 左側 TARGETS 是否同時看到 `MyNetBatt` 與 `MyNetBattPrivilegedHelper`
- 主 App Build Phases 是否有 `MyNetBattPrivilegedHelper` Target Dependency
- 主 App Build Phases 是否有 `Embed Privileged Helper`
- 主 App Build Phases 是否有 `Embed LaunchDaemon`
- App Sandbox 是否為關閉狀態
- App 與 Helper 是否選擇同一個 Development Team

可用 Terminal 檢查簽章：

```bash
codesign -dv --verbose=4 /path/to/MyNetBatt.app
codesign -dv --verbose=4 /path/to/MyNetBatt.app/Contents/MacOS/MyNetBattPrivilegedHelper
```

## Phase 1 完成標準

- Xcode 內有兩個 Target
- App Bundle Identifier = `com.stone5202.MyNetBatt`
- Helper Bundle Identifier = `com.stone5202.MyNetBatt.PrivilegedHelper`
- App bundle 內有 Helper executable
- App bundle 內有 LaunchDaemon plist
- `SMAppService` 狀態為 enabled
- XPC 可以讀取低耗電模式
- Toggle 可以真正修改 macOS 低耗電模式
- 不需要 AppleScript
- 不需要 `sudo`
