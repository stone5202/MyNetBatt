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
    static let machServiceName = "com.stone5202.MyNetBatt.PrivilegedHelper"
    /// Helper 執行檔名稱必須等於它的簽章 identifier：SMAppService 會依 BundleProgram 的檔名
    /// 產生 launch constraint，兩者不同時 launchd 會拒絕啟動（EX_CONFIG）。
    static let helperExecutableName = "com.stone5202.MyNetBatt.PrivilegedHelper"
    /// SMAppService 從 MyNetBatt.app/Contents/Library/LaunchDaemons/ 讀取這個 plist。
    static let daemonPlistName = "com.stone5202.MyNetBatt.PrivilegedHelper.plist"
    // 同時驗證 signing identifier 與 Team ID，避免誤連到同名的 XPC service。
    // 若日後修改 Team 或 PRODUCT_BUNDLE_IDENTIFIER，兩端的 requirement 必須一起更新。
    static let appSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt\" and certificate leaf[subject.OU] = \"MHCATJULGT\""
    static let helperSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt.PrivilegedHelper\" and certificate leaf[subject.OU] = \"MHCATJULGT\""
}
