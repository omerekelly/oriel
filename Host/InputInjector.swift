import Foundation
import CoreGraphics
import ApplicationServices

/// Translates events from the phone into real macOS input using the HID event
/// tap. Requires Accessibility permission for the host app.
final class InputInjector {

    private let queue = DispatchQueue(label: "dev.igho.remotemac.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Display the stream is showing, in global Quartz coordinates.
    private var displayBounds: CGRect = CGDisplayBounds(CGMainDisplayID())

    /// The slice of the display currently being streamed, normalised 0...1.
    /// Incoming coordinates are relative to this, not to the whole display.
    private var viewportRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Diagnostics sink, wired to the host log.
    var debugLog: ((String) -> Void)?

    private var leftDown = false
    private var rightDown = false

    func updateDisplay(pointSize: CGSize, origin: CGPoint = .zero) {
        queue.sync {
            displayBounds = CGRect(origin: origin, size: pointSize)
        }
    }

    func updateViewport(_ rect: CGRect) {
        queue.sync {
            viewportRect = rect
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Triggers the system Accessibility prompt the first time.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Cursor

    /// Authoritative cursor position.
    ///
    /// Reading the real cursor back mid-burst is unreliable: posted moves are
    /// coalesced, so consecutive events all observe the same stale position and
    /// their deltas collapse into a single move. Track the position ourselves
    /// and only adopt the real cursor once we have been idle long enough that a
    /// physical mouse move is the likely cause of any difference.
    private var virtualCursor: CGPoint?
    private var lastPostAt = Date.distantPast

    private func resolveCursor() -> CGPoint {
        let actual = CGEvent(source: nil)?.location
            ?? CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        if Date().timeIntervalSince(lastPostAt) > 0.25 {
            virtualCursor = actual
        }
        return virtualCursor ?? actual
    }

    private func commit(_ point: CGPoint) {
        virtualCursor = point
        lastPostAt = Date()
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, displayBounds.minX), displayBounds.maxX - 1),
                y: min(max(p.y, displayBounds.minY), displayBounds.maxY - 1))
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: button) else {
            debugLog?("postMouse: CGEvent creation failed")
            return
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Events

    func handle(_ event: InputEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            switch event {
            case let .moveRelative(dx, dy):
                let current = self.resolveCursor()
                let next = self.clamp(CGPoint(x: current.x + dx * self.viewportRect.width,
                                              y: current.y + dy * self.viewportRect.height))
                self.commit(next)
                let type: CGEventType = self.leftDown ? .leftMouseDragged
                                      : self.rightDown ? .rightMouseDragged
                                      : .mouseMoved
                self.postMouse(type, at: next, button: self.rightDown ? .right : .left)

            case let .moveAbsolute(x, y):
                let next = self.clamp(CGPoint(x: self.displayBounds.minX + (self.viewportRect.minX + x * self.viewportRect.width) * self.displayBounds.width,
                                              y: self.displayBounds.minY + (self.viewportRect.minY + y * self.viewportRect.height) * self.displayBounds.height))
                self.commit(next)
                let type: CGEventType = self.leftDown ? .leftMouseDragged
                                      : self.rightDown ? .rightMouseDragged
                                      : .mouseMoved
                self.postMouse(type, at: next, button: self.rightDown ? .right : .left)

            case let .button(button, down):
                self.setButton(button == 0 ? .left : .right, down: down, at: self.resolveCursor())

            case let .scroll(dx, dy):
                guard let e = CGEvent(scrollWheelEvent2Source: self.source,
                                      units: .pixel,
                                      wheelCount: 2,
                                      wheel1: Int32(dy),
                                      wheel2: Int32(dx),
                                      wheel3: 0) else { return }
                e.location = self.resolveCursor()
                e.post(tap: .cghidEventTap)

            case let .hostAction(name):
                self.performHostAction(name)

            case let .chord(code, flags):
                self.postChord(code: CGKeyCode(code), flags: CGEventFlags(rawValue: flags))

            case let .key(code, down, flags):
                let keyCode = CGKeyCode(code)
                if let modifier = InputInjector.modifierFlag(for: keyCode) {
                    self.setModifier(keyCode, modifier, down: down)
                    return
                }
                let combined = InputInjector.flags(forKey: keyCode, CGEventFlags(rawValue: flags))
                    .union(self.heldModifiers)
                self.postKeyEvent(keyCode, down: down, flags: combined)

            case let .text(string):
                self.type(string)

            case let .click(x, y):
                var point = self.resolveCursor()
                if let x, let y {
                    point = self.clamp(CGPoint(x: self.displayBounds.minX + (self.viewportRect.minX + x * self.viewportRect.width) * self.displayBounds.width,
                                               y: self.displayBounds.minY + (self.viewportRect.minY + y * self.viewportRect.height) * self.displayBounds.height))
                }
                self.commit(point)
                self.postMouse(.mouseMoved, at: point, button: .left)
                self.setButton(.left, down: true, at: point)
                self.setButton(.left, down: false, at: point)
            }
        }
    }

    /// Posts a modifier combination the way a real keyboard does it: modifiers
    /// as `flagsChanged` events, held for a moment, then the key, then released.
    ///
    /// Posting all four events in one burst does not work for system shortcuts
    /// (Mission Control, spaces): by the time the arrow is evaluated the
    /// modifier has already been released, so it arrives as a plain arrow.
    /// Modifiers currently held, so releasing one does not clear the others.
    private var heldModifiers: CGEventFlags = []

    private static func modifierFlag(for code: CGKeyCode) -> CGEventFlags? {
        switch code {
        case 55, 54: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 57: return .maskAlphaShift
        default: return nil
        }
    }

    /// Arrow keys are fn+arrow on real hardware, and macOS records its arrow
    /// shortcuts with the fn flag included. Without it a synthesised arrow is a
    /// plain arrow and never matches a shortcut.
    private static func flags(forKey code: CGKeyCode, _ flags: CGEventFlags) -> CGEventFlags {
        var out = flags
        if (123...126).contains(Int(code)) { out.insert(.maskSecondaryFn) }
        return out
    }

    private func postChord(code: CGKeyCode, flags: CGEventFlags) {
        let modifiers: [(CGEventFlags, CGKeyCode)] = [
            (.maskControl, 59),
            (.maskAlternate, 58),
            (.maskShift, 56),
            (.maskCommand, 55)
        ].filter { flags.contains($0.0) }

        for (flag, key) in modifiers {
            setModifier(key, flag, down: true)
        }
        if !modifiers.isEmpty { usleep(30_000) }

        let keyFlags = InputInjector.flags(forKey: code, flags).union(heldModifiers)
        postKeyEvent(code, down: true, flags: keyFlags)
        usleep(15_000)
        postKeyEvent(code, down: false, flags: keyFlags)

        if !modifiers.isEmpty {
            usleep(30_000)
            for (flag, key) in modifiers.reversed() {
                setModifier(key, flag, down: false)
            }
        }
    }

    /// Mission Control and space switching are keyboard shortcuts, and on many
    /// Macs they are switched off. Mission Control is also an app, so it can be
    /// opened directly regardless of the user's shortcut bindings.
    private func performHostAction(_ name: String) {
        switch name {
        case "missionControl":
            run("/usr/bin/open", ["-a", "Mission Control"])
        default:
            break
        }
    }

    static func enableWindowShortcuts() {
        // Standard bindings: ⌃↑ Mission Control, ⌃↓ App windows, ⌃←/⌃→ spaces.
        // 8650752 is fn + control; the arrow keys carry the fn flag.
        let bindings: [(String, Int, Int)] = [
            ("32", 126, 8650752),
            ("33", 125, 8650752),
            ("36", 123, 8650752),
            ("37", 124, 8650752)
        ]
        for (key, code, modifiers) in bindings {
            let value = "{enabled = 1; value = {parameters = (65535, \(code), \(modifiers)); type = standard;};}"
            run("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys",
                                      "AppleSymbolicHotKeys", "-dict-add", key, value])
        }
        run("/usr/bin/killall", ["cfprefsd"])
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func run(_ path: String, _ arguments: [String]) {
        InputInjector.run(path, arguments)
    }

    /// Modifiers must be `flagsChanged` events, not keyDown: only then does the
    /// system treat the modifier as held for the events that follow.
    private func setModifier(_ code: CGKeyCode, _ flag: CGEventFlags, down: Bool) {
        if down { heldModifiers.insert(flag) } else { heldModifiers.remove(flag) }
        guard let event = CGEvent(source: source) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        event.flags = heldModifiers
        event.post(tap: .cghidEventTap)
    }

    private func postKeyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func setButton(_ button: CGMouseButton, down: Bool, at point: CGPoint) {
        let isLeft = button == .left
        let type: CGEventType
        if isLeft {
            type = down ? .leftMouseDown : .leftMouseUp
            leftDown = down
        } else {
            type = down ? .rightMouseDown : .rightMouseUp
            rightDown = down
        }
        if let e = CGEvent(mouseEventSource: source, mouseType: type,
                           mouseCursorPosition: point, mouseButton: button) {
            // Click state of 1 is a single click; macOS synthesises double clicks
            // from timing, so this stays correct for rapid taps.
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
        }
    }

    /// Releases anything held down, so a dropped connection doesn't leave a
    /// modifier or mouse button stuck.
    func releaseAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.virtualCursor = nil
            if self.leftDown { self.setButton(.left, down: false, at: self.resolveCursor()) }
            if self.rightDown { self.setButton(.right, down: false, at: self.resolveCursor()) }
            for key in [55, 54, 56, 60, 58, 61, 59, 62] {
                if let flag = InputInjector.modifierFlag(for: CGKeyCode(key)) {
                    self.setModifier(CGKeyCode(key), flag, down: false)
                }
            }
            self.heldModifiers = []
        }
    }

    // MARK: - Typing

    private struct KeyStroke {
        let code: CGKeyCode
        let shift: Bool
    }

    /// US layout. Typing with real keycodes (rather than Unicode string events)
    /// is what makes characters land in terminals, Electron apps and anything
    /// else that reads raw key events. Unicode is only the fallback for
    /// characters this table does not cover.
    private static let keyMap: [Character: KeyStroke] = {
        var map: [Character: KeyStroke] = [:]

        let letters: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
            "j": 38, "k": 40, "n": 45, "m": 46
        ]
        for (character, code) in letters {
            map[character] = KeyStroke(code: code, shift: false)
            map[Character(String(character).uppercased())] = KeyStroke(code: code, shift: true)
        }

        func add(_ characters: String, _ code: CGKeyCode, shift: Bool = false) {
            for character in characters { map[character] = KeyStroke(code: code, shift: shift) }
        }

        add("1234567890", 18)
        map["1"] = KeyStroke(code: 18, shift: false)
        map["2"] = KeyStroke(code: 19, shift: false)
        map["3"] = KeyStroke(code: 20, shift: false)
        map["4"] = KeyStroke(code: 21, shift: false)
        map["5"] = KeyStroke(code: 23, shift: false)
        map["6"] = KeyStroke(code: 22, shift: false)
        map["7"] = KeyStroke(code: 26, shift: false)
        map["8"] = KeyStroke(code: 28, shift: false)
        map["9"] = KeyStroke(code: 25, shift: false)
        map["0"] = KeyStroke(code: 29, shift: false)

        map["!"] = KeyStroke(code: 18, shift: true)
        map["@"] = KeyStroke(code: 19, shift: true)
        map["#"] = KeyStroke(code: 20, shift: true)
        map["$"] = KeyStroke(code: 21, shift: true)
        map["%"] = KeyStroke(code: 23, shift: true)
        map["^"] = KeyStroke(code: 22, shift: true)
        map["&"] = KeyStroke(code: 26, shift: true)
        map["*"] = KeyStroke(code: 28, shift: true)
        map["("] = KeyStroke(code: 25, shift: true)
        map[")"] = KeyStroke(code: 29, shift: true)

        add("-", 27); add("_", 27, shift: true)
        add("=", 24); add("+", 24, shift: true)
        add("[", 33); add("{", 33, shift: true)
        add("]", 30); add("}", 30, shift: true)
        add("\\", 42); add("|", 42, shift: true)
        add(";", 41); add(":", 41, shift: true)
        add("'", 39); add("\"", 39, shift: true)
        add(",", 43); add("<", 43, shift: true)
        add(".", 47); add(">", 47, shift: true)
        add("/", 44); add("?", 44, shift: true)
        add("`", 50); add("~", 50, shift: true)
        add(" ", 49)
        add("\t", 48)

        return map
    }()

    private func type(_ string: String) {
        for character in string {
            if character == "\n" || character == "\r" {
                postKey(36, shift: false)
                continue
            }
            if let stroke = Self.keyMap[character] {
                postKey(stroke.code, shift: stroke.shift)
            } else {
                postUnicode(String(character))
            }
        }
    }

    private func postKey(_ code: CGKeyCode, shift: Bool) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = shift ? .maskShift : []
            event.post(tap: .cghidEventTap)
        }
    }

    private func postUnicode(_ string: String) {
        var utf16 = Array(string.utf16)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { return }
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        event.post(tap: .cghidEventTap)
    }

    /// Verifies that a synthesised modifier actually registers system-wide before
    /// the following key event is posted. Flags alone on a synthetic key event
    /// are not reliable: the window server can drop them.
    func modifierStateTest() -> [String] {
        var out: [String] = []
        let source = CGEventSource(stateID: .hidSystemState)

        CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: true)?.post(tap: .cghidEventTap)
        usleep(60_000)
        let down = CGEventSource.flagsState(.combinedSessionState)
        out.append("after control down: flags=\(down.rawValue) control=\(down.contains(.maskControl))")

        CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(60_000)
        let up = CGEventSource.flagsState(.combinedSessionState)
        out.append("after control up: flags=\(up.rawValue) control=\(up.contains(.maskControl))")

        out.append("flag-only event path is what the chord buttons used before")
        return out
    }

    // MARK: - Diagnostics

    /// Tries the known ways of moving the cursor and reports which one actually
    /// takes effect. Run with REMOTEMAC_SELFTEST=1.
    func selfTest() -> [String] {
        var results: [String] = []
        func position() -> String {
            guard let e = CGEvent(source: nil) else { return "nil" }
            return "(\(Int(e.location.x)),\(Int(e.location.y)))"
        }
        let start = CGEvent(source: nil)?.location ?? .zero
        results.append("start \(position()) trusted=\(AXIsProcessTrusted())")

        func attemptQueued(_ name: String, stored: Bool, dx: CGFloat, dy: CGFloat) {
            queue.sync {
                let before = CGEvent(source: nil)?.location ?? .zero
                let target = CGPoint(x: before.x + dx, y: before.y + dy)
                let source = stored ? self.source : CGEventSource(stateID: .hidSystemState)
                let sourceState = source == nil ? "NIL" : "ok"
                results.append("  source for \(name): \(sourceState)")
                let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                    mouseCursorPosition: target, mouseButton: .left)
                event?.post(tap: .cghidEventTap)
                usleep(120_000)
                let after = CGEvent(source: nil)?.location ?? .zero
                let moved = abs(after.x - before.x) > 2 || abs(after.y - before.y) > 2
                let label = moved ? "MOVED" : "no effect"
                let beforeText = "(\(Int(before.x)),\(Int(before.y)))"
                let afterText = "(\(Int(after.x)),\(Int(after.y)))"
                results.append("\(name): \(label) \(beforeText)->\(afterText)")
            }
        }
        attemptQueued("queue + stored source (+100)", stored: true, dx: 100, dy: 0)
        attemptQueued("queue + fresh source  (+100)", stored: false, dx: 100, dy: 0)
        attemptQueued("queue + stored source (-100)", stored: true, dx: -100, dy: 0)

        func attempt(_ name: String, _ body: () -> Void) {
            let before = CGEvent(source: nil)?.location ?? .zero
            body()
            usleep(150_000)
            let after = CGEvent(source: nil)?.location ?? .zero
            let moved = abs(after.x - before.x) > 2 || abs(after.y - before.y) > 2
            results.append("\(name): \(moved ? "MOVED" : "no effect") -> \(position())")
        }

        let target = CGPoint(x: start.x + 120, y: start.y + 80)

        attempt("hidSystemState + cghidEventTap") {
            CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                    mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        attempt("combinedSessionState + cgSessionEventTap") {
            CGEvent(mouseEventSource: CGEventSource(stateID: .combinedSessionState),
                    mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cgSessionEventTap)
        }
        attempt("nil source + cghidEventTap") {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        attempt("CGWarpMouseCursorPosition") {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(target)
        }
        attempt("leftMouseDown/Up at target") {
            let source = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                    mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                    mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(start)
        return results
    }

    private static func chunks(of string: String, limit: Int) -> [String] {
        guard string.count > limit else { return [string] }
        var result: [String] = []
        var current = ""
        for character in string {
            current.append(character)
            if current.count >= limit { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
