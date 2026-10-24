# Contributing

Thanks for looking. This project is small and deliberately dependency-free, so
the bar for changes is mostly: does it work on a real device, and is it
explained where it is surprising.

## Getting set up

```bash
git clone <repo> && cd oriel

# Protocol tests (no signing, no device, fastest signal)
swift test

# Host app
./Host/build.sh && open build/Oriel.app

# Headless verifier
./Tools/build-probe.sh

# iOS project
brew install xcodegen
cd Client && xcodegen generate
open OrielClient.xcodeproj
```

The Xcode project is generated and not committed. Add files to the filesystem
and re-run `xcodegen generate`; do not hand-edit the `.xcodeproj`.

## Before opening a pull request

1. `swift test` passes.
2. `./Host/build.sh` builds clean.
3. For anything touching capture, encoding, transport or input: run the probe and
   confirm frames and input still work.

   ```bash
   ./build/probe --host 100.x.y.z --token <code> --seconds 6 --out /tmp/f.png
   ./build/probe --host 100.x.y.z --token <code> --chord ctrl-left
   ```

4. For iOS UI changes, run on a device or the simulator — not just a compile.

Screenshots or a short clip in the PR are worth more than a description.

## Where things live

| Area | File |
|---|---|
| Wire format, message types | `Shared/Protocol.swift` |
| Capture + encode | `Host/CaptureEngine.swift` |
| Socket server, framing | `Host/ConnectionServer.swift` |
| Mouse + keyboard synthesis | `Host/InputInjector.swift` |
| Pairing codes | `Host/Pairing.swift` |
| Menu bar, wiring | `Host/AppDelegate.swift` |
| Connection state | `Client/Oriel/ClientSession.swift` |
| Decode + render + gestures | `Client/Oriel/{SampleBuilder,StreamSurface}.swift` |
| Session UI | `Client/Oriel/SessionView.swift` |

## Style

- Swift 5 language mode. The code uses GCD and manual queues rather than actors;
  match the surrounding style rather than mixing models.
- No third-party packages. `Network`, `VideoToolbox`, `AVFoundation`, `AppKit`,
  `UIKit` and `SwiftUI` only.
- Prefer a comment that explains *why* over one that restates *what*. The
  hardware and TCC quirks in this codebase are not obvious, so they are
  documented at the point they bite.

## Changing the protocol

`Shared/Protocol.swift` is compiled into the host, the client and the test
target. If you add a message type, add a test for its framing and keep the
length-prefixed envelope intact — the decoder is fuzz-tested against arbitrary
chunk boundaries.

Bump `ProtocolLimits.version` for breaking changes and expect old clients to be
rejected rather than half-supported.

## Licence

Contributions are accepted under Apache-2.0.
