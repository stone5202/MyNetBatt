# MyNetBatt 第一階段：Privileged Helper + 低耗電模式控制

這一階段把低耗電模式控制從 `AppleScript / osascript / sudo` 改成 macOS 13+ 建議的 `SMAppService + LaunchDaemon + NSXPCConnection` 架構。

## 為什麼要這樣做

主 App 不應該直接以管理員權限執行任意 shell 指令。MyNetBatt 現在只會向一個受簽章的 Helper 發送兩種 XPC 請求：

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

目前 Repository 已經放好所有需要的原始碼、plist 與 entitlements，但 **Xcode Target / Copy Files Build Phase 必須由 Xcode 建立**。不要直接手改 `project.pbxproj`，比較不容易把專案結構弄壞。

## 1. 先確認主 App Bundle Identifier

目前 Repository 的 Xcode project 使用：

```text
-23.MyNetBatt
```

這個值同時出現在 Helper 的 XPC code-signing requirement。

如果你之後把 Bundle Identifier 改成例如：

```text
com.stone5202.MyNetBatt
```

請同步修改：

- `MyNetBatt/MyNetBatt/PrivilegedHelperProtocol.swift`
- `MyNetBatt/PrivilegedHelper/HelperProtocol.swift`
- `MyNetBatt/LaunchDaemons/com.stone5202.MyNetBatt.PrivilegedHelper.plist` 的 `AssociatedBundleIdentifiers`

## 2. 主 App 關閉 App Sandbox

選：

```text
Project → MyNetBatt Target → Signing & Capabilities
```

把 **App Sandbox** 移除。

原因：這一階段使用的是未 sandbox 的 root LaunchDaemon；sandboxed App 搭配 unsandboxed daemon 不屬於支援組合。

接著在 Build Settings 搜尋：

```text
Code Signing Entitlements
```

Debug / Release 都設定成：

```text
MyNetBatt/MyNetBatt.entitlements
```

如果 Xcode 自動顯示相對位置不同，以專案實際檔案位置為準。

## 3. 新增 Command Line Tool Target

在 Xcode：

```text
File → New → Target…
```

選：

```text
macOS → Command Line Tool
```

Product Name 請**完全使用**：

```text
MyNetBattPrivilegedHelper
```

Language：

```text
Swift
```

Team：與 MyNetBatt 主 App 相同。

建立完成後，把 Xcode 自動產生的預設 `main.swift` 刪掉，避免和 Repository 裡的 Helper `main.swift` 重複。

## 4. 把 Helper 三個 Swift 檔加入 Helper Target

把以下檔案加入 Xcode project，Target Membership **只勾 `MyNetBattPrivilegedHelper`**：

```text
MyNetBatt/PrivilegedHelper/main.swift
MyNetBatt/PrivilegedHelper/HelperProtocol.swift
MyNetBatt/PrivilegedHelper/HelperService.swift
```

不要讓這三個檔案加入主 `MyNetBatt` App target。

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

另外搜尋：

```text
Create Info.plist Section in Binary
```

設成：

```text
YES
```

這讓 command-line helper 的 signing identifier 能穩定使用 `com.stone5202.MyNetBatt.PrivilegedHelper`，與 App 端的 XPC code-signing requirement 一致。

## 6. 加入 Target Dependency

選：

```text
MyNetBatt Target → Build Phases → Target Dependencies
```

按 `+` 加入：

```text
MyNetBattPrivilegedHelper
```

這樣每次建置 MyNetBatt 前，Helper 都會先建置。

## 7. 把 Helper executable 複製進 App bundle

在：

```text
MyNetBatt Target → Build Phases
```

按 `+`：

```text
New Copy Files Phase
```

設定：

```text
Destination: Wrapper
Subpath: Contents/MacOS
```

把：

```text
MyNetBattPrivilegedHelper
```

從 Products 拖進這個 Copy Files phase。

**Code Sign On Copy 要勾選。**

最後 build 出來後，應該存在：

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

這一項 **Code Sign On Copy 不要勾**。

最後應該存在：

```text
MyNetBatt.app/Contents/Library/LaunchDaemons/com.stone5202.MyNetBatt.PrivilegedHelper.plist
```

`SMAppService.daemon(plistName:)` 只會在這個位置尋找 LaunchDaemon plist。

## 9. Clean Build Folder

設定完成後：

```text
Product → Clean Build Folder
```

然後重新 Run。

如果你之前測試過舊 helper，建議先刪掉 Derived Data 或至少完整 Clean 一次。

---

# 第一次啟用方式

打開：

```text
MyNetBatt → 控制中心 → 電池與電源狀態
```

右上角會看到：

```text
低耗電模式
尚未啟用控制
[啟用控制]
```

按 **啟用控制** 後，App 會執行：

```swift
SMAppService.daemon(
    plistName: "com.stone5202.MyNetBatt.PrivilegedHelper.plist"
).register()
```

macOS 可能要求管理員認證，或把狀態變成 `requiresApproval`。

如果畫面顯示：

```text
等待系統核准
```

請到：

```text
系統設定 → 一般 → 登入項目與延伸功能
```

找到 MyNetBatt 的背景項目並允許。

回到 MyNetBatt 後按 **重新檢查**。

當狀態變成 `enabled`，右上角就會出現真正可操作的低耗電模式 Toggle。

---

# 實際資料流

```text
BatteryDetailView
    ↓
PrivilegedHelperManager
    ↓ SMAppService 註冊
LaunchDaemon
    ↓
NSXPCConnection(machServiceName:, options: .privileged)
    ↓
MyNetBattPrivilegedHelper
    ↓
/usr/bin/pmset -a lowpowermode 1 / 0
```

讀取狀態時 Helper 使用：

```text
pmset -g batt
pmset -g custom
```

來判斷目前是 AC Power 或 Battery Power，並讀取該 profile 的 `lowpowermode`。

---

# XPC 安全限制

這版不是開一個可以執行任意 root command 的服務。

XPC protocol 只有：

```swift
getLowPowerMode(...)
setLowPowerMode(_:...)
```

Helper 只允許固定執行：

```text
/usr/bin/pmset
```

而且 NSXPCConnection 雙方都有 code-signing requirement：

主 App 要求 Helper 必須是：

```text
com.stone5202.MyNetBatt.PrivilegedHelper
```

Helper 要求連線端必須是：

```text
-23.MyNetBatt
```

如果你修改 Bundle Identifier，務必同步修改這些 requirement。

---

# 常見錯誤

## `SMAppService` 顯示 notFound

通常代表 LaunchDaemon plist 沒有被 copy 到：

```text
MyNetBatt.app/Contents/Library/LaunchDaemons/
```

先在 Xcode build product 上按右鍵 → Show in Finder → Show Package Contents 檢查。

## XPC connection invalid / code signing requirement failure

檢查兩件事：

1. App 與 Helper 是否使用同一 Development Team 簽章。
2. Helper 的 signing identifier 是否真的是：

```text
com.stone5202.MyNetBatt.PrivilegedHelper
```

可以在 Terminal 檢查：

```bash
codesign -dv --verbose=4 /path/to/MyNetBatt.app/Contents/MacOS/MyNetBattPrivilegedHelper
```

以及：

```bash
codesign -dv --verbose=4 /path/to/MyNetBatt.app
```

## App Sandbox 仍然開啟

這個第一階段設計假設 App 與 Helper 都是 unsandboxed。

如果 App Sandbox 還開著，先關閉再測試。

---

# Phase 1 完成標準

以下全部成立就表示第一階段完成：

- MyNetBatt 正常啟動
- `SMAppService` 狀態為 enabled
- App bundle 裡有 Helper executable
- App bundle 裡有 LaunchDaemon plist
- XPC 可以讀取低耗電模式
- 控制中心的 Toggle 可以真的修改 macOS 低耗電模式
- 不需要 AppleScript
- 不需要 `sudo`
- 不會再出現先前的 XProtect AppleScript 錯誤
