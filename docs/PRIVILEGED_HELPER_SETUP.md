# MyNetBatt Privileged Helper

MyNetBatt 使用獨立的 privileged helper 修改 macOS 低耗電模式。Helper 以 `SMAppService.daemon` 註冊，由 launchd 直接執行 App bundle 內的執行檔；主程式不以 root 身分執行，日常切換也不需要管理員密碼。

## 識別碼

```text
主 App：      com.stone5202.MyNetBatt
Helper：      com.stone5202.MyNetBatt.PrivilegedHelper
Mach Service：com.stone5202.MyNetBatt.LowPowerHelper
launchd label：com.stone5202.MyNetBatt.LowPowerHelper
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

LaunchDaemon plist：

```text
MyNetBatt/LaunchDaemons/com.stone5202.MyNetBatt.LowPowerHelper.plist
```

Xcode project 已設定：

- `MyNetBattPrivilegedHelper` Command Line Tool target（產出的執行檔名稱為 `com.stone5202.MyNetBatt.PrivilegedHelper`，與簽章 identifier 相同）
- 主程式對 helper 的 target dependency
- 將簽章後的 helper 複製到 `MyNetBatt.app/Contents/MacOS`
- 將 LaunchDaemon plist 複製到 `MyNetBatt.app/Contents/Library/LaunchDaemons`
- 主程式與 helper 皆啟用 Hardened Runtime
- 主程式與 helper 的 entitlements
- 關閉主程式 App Sandbox

## 安裝與執行流程

1. 使用者按「啟用 Helper」，主程式呼叫 `SMAppService.daemon(plistName:).register()`。
2. macOS 將背景項目設為「等待核准」，主程式開啟「系統設定 › 一般 › 登入項目與延伸功能」。
3. 使用者允許後，launchd 會在第一次連線時按需啟動 `Contents/MacOS/com.stone5202.MyNetBatt.PrivilegedHelper`。
4. 主程式透過 privileged `NSXPCConnection` 呼叫 helper。
5. Helper 閒置 60 秒後自行結束，下一次請求時再由 launchd 啟動。

### 版本檢查

Helper 的 `getVersion` 會回傳 `CFBundleVersion`（`CURRENT_PROJECT_VERSION`）。主程式每次建立連線後，會先和 App 內附的 helper 版本比對；如果 App 更新後仍有舊版 helper 在執行，主程式會呼叫 `exitForUpdate` 讓它結束，launchd 隨後會啟動新版。**每次發布新版時都要遞增 `CURRENT_PROJECT_VERSION`。**

### 從舊版升級

3.2 以前的版本以 AppleScript 將 helper 複製到 `/Library/PrivilegedHelperTools/`，並將 plist 安裝到 `/Library/LaunchDaemons/`。新版偵測到這些檔案時會顯示「更新 Helper」，按下後在背景要求一次管理員授權，執行 `launchctl bootout` 並刪除舊檔案，再改用 `SMAppService` 註冊。

新版的 launchd label 與 Mach service 改為 `com.stone5202.MyNetBatt.LowPowerHelper`。原因：系統的背景項目資料庫（BTM）會保留某個 label 第一次註冊時產生的 launch constraint（要求的簽章 identifier），之後即使取消再重新註冊也不會更新。若該 label 曾以不同簽章的 helper 註冊過，AMFI 會以「Launch Constraint Violation」拒絕啟動 helper。**請勿改回舊 label，也不要在 helper 簽章 identifier 變更後沿用同一個 label。**

資料流：

```text
BatteryDetailView / BatteryPopoverView
    ↓
PrivilegedHelperManager
    ↓
NSXPCConnection(options: .privileged)
    ↓
com.stone5202.MyNetBatt.PrivilegedHelper
    ↓
/usr/bin/pmset -a lowpowermode 1 / 0
```


## 安全限制

- Helper 只公開讀取與切換低耗電模式的方法，不接受任意 command、path 或 arguments。
- 主程式與 helper 互相驗證 signing identifier 和 Team ID。
- Helper 由 launchd 直接從已簽章的 App bundle 執行，不會複製到其他位置，因此不會執行到未經驗證的副本。
- 管理員密碼只在移除舊版安裝時使用一次；啟用新版只需在系統設定中核准。

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
codesign -dv --verbose=4 /path/to/MyNetBatt.app/Contents/MacOS/com.stone5202.MyNetBatt.PrivilegedHelper
```

建置後，app bundle 應包含：

```text
MyNetBatt.app/Contents/MacOS/com.stone5202.MyNetBatt.PrivilegedHelper
MyNetBatt.app/Contents/Library/LaunchDaemons/com.stone5202.MyNetBatt.LowPowerHelper.plist
```

可用以下指令確認 launchd 已載入 helper：

```bash
launchctl print system/com.stone5202.MyNetBatt.LowPowerHelper
```
