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
    static let machServiceName = "com.stone5202.MyNetBatt.LowPowerHelper"
    static let mainAppSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt\" and certificate leaf[subject.OU] = \"MHCATJULGT\""
}
