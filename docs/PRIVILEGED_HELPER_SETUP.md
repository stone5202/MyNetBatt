# MyNetBatt 第一階段：Privileged Helper + 低耗電模式控制

這一階段把低耗電模式控制從 `AppleScript / osascript / sudo` 改成 macOS 13+ 的 `SMAppService + LaunchDaemon + NSXPCConnection` 架構。

## Bundle Identifier 規格

這個分支現在統一使用以下識別碼：

```text
主 App:  com.stone5202.MyNetBatt
Helper:  com.stone5202.MyNetBatt.PrivilegedHelper
Mach Service: com.stone5202.MyNetBatt.PrivilegedHelper
```

這三個值彼此有關聯。之後如果再修改主 App Bundle Identifier，必須同步更新 XPC signing requirement、LaunchDaemon 的 `AssociatedBundleIdentifiers` 與 Helper 設定。

## 為什麼要這樣做

主 App 不應該直接以管理員權限執行任意 shell 指令。MyNetBatt 只向受簽章的 Helper 發送兩種 XPC 請求：

- 讀取低耗電模式
- 設定低耗電模式開 / 關

Helper 以 LaunchDaemon 身分執行，並只呼叫固定路徑 `/usr/bin/pmset`。它不接受任意 command、path 或 arguments，因此權限面積被限制在最小範圍。

## 已加入 Repository 的檔案

### 主 App

- `MyNetBatt/MyNetBatt/PrivilegedHelperProtocol.swift`
- `MyNetBatt/MyNetBatt/PrivilegedHelperManager.swift`
- `MyNetBatt/MyNetBatt/MyNetBatt.entitlements`
- `MyNetBatt/MyNetBatt/BatteryDetailView.swift` 已接上 Helper 控制 UI

### Helper Target 原始碼

- `MyNetBatt/PrivilegedHelper/main.swift`
- `MyNetBatt/PrivilegedHelper/HelperProtocol.swift`
- `MyNetBatt/PrivilegedHelper/HelperService.swift`
- `MyNetBatt/PrivilegedHelper/MyNetBattPrivilegedHelper.entitlements`

### LaunchDaemon

- `MyNetBatt/LaunchDaemons/com.stone5202.MyNetBatt.PrivilegedHelper.plist`

---

# Xcode 設定步驟

Repository 已放好需要的 Swift、plist 與 entitlements。Helper Target 與 Copy Files Build Phase 建議由 Xcode 建立，避免直接手改複雜的 target 結構。

## 1. 確認主 App Bundle Identifier

選：

```text
Project → MyNetBatt Target → Signing & Capabilities
```

確認 Bundle Identifier 為：

```text
com.stone5202.MyNetBatt
```

Repository 的 Debug / Release `PRODUCT_BUNDLE_IDENTIFIER` 都已改成這個值。

## 2. 主 App 關閉 App Sandbox

選：

```text
Project → MyNetBatt Target → Signing & Capabilities
```

把 **App Sandbox** 移除。

接著在 Build Settings 搜尋：

```text
Code Signing Entitlements
```

Debug / Release 都設定成：

```text
MyNetBatt/MyNetBatt.entitlements
```

如果 Xcode 顯示的相對路徑不同，以專案實際位置為準。

## 3. 新增 Command Line Tool Target

在 Xcode：

```text
File → New → Target…
```

選：

```text
macOS → Command Line Tool
```

Product Name：

```text
MyNetBattPrivilegedHelper
```

Language：Swift。Team 與主 App 相同。

建立後，把 Xcode 自動產生的預設 `main.swift` 刪掉，避免和 Repository 內的 Helper `main.swift` 重複。

## 4. 把 Helper 三個 Swift 檔加入 Helper Target

Target Membership 只勾 `MyNetBattPrivilegedHelper`：

```text
MyNetBatt/PrivilegedHelper/main.swift
MyNetBatt/PrivilegedHelper/HelperProtocol.swift
MyNetBatt/PrivilegedHelper/HelperService.swift
```

不要加入主 `MyNetBatt` App Target。

## 5. 設定 Helper Build Settings

選：

```text
MyNetBattPrivilegedHelper Target → Build Settings
```

設定：

```text
Product Name
MyNetBattPrivilegedHelper
```

```text
Product Bundle Identifier
com.stone5202.MyNetBatt.PrivilegedHelper
```

```text
Code Signing Style
Automatic
```

```text
Development Team
與 MyNetBatt 主 App 相同
```

```text
Code Signing Entitlements
PrivilegedHelper/MyNetBattPrivilegedHelper.entitlements
```

搜尋：

```text
Create Info.plist Section in Binary
```

設成 `YES`。

## 6. 加入 Target Dependency

```text
MyNetBatt Target → Build Phases → Target Dependencies
```

加入：

```text
MyNetBattPrivilegedHelper
```

## 7. 把 Helper executable 複製進 App bundle

在主 App Target 的 Build Phases 新增 Copy Files Phase：

```text
Destination: Wrapper
Subpath: Contents/MacOS
```

加入 Product：

```text
MyNetBattPrivilegedHelper
```

**Code Sign On Copy 要勾選。**

Build 後應存在：

```text
MyNetBatt.app/Contents/MacOS/MyNetBattPrivilegedHelper
```

## 8. 把 LaunchDaemon plist 複製進 App bundle

再建立一個 Copy Files Phase：

```text
Destination: Wrapper
Subpath: Contents/Library/LaunchDaemons
```

加入：

```text
MyNetBatt/LaunchDaemons/com.stone5202.MyNetBatt.PrivilegedHelper.plist
```

這一項不要勾 Code Sign On Copy。

Build 後應存在：

```text
MyNetBatt.app/Contents/Library/LaunchDaemons/com.stone5202.MyNetBatt.PrivilegedHelper.plist
```

## 9. Clean Build Folder

```text
Product → Clean Build Folder
```

再重新 Run。若曾經測試舊 Helper，建議一併清除 Derived Data。

---

# 第一次啟用方式

打開：

```text
MyNetBatt → 控制中心 → 電池與電源狀態
```

右上角會看到低耗電模式 Helper 狀態。按 **啟用控制** 後，App 會執行：

```swift
SMAppService.daemon(
    plistName: "com.stone5202.MyNetBatt.PrivilegedHelper.plist"
).register()
```

如果狀態是 `requiresApproval`，到：

```text
系統設定 → 一般 → 登入項目與延伸功能
```

允許 MyNetBatt 的背景項目，再回 App 重新檢查。

---

# 實際資料流

```text
BatteryDetailView
    ↓
PrivilegedHelperManager
    ↓ SMAppService
LaunchDaemon
    ↓
NSXPCConnection(machServiceName:, options: .privileged)
    ↓
com.stone5202.MyNetBatt.PrivilegedHelper
    ↓
/usr/bin/pmset -a lowpowermode 1 / 0
```

讀取狀態時 Helper 使用：

```text
pmset -g batt
pmset -g custom
```

---

# XPC 安全限制

XPC protocol 只有：

```swift
getLowPowerMode(...)
setLowPowerMode(_:...)
```

Helper 只允許固定執行 `/usr/bin/pmset`。

主 App 要求 Helper 的 signing identifier 必須是：

```text
com.stone5202.MyNetBatt.PrivilegedHelper
```

Helper 要求連線端主 App 的 signing identifier 必須是：

```text
com.stone5202.MyNetBatt
```

LaunchDaemon 的 `AssociatedBundleIdentifiers` 也已統一為：

```text
com.stone5202.MyNetBatt
```

---

# 常見錯誤

## `SMAppService` 顯示 notFound

確認 plist 是否存在：

```text
MyNetBatt.app/Contents/Library/LaunchDaemons/com.stone5202.MyNetBatt.PrivilegedHelper.plist
```

## XPC connection invalid / code signing requirement failure

確認：

1. 主 App Bundle Identifier 是 `com.stone5202.MyNetBatt`。
2. Helper Bundle Identifier 是 `com.stone5202.MyNetBatt.PrivilegedHelper`。
3. App 與 Helper 使用同一 Development Team。

可用 Terminal 檢查：

```bash
codesign -dv --verbose=4 /path/to/MyNetBatt.app
codesign -dv --verbose=4 /path/to/MyNetBatt.app/Contents/MacOS/MyNetBattPrivilegedHelper
```

## App Sandbox 仍然開啟

第一階段設計假設主 App 與 Helper 都是 unsandboxed。若 App Sandbox 還開著，先關閉再測試。

---

# Phase 1 完成標準

- MyNetBatt signing identifier 為 `com.stone5202.MyNetBatt`
- Helper signing identifier 為 `com.stone5202.MyNetBatt.PrivilegedHelper`
- `SMAppService` 狀態為 enabled
- App bundle 內有 Helper executable
- App bundle 內有 LaunchDaemon plist
- XPC 可以讀取低耗電模式
- Toggle 可以真正修改 macOS 低耗電模式
- 不需要 AppleScript
- 不需要 `sudo`
