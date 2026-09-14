import Foundation

@objc protocol MyNetBattPrivilegedHelperProtocol {
    func getLowPowerMode(withReply reply: @escaping (Bool, String?) -> Void)
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

enum PrivilegedHelperConstants {
    static let machServiceName = "com.stone5202.MyNetBatt.PrivilegedHelper"
    static let mainAppSigningRequirement = "anchor apple generic and identifier \"-23.MyNetBatt\""
}
