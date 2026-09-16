# MyNetBatt Privileged Helper

MyNetBatt 使用獨立的 privileged helper 修改 macOS 低耗電模式。主程式不直接以 root 身分執行，日常切換也不會反覆要求管理員密碼。

## 識別碼

```text
主 App：      com.stone5202.MyNetBatt
Helper：      com.stone5202.MyNetBatt.PrivilegedHelper
Mach Service：com.stone5202.MyNetBatt.PrivilegedHelper
Team ID：     MHCATJULGT
```

主程式和 helper 的 XPC signing requirement 會同時驗證 bundle identifier 與 Team ID。若更換開發團隊或 bundle identifier，必須同步修改：

- `MyNetBatt/MyNetBatt/PrivilegedHelperProtocol.swift`
- `MyNetBatt/PrivilegedHelper/HelperProtocol.swift`
- Xcode project 的 Signing 設定

## 專案結構

主程式：

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

Xcode project 已設定：

- `MyNetBattPrivilegedHelper` Command Line Tool target
- 主程式對 helper 的 target dependency
- 將簽章後的 helper 複製到 `MyNetBatt.app/Contents/MacOS`
- 主程式與 helper 的 entitlements
- 關閉主程式 App Sandbox

## 安裝與執行流程

第一次按「安裝 Helper」或需要修復時，主程式會要求管理員授權，然後：

1. 將 app bundle 內的 helper 安裝到 `/Library/PrivilegedHelperTools/`。
2. 動態建立 launchd plist 並安裝到 `/Library/LaunchDaemons/`。
3. 使用 `launchctl bootstrap system` 啟動服務。
4. 後續透過 privileged `NSXPCConnection` 呼叫 helper。

資料流：

```text
BatteryDetailView / BatteryPopoverView
    ↓
PrivilegedHelperManager
    ↓
NSXPCConnection(options: .privileged)
    ↓
MyNetBattPrivilegedHelper
    ↓
/usr/bin/pmset -a lowpowermode 1 / 0
```

Repository 不需要存放 LaunchDaemon plist；程式會在安裝時依目前設定產生它。

## 安全限制

- Helper 只公開讀取與切換低耗電模式的方法，不接受任意 command、path 或 arguments。
- 主程式與 helper 互相驗證 signing identifier 和 Team ID。
- 管理員權限只用於安裝、修復或移除 helper。

## 建置與檢查

在 Xcode 確認主程式與 helper 使用同一個 Development Team，再執行：

```bash
xcodebuild \
  -project MyNetBatt/MyNetBatt.xcodeproj \
  -scheme MyNetBatt \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

可用以下指令檢查簽章：

```bash
codesign -dv --verbose=4 /path/to/MyNetBatt.app
codesign -dv --verbose=4 /path/to/MyNetBatt.app/Contents/MacOS/MyNetBattPrivilegedHelper
```

建置後，app bundle 應包含：

```text
MyNetBatt.app/Contents/MacOS/MyNetBattPrivilegedHelper
```

LaunchDaemon plist 只會出現在完成安裝的系統路徑，不應被打包進 app bundle。
