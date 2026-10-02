import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: MyNetBattPrivilegedHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.setCodeSigningRequirement(PrivilegedHelperConstants.mainAppSigningRequirement)
        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
delegate.service.scheduleIdleExit()
let listener = NSXPCListener(machServiceName: PrivilegedHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
