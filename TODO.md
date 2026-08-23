# Hops TODO

Working list from on-device testing. Items stay here until resolved.

## Open

(nothing currently)

33. [x] Telemetry broadcast interval is configurable (Settings → Device
        configuration → Telemetry): battery/device-metrics interval from the
        firmware-default 30 minutes up to 24 hours, with the community-
        recommended 6 hours called out. Writes the telemetry module config via
        admin.

32. [x] iPad support: universal device family, all iPad orientations; tab bar,
        custom Chats header, and all screens verified in the iPad simulator.
        Installed on "Book" (iPad mini). Full-width layout for now; a proper
        split-view (list + conversation side-by-side) is a candidate future item.

31. [x] Default reactions render as a horizontal row in the long-press menu
        (palette control group), like iMessage's tapback bar.
30. [x] Reaction pill is anchored to the message bubble's top corner (opposite
        the sender side), not floating by the avatar. Verified in simulator.
29. [x] Tapping a sender's avatar or name in a channel transcript opens their
        node card (battery, hops, signal) with a Message action that jumps to a
        DM.

28. [x] Node card action buttons: Message and Directions now share identical
        structure (explicit titleAndIcon labels, large control size, capsule
        shape, equal min-height) so they align and both show icons.

27. [x] Search and compose share one line, iMessage-style, in a custom header.
26. [x] "Chats" title is top-aligned (custom header replaces the nav bar on the
        root list; pushed screens keep their bars). Verified in simulator.
25. [x] Manual LoRa editor (Settings → Device configuration → LoRa Radio):
        region, modem preset, frequency slot, hop limit; matching a known metro
        preset re-adopts it automatically via inference.

24. [x] Pinned grid: leading-aligned cells so the first pinned avatar lines up
        with the conversation-row avatars; names center under their own avatar.
        Verified in simulator.

## Resolved (23+)

23. [x] Device configuration in Settings: Bluetooth (enabled, pairing mode, fixed
        PIN — with a warning that disabling BT strands Hops), Display (screen
        timeout, units, 12h clock, flip, compass, wake-on-tap), Position (GPS
        mode, fixed position, broadcast interval, smart broadcast with distance/
        interval). Values load from the connect-time config dump; saves write one
        Config section via admin.

## Resolved

1. [x] Chats search: now searches all known nodes (not just existing conversations) —
       results ordered Conversations → Nodes → Messages; tapping a node with no
       history starts the DM. (ChatsListView `searchResults`)
2. [x] Conversation rows: whole row is now tappable
       (`.frame(maxWidth:.infinity)` + `.contentShape(Rectangle())`).
3. [x] Compose picker rows (channels and people): whole row tappable, same fix.
4. [x] Send button dead in brand-new conversations: the destination was derived from
       the ConversationEntity, which doesn't exist before the first message. Now
       derived directly from the conversation key ("dm-<num>" / "ch-<idx>"), with
       title fallback from the node/channel tables. Verified: entity-less thread
       renders with correct title and live composer.
5. [x] Metro preset audit against community pages:
       - NYC (nyme.sh/getting-started): MediumSlow, **slot 48**, **hop limit 7**
         ("relies on this being the maximum of 7"), AQ== primary key. Role guidance
         (Client Mute handheld / Client stationary) noted in the preset summary —
         Hops writes LoRa config only.
       - Bay Area (bayme.sh): MediumFast, slot 45, **hop limit 6** for
         personal/chat nodes (was wrongly 3).
       - Standard: LongFast defaults (slot 0, hop 3) — correct.
       Manifest bumped to version 2.
22. [x] "Mesh traffic" in Settings is now a live log: every decoded packet appears
        newest-first with sender short name, port tag, per-port summary (message
        text, coordinates, ACK/NAK + packet id, battery, waypoint name), and
        time; encrypted packets Hops can't decode are logged as such. Capped at
        200 entries, session-only.
21. [x] GPL-3.0 LICENSE added (required by the bundled Meshtastic protobufs) and
        the app pushed to the public repo git@github.com:morria/Hops-app.git.
20. [x] Channel editor in Settings → Channels: create/edit name, encryption key
        (default AQ== / random 256-bit / open), remove secondary channels; writes
        to the radio via admin, primary channel role protected.
19. [x] NYC channel icon: when the radio's live LoRa config exactly matches a
        metro preset and no application was recorded (pre-tracking builds), the
        preset is now inferred and adopted on config receipt — icon appears after
        the next connect. Chats list now also observes the preset store, so the
        icon updates live.
18. [x] Settings: Disconnect/Connect button — persists across relaunch, suppresses
        auto-reconnect until Connect is tapped; radio card shows "Disconnected".
17. [x] Tapping a reaction pill opens a sheet listing each reaction with sender
        avatar, name ("You" for own), emoji, and time.
16. [x] DM (and channel) title bars show the avatar/icon beside the name via a
        principal toolbar item.
15. [x] Per-conversation notification level — All Messages / Mentions Only /
        Muted — via long-press menu (picker) and swipe (quick mute toggle).
        Mentions Only matches "@" + your short/long name, case-insensitive, and
        only ever raises (never suppresses All). List rows show a slashed bell
        (muted) or @ badge (mentions only); legacy boolean mutes backfilled.
14. [x] Swipe-left on a transcript reveals per-message send times (iMessage-style):
        bubbles slide with the drag, times fade in at the trailing edge, springs
        back on release.
13. [x] Channel transcripts show the sender's monogram avatar beside each incoming
        bubble with their short name above — group-chat style. Verified.
12. [x] Any-emoji reactions: "More…" in the reaction menu opens a picker sheet
        (common-emoji grid + free-typing field via the emoji keyboard), noting
        that mesh reactions can't be removed.
11. [x] "No messages on primary channel": audited the full decode/present path
        (frame → FromRadio → port dispatch → store → @Query) against the official
        app's handling — sound. Prime suspect is radio config from the pre-fix NYC
        preset (slot 0 ≠ 48 → wrong frequency, hears nothing). Added: a "Mesh
        traffic" diagnostics row in Settings (packets/messages heard since launch,
        orange when zero — decisively separates "radio hears nothing" from "app
        drops messages"), an orange re-apply warning when the radio's LoRa config
        drifts from the applied metro preset, and slot + hop limit now always
        visible in Mesh Setup.
10. [x] Map de-overlap jitter: nodes sharing a coordinate (~11 m grid) are spread
        on a deterministic ring — members sorted by node num, evenly spaced, ring
        radius 40 m for exact stacks or up to 20% of the precision circle (max
        200 m) for fuzzed positions. Isolated nodes stay exact; precision circles
        remain centered on the true coordinate.
9. [x] Conversations with only a failed/unsent message now appear in the list.
       Root cause: persistOutgoing re-fetched the conversation it had just created
       in the same transaction; the fetch could miss it, leaving lastMessageAt nil
       and the row filtered out. Now stamps the held object directly, plus a
       startup repair pass backfills any conversation stranded by the old bug.
8. [x] Settings pull-to-refresh: sends a heartbeat, a direct telemetry request to
       the radio (fresh battery/metrics), and forces a node-DB re-request so all
       device info updates; pulls while disconnected kick a reconnect instead.
7. [x] Map node panel now shows the same info as the DM info sheet: one shared
       `NodeCardView` (identity, last heard, battery, hops away, SNR) with a
       Message action (map, messageable nodes only) and Directions (any node
       with a position) — the two divergent cards were deleted.
6. [x] Map node panel "Message" did nothing: it set the pending conversation but
       never left the Map tab, and the hidden Chats tab couldn't react. Tab
       selection moved into AppModel; the button now switches to Chats and opens
       the thread (also consumed in `onAppear` if Chats wasn't built yet).
       Notification taps got the same tab-switch fix for free.
