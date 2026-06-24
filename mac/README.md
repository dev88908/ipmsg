# IP Messenger for macOS

A native macOS client that is **wire-compatible with IP Messenger for Win32**
(the code in the parent directory). It speaks the classic IP Messenger
"version-1" protocol, so macOS and Windows machines see each other on the same
LAN and can exchange text messages and files — no changes to the Windows app.

This is a separate Swift project; it does **not** modify the Windows sources.

## What works

| Feature | Status |
|---|---|
| Auto-discovery (`BR_ENTRY` / `ANSENTRY` / `BR_ABSENCE` / `BR_EXIT`) | ✅ |
| Member list with nickname / group / host / IP, online & absence state | ✅ |
| Send / receive text messages (UTF-8, interoperates with Windows) | ✅ |
| Delivery confirmation (`SENDCHECK` → `RECVMSG`) | ✅ |
| Send files to a peer (peer pulls them over TCP `GETFILEDATA`) | ✅ |
| Receive / download attached files from a peer | ✅ |
| Directory-tree transfer (`GETDIRFILES`) | ⛔ not yet (regular files only) |
| Encryption (RSA/Blowfish/AES) and sealed messages | ⛔ not yet |

Discovery and messaging are verified at runtime against the protocol
(`scripts/probe.swift` simulates a peer and checks the answers).

## Build & run

```bash
cd mac

# Quick run during development:
swift run IPMsgMac

# Or build a distributable .app (recommended — see permission note below):
./scripts/build-app.sh release
open "build/IP Messenger.app"

# Tests:
swift test
```

### macOS Local Network permission

On first launch macOS asks for **Local Network** access — this is required for
UDP broadcast discovery. Allow it. If discovery shows no members, check:
System Settings → Privacy & Security → Local Network → enable "IP Messenger".

Run from the `.app` bundle (not a bare `swift run` binary) so the permission
prompt and `NSLocalNetworkUsageDescription` work correctly.

### Firewall / port

Uses UDP **2425** (messages) and TCP **2425** (file transfer), the IP Messenger
defaults. Make sure both machines are on the same subnet and the port is not
blocked by a firewall.

## Architecture

```
Sources/
  IPMsgCore/            ← protocol + networking engine (no UI, unit-tested)
    Protocol.swift        command codes & option flags (mirror src/ipmsg.h)
    Packet.swift          encode/decode of the version-1 datagram
    UDPSocket.swift       broadcast UDP socket + interface enumeration
    FileTransfer.swift    TCP file server (send) + downloader (receive)
    Models.swift          Peer / ChatMessage / AttachedFile / identity
    IPMessenger.swift     the engine, an ObservableObject for SwiftUI
  IPMsgMac/             ← SwiftUI front-end
    IPMsgMacApp.swift     @main app
    ContentView.swift     member list + conversation + attachments
Tests/IPMsgCoreTests/   ← packet/file-list round-trip tests
```

## Protocol notes (compatibility)

* Datagram format: `ver:packetNo:user:host:command:<additional>` — only the
  first 5 `:` are the header; the body may contain `:`.
* The additional section is NUL-separated: `body \0 fileList` for `SENDMSG`,
  and `nick \0 group \0 \nUN:..\nHN:..\nNN:..\nGN:..\nVS:..` for entry packets.
* We advertise `CAPUTF8` + `FILEATTACH` on entry and send messages with `UTF8`,
  matching modern Windows IP Messenger.
* File records: `fileID:name:sizeHex:mtimeHex:attrHex:` separated by `\a`.
  Files are pulled by the receiver via a TCP `GETFILEDATA` request whose body is
  `packetID:fileID:offset` (hex); the sender then streams raw bytes.

See `../protocol.txt` / `../prot-eng.txt` for the full specification and
`../src/ipmsg.h` for the authoritative command constants.
