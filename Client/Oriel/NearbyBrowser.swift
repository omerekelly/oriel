import Foundation
import Network

struct NearbyHost: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    static func == (lhs: NearbyHost, rhs: NearbyHost) -> Bool { lhs.id == rhs.id }
}

/// Browses for Oriel hosts on the current network.
///
/// The endpoint is kept as a Bonjour service endpoint rather than resolving it
/// to an address: NWConnection resolves it at connect time, which avoids the
/// IPv4/IPv6 ambiguity of doing it ourselves.
@MainActor
final class NearbyBrowser: ObservableObject {

    @Published private(set) var hosts: [NearbyHost] = []
    /// True once the first browse has had time to produce results, so the UI can
    /// say "nothing found" instead of "searching" forever.
    @Published private(set) var settled = false

    private var browser: NWBrowser?
    private var settleTimer: Timer?

    func start() {
        stop()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: ServiceTypes.oriel, domain: nil),
                                using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        browser.start(queue: .main)
        self.browser = browser

        settled = false
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.settled = true }
        }
    }

    func stop() {
        settleTimer?.invalidate()
        settleTimer = nil
        browser?.cancel()
        browser = nil
        hosts = []
        settled = false
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var found: [NearbyHost] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            found.append(NearbyHost(id: name, name: name, endpoint: result.endpoint))
        }
        hosts = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !found.isEmpty { settled = true }
    }
}

enum ServiceTypes {
    /// Must match `ServiceAdvertiser.serviceType` on the host.
    static let oriel = "_oriel._tcp"
}
