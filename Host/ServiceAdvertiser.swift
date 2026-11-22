import Foundation

/// Publishes the host on the local network over Bonjour so the client can find
/// it without an IP address. The listening socket is a plain BSD socket, so
/// registration is done with NetService rather than NWListener.
final class ServiceAdvertiser: NSObject, NetServiceDelegate {

    static let serviceType = "_oriel._tcp."

    private var service: NetService?
    var onLog: ((String) -> Void)?

    func start(port: UInt16, name: String) {
        stop()

        let service = NetService(domain: "local.",
                                 type: Self.serviceType,
                                 name: name,
                                 port: Int32(port))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "v": Data("1".utf8),
            "name": Data(name.utf8)
        ]))
        service.publish()
        self.service = service
    }

    func stop() {
        service?.stop()
        service = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        onLog?("Bonjour: advertising \(sender.name) on \(sender.domain) port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        onLog?("Bonjour publish failed: \(errorDict)")
    }
}
