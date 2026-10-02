import Foundation

@objc protocol MyNetBattPrivilegedHelperProtocol {
    func getLowPowerMode(withReply reply: @escaping (Bool, String?) -> Void)
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
    /// 回傳 Helper 的 CFBundleVersion，主程式用來偵測 App 更新後仍在執行的舊版 Helper。
    func getVersion(withReply reply: @escaping (String) -> Void)
    /// 請 Helper 結束；下一次連線時 launchd 會改啟動 App bundle 內的新版本。
    func exitForUpdate(withReply reply: @escaping () -> Void)
}

enum PrivilegedHelperConstants {
    /// launchd label 與 XPC Mach service 名稱。
    /// 不沿用舊名稱 com.stone5202.MyNetBatt.PrivilegedHelper：系統的背景項目資料庫（BTM）會保留該 label 首次註冊時的
    /// launch constraint（要求舊的簽章 identifier），取消再重新註冊也不會更新，Helper 會被 AMFI 拒絕啟動。
    static let machServiceName = "com.stone5202.MyNetBatt.LowPowerHelper"
    /// Helper 執行檔名稱與簽章 identifier 保持一致，方便在 launchd、AMFI 的紀錄中對照。
    static let helperExecutableName = "com.stone5202.MyNetBatt.PrivilegedHelper"
    /// SMAppService 從 MyNetBatt.app/Contents/Library/LaunchDaemons/ 讀取這個 plist。
    static let daemonPlistName = "com.stone5202.MyNetBatt.LowPowerHelper.plist"
    /// 3.2 以前以 AppleScript 安裝到 /Library 的舊版 Helper 使用的 label。
    static let legacyLabel = "com.stone5202.MyNetBatt.PrivilegedHelper"
    // 同時驗證 signing identifier 與 Team ID，避免誤連到同名的 XPC service。
    // 若日後修改 Team 或 PRODUCT_BUNDLE_IDENTIFIER，兩端的 requirement 必須一起更新。
    static let appSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt\" and certificate leaf[subject.OU] = \"MHCATJULGT\""
    static let helperSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt.PrivilegedHelper\" and certificate leaf[subject.OU] = \"MHCATJULGT\""
}
