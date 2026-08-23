# Hops (iOS)

A fast, familiar messaging app for a single Meshtastic radio. See
[docs/PRODUCT_VISION.md](docs/PRODUCT_VISION.md) for the full product vision and the
adversarial-review appendix that shaped it.

## Building

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd ios
xcodegen generate        # regenerate Hops.xcodeproj after adding/removing files
open Hops.xcodeproj      # build & run the Hops scheme
```

Simulator builds work (`CODE_SIGNING_ALLOWED=NO`), but Bluetooth requires a real
device — set your signing team in project.yml (or Xcode) for device installs.

## Layout

- `Hops/Radio/` — CoreBluetooth transport (`BLETransport`), session/handshake/send
  (`RadioManager`), channel-URL codec (`MeshURL`). Handshake is messages-first:
  config (nonce 69420) → drain the radio's queued packets → node DB (69421) deferred.
- `Hops/Store/` — SwiftData models and the `MessageStore` model actor (all
  radio-driven writes; views read via `@Query`).
- `Hops/Views/` — Chats / Conversation / Map / Settings / Pairing.
- `Hops/Presets/` + `Hops/Resources/metro-presets.json` — versioned metro mesh
  presets (NYC, Bay Area, Standard). Point `MetroPresetStore.remoteURL` at a
  maintained manifest to ship preset updates without an app release.
- `MeshtasticProtobufs/` — generated Swift protobufs from the Meshtastic project
  (GPL-3.0; see Licensing).

## Screenshot / dev mode

Debug builds accept launch arguments (used for simulator verification, where BLE
doesn't exist):

```sh
xcrun simctl launch <device> com.w2asm.hops -screenshots            # demo data, no permission prompt
xcrun simctl launch <device> com.w2asm.hops -screenshots -tab map   # or settings
xcrun simctl launch <device> com.w2asm.hops -screenshots -conversation dm-10597059
```

Simulating a paired radio: `xcrun simctl spawn <device> defaults write com.w2asm.hops
pairedPeripheralId <any-uuid>` skips onboarding.

## Device checklist (not yet verified on hardware)

- Pair → PIN sheet → handshake → channels/conversations appear.
- Background wake: `bluetooth-central` mode + state restoration
  (`com.w2asm.hops.central`) + pending connect re-armed on disconnect.
- Communication notifications need the `com.apple.developer.usernotifications.communication`
  entitlement added to signing before sender avatars/Siri announcements work.
- Admin writes (name, metro preset, channel import) reboot the radio; Hops
  reconnects via the pending connect.

## Licensing

Hops is licensed under **GPL-3.0** — see [LICENSE](LICENSE). This follows from
`MeshtasticProtobufs/`, generated from the GPL-3.0
[meshtastic/protobufs](https://github.com/meshtastic/protobufs) (copied from
[Meshtastic-Apple](https://github.com/meshtastic/Meshtastic-Apple)), which any
distribution of Hops inherits. The NYC Mesh channel icon is the
[nyme.sh](https://nyme.sh) community logo.
