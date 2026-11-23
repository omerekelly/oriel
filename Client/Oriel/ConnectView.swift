import SwiftUI
import Network

struct ConnectView: View {
    @ObservedObject var session: ClientSession

    @AppStorage("lastHost") private var host = "100.78.170.16"
    @AppStorage("lastPort") private var portText = "7801"
    @AppStorage("pairingCode") private var pairingCode = ""

    @State private var showManual = false
    @StateObject private var nearby = NearbyBrowser()
    @FocusState private var codeFocused: Bool

    private var port: UInt16 { UInt16(portText) ?? ProtocolLimits.defaultPort }
    private var busy: Bool { session.state == .connecting }
    private var ready: Bool { !pairingCode.isEmpty && !busy }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                devices
                pairing
                connectButton
                manual
                footnote
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.black)
        .onAppear { nearby.start() }
        .onDisappear { nearby.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image("OrielMark")
                .resizable()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(OrielTheme.hairline, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Oriel")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Your Mac, from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if busy { ProgressView().tint(.white) }
        }
    }

    // MARK: - Machines

    private var devices: some View {
        VStack(spacing: 0) {
            if !nearby.hosts.isEmpty {
                sectionHeader("NEARBY")
                ForEach(Array(nearby.hosts.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { divider }
                    row(icon: "wifi",
                        name: entry.name,
                        detail: "Same network",
                        tag: "LAN",
                        tint: OrielTheme.amber) {
                        connectNearby(entry)
                    }
                }
            }

            if !session.peers.isEmpty {
                if !nearby.hosts.isEmpty { divider }
                sectionHeader("TAILNET")
                ForEach(Array(session.peers.enumerated()), id: \.element.id) { index, peer in
                    if index > 0 { divider }
                    row(icon: peer.isMac ? "laptopcomputer" : "display",
                        name: peer.name,
                        detail: peer.ip,
                        tag: nil,
                        tint: peer.online ? .white.opacity(0.75) : .white.opacity(0.3)) {
                        connectTailnet(peer)
                    }
                }
            }

            if nearby.hosts.isEmpty && session.peers.isEmpty {
                sectionHeader("MACHINES")
                emptyRow
            }
        }
        .background(OrielTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(OrielTheme.hairline, lineWidth: 0.5)
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 5)
    }

    private var divider: some View {
        Rectangle()
            .fill(OrielTheme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 48)
    }

    private func row(icon: String,
                     name: String,
                     detail: String,
                     tag: String?,
                     tint: Color,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let tag {
                    Text(tag)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(OrielTheme.amber.opacity(0.9), in: Capsule())
                        .foregroundStyle(OrielTheme.ink)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.22))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyRow: some View {
        HStack(spacing: 12) {
            Image(systemName: nearby.settled ? "wifi.slash" : "wifi")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            Text(nearby.settled
                 ? "No Macs found nearby. Allow Local Network access, or connect by address below."
                 : "Looking for Macs on this network…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if nearby.settled {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(OrielTheme.amber)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    // MARK: - Pairing

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PAIRING CODE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(pairingCode.isEmpty ? .secondary : OrielTheme.amber)

                TextField("8 characters", text: $pairingCode)
                    .focused($codeFocused)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                    .submitLabel(.go)
                    .onSubmit { connectManual() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(OrielTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(codeFocused ? OrielTheme.amber.opacity(0.6) : OrielTheme.hairline,
                                  lineWidth: 1)
            )
        }
    }

    // MARK: - Actions

    private var connectButton: some View {
        Button {
            if let first = nearby.hosts.first {
                connectNearby(first)
            } else if let peer = session.peers.first(where: \.isMac) ?? session.peers.first {
                connectTailnet(peer)
            } else {
                connectManual()
            }
        } label: {
            HStack {
                Spacer()
                Text(ready ? "Connect" : (busy ? "Connecting…" : "Enter pairing code"))
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.vertical, 15)
            .background(ready ? OrielTheme.amber : Color.white.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(ready ? OrielTheme.ink : .white.opacity(0.35))
        }
        .disabled(!ready)
    }

    // MARK: - Manual address

    private var manual: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showManual.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showManual ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Enter address manually")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if showManual {
                VStack(spacing: 8) {
                    compactField("Address", text: $host, keyboard: .URL)
                    compactField("Port", text: $portText, keyboard: .numberPad)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func compactField(_ title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            TextField("", text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OrielTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footer

    private var footnote: some View {
        VStack(spacing: 10) {
            if case .failed(let message) = session.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The pairing code is in the Oriel menu bar on your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)

            Text(buildStamp)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.18))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private var buildStamp: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard let path = Bundle.main.executablePath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else { return "v\(version)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return "v\(version) · built \(formatter.string(from: date))"
    }

    // MARK: - Connecting

    private func requireCode() -> Bool {
        if pairingCode.isEmpty {
            codeFocused = true
            return false
        }
        return true
    }

    private func connectNearby(_ entry: NearbyHost) {
        guard requireCode() else { return }
        var targets = [ClientSession.ConnectionTarget(label: "LAN", endpoint: entry.endpoint)]
        let typed = host.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) {
            targets.append(ClientSession.ConnectionTarget(
                label: ClientSession.label(for: typed),
                endpoint: .hostPort(host: NWEndpoint.Host(typed), port: nwPort)))
        }
        session.connect(targets: targets, token: pairingCode)
    }

    private func connectTailnet(_ peer: PeerEntry) {
        guard requireCode() else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        session.connect(targets: [ClientSession.ConnectionTarget(
            label: ClientSession.label(for: peer.ip),
            endpoint: .hostPort(host: NWEndpoint.Host(peer.ip), port: nwPort))],
            token: pairingCode)
    }

    private func connectManual() {
        guard requireCode() else { return }
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { showManual = true; return }
        session.connect(host: trimmed, port: port, token: pairingCode)
    }
}
