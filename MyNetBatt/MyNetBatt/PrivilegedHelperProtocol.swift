import Foundation

@objc protocol MyNetBattPrivilegedHelperProtocol {
    func getLowPowerMode(withReply reply: @escaping (Bool, String?) -> Void)
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

enum PrivilegedHelperConstants {
    static let machServiceName = "com.stone5202.MyNetBatt.PrivilegedHelper"
    static let daemonPlistName = "com.stone5202.MyNetBatt.PrivilegedHelper.plist"

    // Xcode 目前專案的主 App signing identifier / bundle identifier。
    // 如果你之後修改 PRODUCT_BUNDLE_IDENTIFIER，請同步修改 Helper 端的 requirement。
    static let appSigningRequirement = "anchor apple generic and identifier \"-23.MyNetBatt\""
    static let helperSigningRequirement = "anchor apple generic and identifier \"com.stone5202.MyNetBatt.PrivilegedHelper\""
}
