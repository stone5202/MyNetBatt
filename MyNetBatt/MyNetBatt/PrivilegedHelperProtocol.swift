import Foundation

@objc protocol MyNetBattPrivilegedHelperProtocol {
    func getLowPowerMode(withReply reply: @escaping (Bool, String?) -> Void)
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

enum PrivilegedHelperConstants {
    static let machServiceName = "com.stone5202.MyNetBatt.PrivilegedHelper"
    static let daemonPlistName = "com.stone5202.MyNetBatt.PrivilegedHelper.plist"

    // 主 App 與 Helper 的 signing identifier / bundle identifier。
    // 若日後修改 PRODUCT_BUNDLE_IDENTIFIER，兩端的 requirement 必須一起更新。
    static let appSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt\""
    static let helperSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt.PrivilegedHelper\""
}
