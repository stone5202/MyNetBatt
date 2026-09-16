import Foundation

@objc protocol MyNetBattPrivilegedHelperProtocol {
    func getLowPowerMode(withReply reply: @escaping (Bool, String?) -> Void)
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

enum PrivilegedHelperConstants {
    static let machServiceName = "com.stone5202.MyNetBatt.PrivilegedHelper"
    static let daemonPlistName = "com.stone5202.MyNetBatt.PrivilegedHelper.plist"
    // 同時驗證 signing identifier 與 Team ID，避免誤連到同名的 XPC service。
    // 若日後修改 Team 或 PRODUCT_BUNDLE_IDENTIFIER，兩端的 requirement 必須一起更新。
    static let appSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt\" and certificate leaf[subject.OU] = \"MHCATJULGT\""
    static let helperSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt.PrivilegedHelper\" and certificate leaf[subject.OU] = \"MHCATJULGT\""
}
