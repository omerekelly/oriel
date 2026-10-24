import Foundation

/// Pairing code that a client must present before it can see or control the
/// screen. Without this, every device on the tailnet is trusted implicitly.
///
/// The code is short enough to type on a phone and stored in Application
/// Support. The alphabet omits look-alikes (0/O, 1/I) so it can be read off the
/// menu bar without ambiguity.
enum Pairing {

    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let length = 8

    private struct State: Codable { var token: String }

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oriel", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("pairing.json")
    }

    /// Reads the stored code, creating one on first launch.
    static func loadOrCreate() -> String {
        if let data = try? Data(contentsOf: storeURL),
           let state = try? JSONDecoder().decode(State.self, from: data),
           state.token.count == length {
            return state.token
        }
        return reset()
    }

    /// Generates a new code, invalidating every existing client.
    @discardableResult
    static func reset() -> String {
        let token = String((0..<length).map { _ in alphabet.randomElement() ?? "A" })
        if let data = try? JSONEncoder().encode(State(token: token)) {
            try? data.write(to: storeURL, options: .atomic)
        }
        return token
    }

    /// "K7M4Q29X" -> "K7M4-Q29X" for display.
    static func display(_ token: String) -> String {
        guard token.count == length else { return token }
        return "\(token.prefix(4))-\(token.suffix(4))"
    }

    /// Strips separators and case so "k7m4 q29x" still matches.
    static func normalise(_ input: String) -> String {
        input.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func matches(_ input: String, _ token: String) -> Bool {
        guard !token.isEmpty, !input.isEmpty else { return false }
        let a = Array(normalise(input).utf8)
        let b = Array(normalise(token).utf8)
        // Length-independent comparison; the code is short and low-value, but
        // there is no reason to leak a prefix.
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
