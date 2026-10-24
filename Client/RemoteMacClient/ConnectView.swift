import SwiftUI

struct ConnectView: View {
    @ObservedObject var session: ClientSession

    @AppStorage("lastHost") private var host = "100.78.170.16"
    @AppStorage("lastPort") private var portText = "7801"
    @AppStorage("pairingCode") private var pairingCode = ""
    @State private var editing = false

    private var port: UInt16 { UInt16(portText) ?? ProtocolLimits.defaultPort }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

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
        }
        .padding(.top, 8)
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
