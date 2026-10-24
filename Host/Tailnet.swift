import Foundation

/// Reads the tailnet inventory from the Tailscale CLI so the client can offer a
/// list of machines instead of making the user type an address.
enum Tailnet {

    static var binary: String? {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var selfName: String {
        ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    }

    static func peers() -> [PeerEntry] {
        guard let binary else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(data)
    }

    private static func parse(_ data: Data) -> [PeerEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var result: [PeerEntry] = []

        // The host itself belongs in the list: `tailscale status` only reports
        // peers, so without this the Mac you are already talking to would be
        // the one machine missing from the picker.
        if let selfNode = root["Self"] as? [String: Any],
           let entry = entry(from: selfNode) {
            result.append(entry)
        }

        if let peers = root["Peer"] as? [String: Any] {
            for value in peers.values {
                guard let dictionary = value as? [String: Any],
                      let entry = entry(from: dictionary) else { continue }
                result.append(entry)
            }
        }

        // Macs first, then online, then alphabetical.
        return result.sorted { left, right in
            if left.isMac != right.isMac { return left.isMac }
            if left.online != right.online { return left.online }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    /// Only devices with an IPv4 tailnet address are useful here: Funnel
    /// ingress nodes are IPv6-only and would clutter the picker.
    private static func entry(from dictionary: [String: Any]) -> PeerEntry? {
        guard let name = dictionary["HostName"] as? String, !name.isEmpty else { return nil }
        let addresses = dictionary["TailscaleIPs"] as? [String] ?? []
        guard let ip = addresses.first(where: { !$0.contains(":") }) else { return nil }

        return PeerEntry(name: name,
                         ip: ip,
                         os: dictionary["OS"] as? String ?? "",
                         online: dictionary["Online"] as? Bool ?? true)
    }
}
