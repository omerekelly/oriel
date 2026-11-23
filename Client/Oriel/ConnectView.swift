import SwiftUI
import Network

struct ConnectView: View {
    @ObservedObject var session: ClientSession

    @AppStorage("lastHost") private var host = "100.78.170.16"
    @AppStorage("lastPort") private var portText = "7801"
    @AppStorage("pairingCode") private var pairingCode = ""
    @State private var editing = false
    @StateObject private var nearby = NearbyBrowser()

    private var port: UInt16 { UInt16(portText) ?? ProtocolLimits.defaultPort }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                nearbySection

                if !session.peers.isEmpty {
                    peerList
                }

                VStack(alignment: .leading, spacing: 14) {
                    field(title: "Tailscale address", text: $host, keyboard: .URL)
                    field(title: "Port", text: $portText, keyboard: .numberPad)
                    field(title: "Pairing code", text: $pairingCode, keyboard: .asciiCapable)
                }

                connectButton

                if case .failed(let message) = session.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if session.state == .connecting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Connecting to \(host)…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                tips
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .background(Color.black)
        .onAppear { nearby.start() }
        .onDisappear { nearby.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image("OrielMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(OrielTheme.hairline, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Oriel")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Your Mac, from anywhere.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEARBY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if nearby.hosts.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: nearby.settled ? "wifi.slash" : "wifi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text(nearby.settled
                         ? "No nearby Macs. Allow Local Network access in Settings."
                         : "Searching for Macs on this network…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    if nearby.settled {
                        Button("Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.caption2.weight(.semibold))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(OrielTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            ForEach(nearby.hosts) { entry in
                Button {
                    connectNearby(entry)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi")
                            .font(.caption)
                            .foregroundStyle(OrielTheme.amber)
                            .frame(width: 16)

                        Text(entry.name)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer(minLength: 6)

                        Text("LAN")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(OrielTheme.amber.opacity(0.9), in: Capsule())
                            .foregroundStyle(OrielTheme.ink)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(OrielTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Prefers the local route and falls back to whatever address is typed in,
    /// so a nearby Mac connects instantly on Wi-Fi and still works remotely.
    private func connectNearby(_ entry: NearbyHost) {
        var targets = [ClientSession.ConnectionTarget(label: "LAN", endpoint: entry.endpoint)]
        let typed = host.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) {
            targets.append(ClientSession.ConnectionTarget(
                label: ClientSession.label(for: typed),
                endpoint: .hostPort(host: NWEndpoint.Host(typed), port: nwPort)))
        }
        session.connect(targets: targets, token: pairingCode)
    }

    private var peerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR TAILNET")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(session.peers) { peer in
                Button {
                    host = peer.ip
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: peer.isMac ? "laptopcomputer" : "display")
                            .font(.caption)
                            .foregroundStyle(peer.isMac ? OrielTheme.amber : .secondary)
                            .frame(width: 16)

                        Text(peer.name)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer(minLength: 6)

                        Text(peer.ip)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Circle()
                            .fill(peer.online ? Color.green.opacity(0.8) : Color.gray.opacity(0.5))
                            .frame(width: 6, height: 6)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(host == peer.ip ? OrielTheme.panelStrong : OrielTheme.panel,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func field(title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .padding(14)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
    }

    private var connectButton: some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            session.connect(host: host.trimmingCharacters(in: .whitespaces),
                            port: port,
                            token: pairingCode)
        } label: {
            HStack {
                Spacer()
                if session.state == .connecting {
                    ProgressView().tint(OrielTheme.ink)
                } else {
                    Image(systemName: "play.fill")
                    Text("Connect")
                        .fontWeight(.semibold)
                }
                Spacer()
            }
            .padding(.vertical, 16)
            .background(OrielTheme.amber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(OrielTheme.ink)
        }
        .disabled(session.state == .connecting || host.isEmpty || pairingCode.isEmpty)
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before you connect")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            tip("moon.zzz.fill", "The Oriel host is running and shows a mark in the menu bar.")
            tip("lock.shield.fill", "Screen Recording and Accessibility are granted to Oriel Host.")
            tip("key.fill", "The pairing code is shown in the Oriel menu bar on the Mac.")
            tip("network", "Tailscale shows on this iPhone, and the Mac is listed as connected.")
            Text(buildStamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.top, 12)
        }
        .padding(.top, 8)
    }

    /// The executable's modification date is the actual build time, which is the
    /// only reliable way to tell two installs apart (CFBundleVersion is static).
    private var buildStamp: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard let path = Bundle.main.executablePath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else {
            return "v\(version)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return "v\(version) · built \(formatter.string(from: date))"
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
