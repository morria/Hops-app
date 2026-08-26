# Hops TODO

Working list from on-device testing. Items stay here until resolved.

## Open

139. [x] Sites no longer vanish after time away: beacons come every 5 min
         and the expiry window is 20 (4x headroom), but the clock kept
         counting while we weren't listening — any 20-minute BLE drop or
         app close expired every site at the next glance. The prune now
         runs only while connected, and only once the session is a full
         window old, so reconnects grant known sites a fresh chance to be
         heard. (Note: a phone-served site really does stop beaconing while
         that phone is backgrounded — iOS suspends its timer.)

138. [x] Meshsite pages load instantly from cache: only back-nav was
         cache-first — following a link to an already-seen page (or re-
         opening a site) always did an etag revalidate, a full mesh round
         trip even when the answer was NOT_MODIFIED. All GET navigation now
         serves a fresh cache hit (24 h) with zero airtime; the Refresh
         button is the explicit revalidate. Cache is per-launch (in-memory).

137. [x] Meshsite browser shows a single back button: the site's own
         history chevron replaces the app back button (browser-style — walks
         site pages first, pops back to the app from the root). Also usable
         mid-load to escape a slow page: it cancels the in-flight fetch.

136. [x] The tapback palette closes its menu again: palette-style controls
         in a context menu don't auto-dismiss it — the reaction row now
         forces dismissal on pick (menuActionDismissBehavior).

135. [x] Channel transcripts show name/photo overrides immediately: row
         snapshots only rebuilt on message changes, so an override set from
         the sender's node card kept the stale monogram/name until the next
         message arrived. Closing the card now rebuilds the window.

134. [x] Node card keeps the mesh-reported identity visible while a local
         override is active: "Mesh short name" / "Mesh long name" rows appear
         whenever a custom name or photo is set — that's what everyone else
         on the mesh still sees.

133. [x] Notification taps navigate again after a cold launch: the tap
         handler could fire before the UI wired up the deep-link closure
         (openConversation was nil → silently dropped). The key is now
         buffered and flushed the moment the handler is set.

132. [x] A meshsite no longer vanishes from Nearby Sites right after you
         load it: page traffic (chunks / errors / NOT_MODIFIED) now counts
         as liveness, so the 20-minute beacon prune can't remove a server
         you just successfully fetched from.

131. [x] Tapping search with an empty query browses the entire node database:
         a scrollable "All Nodes" list (recently heard first, snapshotted on
         entry — no standing query), reusing the search-result node row.
         Search is now a sticky mode with a Cancel button, so scrolling the
         list (which dismisses the keyboard) no longer kicks you back to
         conversations.

130. [x] Adversarial pass on delivery/read states — 10 findings, all fixed:
         Live Activities now mirror the store verdict (no more false
         "Delivered" on weaker evidence, channel sends can never claim it);
         released/force-sent holds restart the timeout clock (was: insta-
         failed "No response" within 60s); terminal success is sticky vs late
         NAKs; the stale-sending sweep only fast-fails packets THIS device
         transmitted (CloudKit bystanders get a 1h stray net); own-broadcasts
         heard via a second radio no longer ring your own bell; dedupe keeps
         the best status not the highest raw value; routing results must be
         addressed to us; retries migrate reactions/replies and end the old
         Live Activity; reads go through the shared store actor + manual
         toggles refresh the badge; Meshsites served-counter only counts
         completed transfers.

129. [x] Reset Encryption Key action on the node card (Security section,
         confirmed destructive): clears the pinned pubkey + keyChanged so a
         legitimately re-keyed node (reflashed radio) can re-announce.
         First-key-wins now has its escape hatch.

128. [x] Device Configuration saves are transactional (beginEditSettings /
         commitEditSettings) — back-to-back setConfig writes were racing the
         firmware·s save+reboot and later sections were silently dropped.

127. [x] Mesh Relay setting in Device Configuration: rebroadcast_mode picker
         (All / skip-decoding / Local / Known / Never / Core ports only) with
         read-modify-write via the device-config mirror so the role is never
         clobbered; footer warns Core-ports-only silently drops app traffic
         like Meshsites before it reaches Hops.

126. [x] Mesh traffic row no longer wraps: compact counts (pkts/msgs) and
         short relative time (15s/3m/2h ago); trailing-aligned if it ever
         does wrap.

125. [x] Site rows wear the serving node·s avatar (short-name monogram or
         custom icon) instead of a generic globe — own site and deprecated
         rows included.

124. [x] Sites tab (Meshsites builds, toggle on): Messages · Sites · Map ·
         Settings. Stable tab tags; toggling off bounces to Messages;
         redundant Settings link removed.

123. [x] Nearby Sites shows your own site while serving ("This phone —
         served by you"), opening through the local serving engine.

122. [x] Messages search covers everything: conversations, message text, and
         ALL known nodes (dropped the isMessageable filter that hid routers/
         repeaters/sensors from discovery), plus hex node-id search
         ("!073758f2" or any 4+ hex chars) for factory-named nodes.

121. [x] Delivery Details: long-press any message → info sheet with the
         status in plain language (what it proves and does not), failure
         reason decoded from the routing error, timestamps, packet ID
         cross-referencing Mesh Traffic, and a primer on direct vs channel
         delivery.

120. [x] Coverage map readability: four discrete color bins (node reach
         palette) replace the continuous hue whose olive mids blended into
         satellite terrain; two opacity levels kill the confidence
         checkerboard; grid origin snapped to world coordinates so panning
         slides over a stable surface; legend chip (top-left) explains bins
         and measured-signal dots.

119. [x] Map filters: hop count (any/direct/1/2/4) and max age (any/1h/6h/
         24h/7d) via a filter button above the layers control, applied to
         Nodes and Weather layers. Persisted in AppStorage; filled icon +
         accent tint when active; Clear Filters shortcut.

118. [x] Meshsite serving on iOS (dev builds only): the phone serves its own
         site. Pages are markdown files in iCloud Drive › Hops › Meshsite
         (Files-app visible, Mac-editable); My Site screen with serve toggle
         + beacon status; page editor with live compressed-bytes gauge and
         link/form insertion; every POST lands in _replies.md (private "_"
         namespace, 128 KB tail trim) + in-app inbox; Preview runs the real
         serving engine. Spec draft 6. Reviewed: 1 critical (placeholder
         overwrite data loss), 2 major, 9 minor — all fixed.

117. [x] Meshsites (experimental, dev builds only): protocol spec in
         docs/MESHSITES.md (port 421, direct-RF-only via hop-limit 1 +
         relay-discard, one-packet requests, deflate chunks, etag caching
         with NOT_MODIFIED, Meshdown pages with forms). Client: passive
         beacon discovery, browser with back/refresh, GET/POST forms, page
         cache. Settings toggle default off; AppStore build config strips
         the code from public distributions. Python server lives in the
         parent repo meshsites/. Both sides cross-reviewed; spec draft 5.

116. [x] Link topology feeds the coverage prediction: BFS over NeighborInfo
         edges + our direct links refines hop estimates (observed paths beat
         the flood counter), and each RF link contributes corridor evidence at
         30/50/70% along the segment so space between linked nodes gets color.

115. [x] Coverage is an interpolated contact-prediction surface: IDW over node
         hop counts + measured SNR samples, gridded per viewport (recomputed on
         pan/zoom, debounced), hue green→red by expected hops, opacity by
         evidence density, transparent beyond ~1.5 km of any evidence.

114. [x] Coverage layer reworked to match the real mental model: citywide reach
         blobs around every node heard in 24 h, colored by hop distance from
         you (green direct → orange far → gray unknown), with personal measured
         SNR dots on top as ground truth. No walking required.

113. [x] Location prompt also fires when the map launches already in the
         Coverage layer (persisted mode skipped the switch-based prompt).

112. [x] Coverage samples render as screen-space dots (constant pixel size at
         any zoom) — 60 m geographic circles were sub-pixel at city scale;
         layer switches refresh snapshots immediately instead of waiting for
         the timer.

111. [x] Coverage was waiting for location permission nothing ever requested:
         entering the Coverage layer now prompts/warms a fix, app-activation
         warms the cache when authorized, and the empty state says exactly
         what's blocking (permission button; Battery Saver notice).

110. [x] Battery pass. Free wins: SwiftData saves debounced to one per ~2 s on
         high-frequency paths (was a disk write per packet heard — the main
         background drain), reconnect scan-assist time-boxed to 45 s, map
         snapshot timer paused when the Map tab is hidden. Battery Saver toggle
         (auto-follows iOS Low Power Mode): pauses coverage sampling and Live
         Activities, map refresh 5 s → 30 s, skips scan-assist, save debounce
         2 s → 5 s. Messaging unaffected in either mode.

109. [x] "+" menu offers "Request Missed Messages" — only when an S&F router
         has heartbeated within 3 h, so the option can't be a dead button;
         replays dedupe on ingest.
108. [x] Channel "+" menu gains "Send My Node Info" — broadcasts on that
         channel with its encryption.

107. [x] Send Now on held messages hardened: works while syncing, and when
         disconnected it demotes the message to the outbox (sends at next
         connection) instead of silently doing nothing.

106. [x] Map base style chooser in the layers menu: Explore (standard), Hybrid,
         Satellite — persisted, all with realistic elevation.

105. [x] Failed DMs offer "Send When Their Radio Is Heard" alongside Retry Now
         (fresh packet id, parked in the held state, releases on hearing them).

104. [x] Sending scrolls to the sent message: a second scroll pass after layout
         settles (the immediate scroll fired before the new row had geometry).

103. [x] Coverage sampling works in the background: position comes from the
         radio's own GPS (arrives in the same packet flushes, ≤10 min fresh)
         or the phone's passively cached fix (≤5 min); active GPS only when
         the app is on screen. Pocket the phone, carry the radio, get a map.

102. [x] Long-press Send offers "Send When Their Radio Is Heard" (DMs); a plain
         tap always transmits immediately — the automatic 30-min hold heuristic
         from #98 is now opt-in.
101. [x] Radio-less messaging: "Use Without a Radio" skip in onboarding (with
         the iCloud-relay explanation); Settings gains "Pair a Radio…" to enter
         pairing later. Composes queue in the outbox and transmit via the other
         device's radio through the #99 mailbox sweep.

100. [x] Coverage survey map layer: while foregrounded, connected, and location-
         authorized, Hops records ≤1 sample per 30 s pairing your position with
         the best SNR heard; the Coverage layer paints them as green/yellow/red
         circles. 30-day/2000-sample retention; passive by design (never prompts
         for location, foreground only).

99. [x] Book-as-mailbox: a 60 s outbox sweep while connected sends messages
        that synced in from another device via iCloud — compose on the phone
        anywhere, the home device with the base radio transmits. Duplicate
        transmits share a packet id, which the mesh dedupes.
98. [x] Send-when-reachable: DMs to peers silent 30+ min are held
        ("Waiting for their radio — sends when it's heard") and released the
        moment any packet arrives from them; long-press offers Send Now.

97. [x] Live Activity extended to channel sends (was DM-only, which is why it
        never appeared for channel-first usage): channel broadcasts run the
        activity and terminate on the implicit ack as "Sent to mesh".

96. [x] Node retention setting (Settings → Node database): remove unheard nodes
        after 7/30/90/180 days or Never (default 90); renamed/photographed/
        messaged nodes always kept; trail samples cleaned with them; runs at
        launch and on setting change.
95. [x] Map at thousands of nodes: sort/de-overlap work runs on a 5 s snapshot
        cadence instead of every position-driven render; trails fetch on node
        selection instead of a standing whole-table query (plus #94's
        positioned-only query and 300-pin recency cap).

94. [x] Few-thousand-node scalability: Messages-list search no longer holds
        whole-table queries on all nodes/messages (which re-rendered the list on
        every packet heard) — search now runs on-demand DB fetches with 50-row
        limits pushed to SQLite. Map queries positioned nodes only and caps
        annotations at the 300 most recently heard (MapKit chokes beyond that).

93. [x] Conversation view performance: rows precompute into value snapshots
        (one sender fetch per window instead of 3 DB fetches per bubble render;
        shared NSDataDetector; cached linkified text, coordinates, tapbacks,
        reply previews, day separators); initial window is the newest 60
        messages with a Load Earlier button (anchor-preserving); markRead moved
        off the render path onto the store actor.

92. [x] Device telemetry can be shut off: "Off — never broadcast" option (an
        interval the radio never reaches; firmware has no boolean); long
        read-back intervals display as Off.

91. [x] Blank transcript when tapping the input: removed defaultScrollAnchor
        (known blank-content failure when the keyboard shifts the safe area);
        interactive keyboard dismissal added.
90. [x] Scroll landing a few messages up: explicit bottom scrolling on appear
        (with a second pass after async layout like map cards), on new
        messages, and on keyboard show.

89. [x] Trademark compliance: About screen carries the Meshtastic® registered-
        trademark disclaimer; app name stays "Hops" (no Meshtastic in branding
        per policy); "client for Meshtastic radios" phrasing reserved for
        descriptions. M-Powered badge available if wanted for marketing.

88. [x] Connection resilience pass: fixed the scan fallback that discovered but
        never connected (now a scan hit on the desired radio connects
        immediately); scan-assist runs alongside pending connects so whichever
        path is faster wins; a 20 s watchdog tears down stalled connect attempts
        and retries with fresh retrieval; TORADIO writes are serialized through
        a queue with 4x backoff retry on transient radio-buffer pressure
        (previously errors were only logged) and the queue clears on new
        sessions so stale frames can't fire.

87. [x] Map remembers its last layer (Nodes/Weather) and camera
        (center + zoom) across sessions; restored on open until changed.

86. [x] Settings → About links to the GitHub repo.

85. [x] Guided onboarding overhaul: Bluetooth-off state with guidance,
        troubleshooting tips after 12 s of empty scanning, staged
        connect/sync progress instead of dumping to an empty list, factory-name
        prompt ("What should the mesh call you?"), mesh setup as an onboarding
        step (gating Start Messaging when region unset), notification
        permission deferred until after first sync, one-time nodeinfo announce
        on completion. Existing installs skip it via migration flag.

84. [x] Weather pills carry no station label on the map; the name lives in the
        tap-through sheet.
83. [x] Temperatures render as whole degrees with a °F/°C picker in Settings →
        Units (defaults from locale; pills and sheet update live).

82. [x] Your own key fingerprint shows under Settings → Your name (same shared
        SHA-256 formatting as peer node cards, selectable text) so out-of-band
        comparison works both directions.

81. [x] Node sheet title is the node itself (avatar + name in the principal
        position); redundant "Node" label and duplicate header row removed,
        last-heard becomes a normal row.
80. [x] Tapping a node (or weather pill) pans the map so the pin sits in the
        upper half, clear of the sheet, preserving zoom.

79. [x] Map mode switcher is an Apple Maps-style floating layers circle above
        locate-me, opening a Nodes/Weather chooser. Mesh view dropped for now
        (NeighborInfo plumbing stays dormant in RadioManager for a revival).

78. [x] Mesh view shows connectivity only: your node (accent-ringed), direct
        0-hop neighbors, and NeighborInfo participants with edges — not the
        whole node database. Explanatory empty state when no links are known.

77. [x] Weather empty state is a readable material card instead of raw text
        over satellite imagery.
76. [x] Map mode picker: single clean material pill (no doubled backgrounds),
        max width, subtle shadow.

75. [x] Mesh Traffic hop/SNR row formatting: tight icon-text pairs, monospaced
        digits, consistent spacing.

74. [x] Composer accessory is now a "+" menu (Send My Location inside) so
        location can't be fat-fingered; extensible for future special sends.
73. [x] Map modes: Nodes / Weather / Mesh segmented control. Weather shows
        temp/humidity pills (locale units) for nodes with recent environment
        telemetry; tapping opens details with a Hide From Weather Map action.
        Mesh draws direct-neighbor edges from our node plus NeighborInfo-derived
        edges (opacity by SNR).
72. [x] Waypoint authoring: long-press the map (Nodes view) → composer with
        name, emoji grid, expiry → broadcast on primary channel; appears locally
        immediately.
71. [x] Position trails: samples recorded on ~25 m movement (24 h / 200-sample
        retention); opening a node's card draws its breadcrumb, fading with age.
70. [x] Live Activity experiment: outgoing DMs run a Dynamic Island/lock-screen
        activity — Sending… → Relayed by the mesh… → Delivered to their radio ✓
        (or Couldn't deliver), with stale-timeout safety. New HopsWidgets
        extension target.
69. [x] PKI legibility: lock badge in DM title bars (orange shield when the
        pinned key changed), Security section on the node card with encryption
        state, SHA-256 key fingerprint for out-of-band comparison, and a
        key-change warning. Key changes now flagged at ingest.
68. [x] Store & Forward auto-recovery: S&F router heartbeats tracked; on
        reconnect after ≥5 min away (router heard <3 h ago) Hops requests
        history for the offline window; replays ingest with content-based dedup
        (sender+text within 48 h) since replay packet ids/timestamps differ.

50. [x] Connection status (spinner + text) moved inline, right of the "Chats"
        title, instead of a centered capsule row below the search bar.
49. [x] Send-my-location works: proper async location provider (authorization
        flow, one-shot fix, denial alert). Sends coordinates as a visible text
        message (with delivery state) plus the standard waypoint for maps.
48. [x] Map renders with realistic elevation — zoomed out it's a globe.
47. [x] Pinch-zoom works over crowded pin fields: node pins switched from
        Buttons (which claimed touches on contact, eating one finger of every
        pinch) to tap gestures that let the map's pinch through.
46. [x] Custom photos now replace the monogram everywhere: conversation title
        bar, transcript sender avatars, map pins, node info card, compose picker
        (channels and people), search results, reaction details, and the
        channels list. Priority: custom photo > metro icon > monogram.
45. [x] Pinned conversations long-press independently: the grid moved out of
        the List (whose row-level context-menu preview lifted every pin at once
        and mistargeted the menu) into the header area. Layout unchanged;
        verified in simulator.
44. [x] Reaction sheet closes itself immediately on pick (one-shot guard also
        prevents duplicate sends from the typed-emoji path).
43. [x] Conversations can be deleted from the list via swipe or long-press, with
        a confirmation explaining local-only deletion (channels on the radio
        reappear empty; mesh messages can't be deleted remotely).
42. [x] Map locate-me button moved to bottom-trailing via a custom-scoped
        MapUserLocationButton, clear of the title area.
41. [x] Photo association now offers pinch-to-zoom + drag positioning in a
        circular crop view before saving (512px render of exactly what's
        framed).
40. [x] "Set Photo" silently did nothing: the picker's presentation binding
        cleared photoTarget on dismiss — before the selection arrived — so the
        save had no target. Presentation now uses a separate flag; the target
        survives into the crop step.
39. [x] LoRa settings moved from Device configuration into Mesh Setup as
        "Custom LoRa Settings", with a footer nudge to save results as a preset.
38. [x] Mesh Setup: "Save Current as Preset…" stores the radio's current
        region/preset/slot/hop limit as a named custom configuration in the
        preset list (persisted, adopted as applied); custom rows delete via
        swipe. Community presets are undeletable.
37. [~] iCloud sync (messages, nodes, conversations, custom icons): fully
        implemented — CloudKit-compatible schema (no unique constraints, inline
        defaults, launch-time cross-device dedupe), CloudKit-backed store with
        local fallback, entitlements file ready. ACTIVATION BLOCKED: Xcode has
        no signed-in developer account, so the iCloud container/push capability
        cannot be provisioned. Sign in (Xcode → Settings → Accounts), then
        re-enable CODE_SIGN_ENTITLEMENTS in project.yml and rebuild. Same
        sign-in unblocks TestFlight.
36. [x] Custom photos for channels and nodes: long-press a conversation → Set
        Photo… (or Remove Photo) — picked from the photo library, downscaled to
        256px, shown in the list, pinned grid, and title bars. Stored in the
        data store, so it rides iCloud sync once #37 activates.

35. [x] Telemetry interval now truly reads and confirms: module-config writes
        do not reboot the radio, so nothing re-synced and the screen showed a
        stale default (radios also report 0 = "firmware default", which was
        skipped). Now: opening the screen requests the live value via admin
        getModuleConfig, the picker updates when the response lands, saves
        mirror optimistically and read back ~2s later to confirm what stuck,
        and admin get-config responses update all config mirrors (bluetooth/
        display/position/lora too). Admin packets now use reliable priority,
        matching the official app.

34. [x] Reaction picker: searchable across the full iOS emoji set (typed letters
        search Unicode names, never send); typing an emoji from the emoji
        keyboard sends it immediately. Only emoji can be sent as reactions.

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
