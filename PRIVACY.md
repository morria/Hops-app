# Hops Privacy Policy

_Last updated: August 26, 2026_

Hops is a messaging client for Meshtastic® LoRa radios. It is built to work
entirely off-grid, and its privacy posture matches:

## What we collect

**Nothing.** Hops has no servers, no accounts, no analytics, no ads, and no
trackers. The developer receives no data from the app.

## Where your data lives

- **On your devices.** Messages, contacts (mesh nodes), and settings are
  stored locally on your iPhone or iPad.
- **In your private iCloud.** If iCloud is enabled, Hops syncs your messages
  and settings between your own devices through your personal iCloud account
  (CloudKit). The developer cannot read this data — it is governed by
  Apple's iCloud terms and privacy policy.
- **On the mesh.** Anything you send by radio (messages, position shares,
  node info, Meshsite requests) is broadcast over LoRa to other Meshtastic
  radios. Direct messages use end-to-end encryption when both radios have
  exchanged keys; channel messages are encrypted with the channel's shared
  key. Radio traffic is, by nature, receivable by anyone in RF range running
  compatible hardware.

## Location

If you grant location access, Hops uses your position to center the map,
share your location when you explicitly send it, and record coverage
samples stored only on your device. Location is never sent to the developer.

## Contact

Questions: open an issue at https://github.com/morria/Hops-app

Meshtastic® is a registered trademark of Meshtastic LLC.
