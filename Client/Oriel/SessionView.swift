import SwiftUI
import UIKit

struct SessionView: View {
    @ObservedObject var session: ClientSession

    @State private var mode: InputMode = .trackpad
    @State private var keyboardVisible = false
    @State private var modifiers: UInt64 = 0
    @State private var hudDimmed = false
    @State private var hudTask: DispatchWorkItem?
    @State private var keyboardHeight: CGFloat = 0
    @State private var showHelp = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface(session: session,
                         videoSize: session.videoSize,
                         mode: $mode,
                         viewport: session.viewport,
                         onViewport: { viewport, immediate in
                             session.setViewport(viewport, immediate: immediate)
                         }) { event in
                session.sendInput(event)
            }
            .ignoresSafeArea()
            .offset(y: videoOffset)

            if session.videoSize == .zero {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Waiting for the first frame…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            VStack(spacing: 0) {
                hud
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer(minLength: 0)
                if keyboardVisible {
                    keyBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                toolbar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: keyboardVisible)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .background {
            TypingField(isActive: keyboardVisible,
                        onText: handleText,
                        onDelete: { sendKey(VirtualKey.delete) })
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .sheet(isPresented: $showHelp) { GestureHelpView() }
        .onAppear { scheduleHudDim() }
        .onDisappear { session.disconnect() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let height = max(0, UIScreen.main.bounds.height - frame.minY)
            withAnimation(.easeOut(duration: 0.22)) { keyboardHeight = height }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.22)) { keyboardHeight = 0 }
        }
    }

    /// Shift the video up so it sits in the space above the keyboard and the
    /// bottom controls, instead of being covered by them.
    private var videoOffset: CGFloat {
        guard keyboardVisible, keyboardHeight > 0 else { return 0 }
        let bottomControls: CGFloat = 104
        return -(keyboardHeight + bottomControls) / 2
    }

    // MARK: - HUD

    private var hud: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(session.clientFPS > 0.5 ? OrielTheme.amber : Color.orange)
                .frame(width: 7, height: 7)

            Text(session.resolutionText)
                .font(OrielTheme.mono(11))

            Text(String(format: "%.0f fps", session.clientFPS))
                .font(OrielTheme.mono(11))

            Text(String(format: "%.0f ms", session.latencyMS))
                .font(OrielTheme.mono(11))
                .foregroundStyle(session.latencyMS > 120 ? .orange : .white)

            Text(String(format: "%.1f Mbps", session.kbps / 1000))
                .font(OrielTheme.mono(11))
                .foregroundStyle(.white.opacity(0.55))

            if session.audioChunks > 0 {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }

            if session.viewport.zoom > 1.01 {
                Button {
                    session.resetViewport()
                    scheduleHudDim()
                } label: {
                    Text(String(format: "%.1f×", session.viewport.zoom))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(OrielTheme.amber, in: Capsule())
                        .foregroundStyle(OrielTheme.ink)
                }
            }

            Spacer(minLength: 0)

            Button {
                session.disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(.black.opacity(0.62), in: Capsule())
        .overlay(Capsule().strokeBorder(OrielTheme.hairline, lineWidth: 0.5))
        .opacity(hudDimmed ? 0.25 : 1)
        .onTapGesture {
            hudDimmed = false
            scheduleHudDim()
        }
    }

    private func scheduleHudDim() {
        hudTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.5)) { hudDimmed = true }
        }
        hudTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            pillButton(symbol: keyboardVisible ? "keyboard.fill" : "keyboard",
                       label: nil,
                       active: keyboardVisible) {
                keyboardVisible.toggle()
                if !keyboardVisible { releaseModifiers() }
                scheduleHudDim()
            }

            Button {
                mode = mode == .trackpad ? .direct : .trackpad
                scheduleHudDim()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: mode.symbol)
                    Text(mode.label)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.62), in: Capsule())
                .overlay(Capsule().strokeBorder(OrielTheme.hairline, lineWidth: 0.5))
                .foregroundStyle(.white)
            }

            Button {
                showHelp = true
                scheduleHudDim()
            } label: {
                Image(systemName: "questionmark.circle")
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.62), in: Capsule())
                    .overlay(Capsule().strokeBorder(OrielTheme.hairline, lineWidth: 0.5))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 0)
        }
        .opacity(hudDimmed ? 0.25 : 1)
        .onTapGesture { hudDimmed = false; scheduleHudDim() }
    }

    private func pillButton(symbol: String, label: String?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if let label { Text(label).font(.caption.weight(.medium)) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(active ? OrielTheme.amber : Color.black.opacity(0.62), in: Capsule())
            .overlay(Capsule().strokeBorder(OrielTheme.hairline, lineWidth: active ? 0 : 0.5))
            .foregroundStyle(active ? OrielTheme.ink : .white)
        }
    }

    // MARK: - Key bar

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Window actions live on explicit buttons: reliable, and no
                // conflict with the two-finger gestures.
                actionChip("⊞") { session.sendInput(.hostAction("missionControl")) }
                chordChip("⌃←", flag: EventFlags.control, code: VirtualKey.leftArrow)
                chordChip("⌃→", flag: EventFlags.control, code: VirtualKey.rightArrow)
                chordChip("⌘M", flag: EventFlags.command, code: VirtualKey.letter("m") ?? 46)
                symbolChip("doc.on.clipboard") { session.sendClipboard() }

                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 24)
                    .padding(.horizontal, 2)

                keyChip("esc", code: VirtualKey.escape)
                modifierChip("⌃", bit: EventFlags.control, code: VirtualKey.control)
                modifierChip("⌥", bit: EventFlags.option, code: VirtualKey.option)
                modifierChip("⌘", bit: EventFlags.command, code: VirtualKey.command)
                modifierChip("⇧", bit: EventFlags.shift, code: VirtualKey.shift)
                keyChip("tab", code: VirtualKey.tab)
                keyChip("←", code: VirtualKey.leftArrow)
                keyChip("↑", code: VirtualKey.upArrow)
                keyChip("↓", code: VirtualKey.downArrow)
                keyChip("→", code: VirtualKey.rightArrow)
                keyChip("⏎", code: VirtualKey.returnKey)
                keyChip("⌫", code: VirtualKey.delete)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.black.opacity(0.55))
    }

    private func keyChip(_ label: String, code: UInt16) -> some View {
        Button {
            sendKey(code)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(minWidth: 38, minHeight: 34)
                .padding(.horizontal, 4)
                .background(OrielTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
        }
    }

    private func symbolChip(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHudDim()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 38, minHeight: 34)
                .padding(.horizontal, 4)
                .background(OrielTheme.panelStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
        }
    }

    private func actionChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHudDim()
        } label: {
            Text(label)
                .font(OrielTheme.mono(12, weight: .semibold))
                .frame(minWidth: 38, minHeight: 34)
                .padding(.horizontal, 4)
                .background(OrielTheme.panelStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
        }
    }

    private func chordChip(_ label: String, flag: UInt64, code: UInt16) -> some View {
        Button {
            // One atomic chord: the host presses the modifier as a flagsChanged
            // event, holds it, sends the key, then releases.
            session.sendInput(.chord(code: code, flags: flag))
            scheduleHudDim()
        } label: {
            Text(label)
                .font(OrielTheme.mono(12, weight: .semibold))
                .frame(minWidth: 38, minHeight: 34)
                .padding(.horizontal, 4)
                .background(OrielTheme.panelStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
        }
    }

    private func modifierChip(_ label: String, bit: UInt64, code: UInt16) -> some View {
        let active = modifiers & bit != 0
        return Button {
            if active {
                session.sendInput(.key(code: code, down: false, flags: 0))
                modifiers &= ~bit
            } else {
                session.sendInput(.key(code: code, down: true, flags: modifiers))
                modifiers |= bit
            }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(minWidth: 38, minHeight: 34)
                .padding(.horizontal, 4)
                .background(active ? OrielTheme.amber : OrielTheme.panel,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(active ? OrielTheme.ink : .white)
        }
    }

    // MARK: - Input plumbing

    private func sendKey(_ code: UInt16) {
        session.sendInput(.key(code: code, down: true, flags: modifiers))
        session.sendInput(.key(code: code, down: false, flags: modifiers))
        releaseModifiers()
    }

    private func handleText(_ text: String) {
        // With a modifier held, a printable character is a shortcut (⌘C), not
        // literal text, so map it back to a keycode.
        if modifiers != 0, text.count == 1, let character = text.first,
           let code = VirtualKey.letter(character) {
            var flags = modifiers
            if character.isUppercase { flags |= EventFlags.shift }
            session.sendInput(.key(code: code, down: true, flags: flags))
            session.sendInput(.key(code: code, down: false, flags: flags))
            releaseModifiers()
            return
        }
        session.sendInput(.text(text))
        releaseModifiers(silently: true)
    }

    private func releaseModifiers(silently: Bool = false) {
        guard modifiers != 0 else { return }
        let codes: [(UInt64, UInt16)] = [
            (EventFlags.control, VirtualKey.control),
            (EventFlags.option, VirtualKey.option),
            (EventFlags.command, VirtualKey.command),
            (EventFlags.shift, VirtualKey.shift)
        ]
        for (bit, code) in codes where modifiers & bit != 0 {
            session.sendInput(.key(code: code, down: false, flags: 0))
        }
        modifiers = 0
    }
}


struct GestureHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id = UUID()
        let gesture: String
        let action: String
    }

    private let rows: [Row] = [
        Row(gesture: "1-finger drag", action: "Move the pointer"),
        Row(gesture: "1-finger tap", action: "Left click"),
        Row(gesture: "Long-press + drag", action: "Hold, then drag"),
        Row(gesture: "2-finger drag", action: "Scroll"),
        Row(gesture: "2-finger tap", action: "Right click"),
        Row(gesture: "Pinch", action: "Zoom 1×–4× (sharp crop)"),
        Row(gesture: "Double-tap", action: "Toggle 2× zoom"),
        Row(gesture: "Key bar ⌃↑", action: "Mission Control"),
        Row(gesture: "Key bar ⌃← / ⌃→", action: "Previous / next desktop"),
        Row(gesture: "Key bar ⌘M", action: "Minimise window"),
        Row(gesture: "Key bar ⧉", action: "Send iPhone clipboard to Mac")
    ]

    var body: some View {
        NavigationStack {
            List(rows) { row in
                HStack(spacing: 14) {
                    Text(row.gesture)
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(width: 150, alignment: .leading)
                    Text(row.action)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .navigationTitle("Gestures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
