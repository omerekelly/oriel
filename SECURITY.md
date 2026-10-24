# Security

## Threat model

Oriel is built for one person reaching their own Mac over their own tailnet.

- **Transport.** All traffic crosses the Tailscale tunnel, which is WireGuard:
  encrypted and authenticated. Oriel itself does not add a second transport
  encryption layer, and does not need to.
- **Exposure.** The host binds to `0.0.0.0:7801`. Reachability is constrained by
  Tailscale — the host is not reachable from the public internet unless you
  deliberately expose it. **Never port-forward 7801 or put the host on a public
  address.** Use Tailscale, or a tunnel that terminates authentication in front
  of it.
- **Authorisation.** A client must present the pairing code shown in the host's
  menu bar. Codes are 8 characters from a 32-symbol alphabet (~40 bits) and can
  be reset, which invalidates existing clients. Without the code, a peer is
  disconnected immediately after the handshake.
- **Device trust.** The pairing code assumes your tailnet is already trustworthy.
  Anyone who can add a device to your tailnet can attempt to guess a code; if
  that is a concern, reset the code and audit your tailnet's ACLs.

## What Oriel does not protect against

- A compromised device already on your tailnet.
- A compromised Mac: an attacker with local access can read the pairing file.
- Anything the remote session itself does. Once paired, the client has full
  pointer and keyboard control, which means it can run anything you can.

## Reporting

Please open a private security advisory rather than a public issue, or email the
maintainer listed in the repository profile. Include the version, macOS/iOS
versions, and steps to reproduce.

There is no bug bounty.
