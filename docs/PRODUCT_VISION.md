# Hops — Product Vision

*A fast, familiar messaging app for your Meshtastic radio.*

Revision 2 — incorporates the adversarial review (see appendix) and metro presets.

## What Hops is

Hops is an iOS app for people who own **one Meshtastic radio** and mostly want to
**send and receive messages**. It looks and behaves like Messages or Signal: open the
app, see your conversations, tap one, type. The radio is plumbing — Hops connects to
it automatically, keeps itself in sync silently, and only surfaces the mesh when the
mesh is the point (delivery state, signal quality, the map).

Hops is deliberately not a radio administration tool. The official Meshtastic app
exposes every knob on the device; Hops exposes only what a messaging user needs to
get on the air and stay there, and happily coexists with the official app for
everything else (both apps speak the same protocol to the same radio, so nothing is
lost by switching between them).

### Product principles

1. **Simple.** One radio. One list of conversations. If a feature needs a manual to
   explain, it belongs in the official app.
2. **Fast.** The UI renders instantly from the local message store and never waits on
   the radio. Messages come first in every sync; housekeeping (node database,
   telemetry) always yields to them.
3. **Reliable.** Sent messages resolve to a truthful delivery state with one-tap
   retry. Nothing is silently dropped: anything Hops can't send yet waits in an
   outbox, and anything it can't know it doesn't pretend to know.
4. **Familiar.** Standard iOS navigation, standard gestures, standard components,
   SF Symbols, Dynamic Type, dark mode. Where mesh reality forces a departure from
   what a Messages-shaped app implies (no photos, no read receipts), Hops says so
   up front instead of letting users discover it by failure.

## What mesh messaging is — and isn't

Hops looks like a modern messenger, so it must be explicit about the contract LoRa
can actually offer. Messages are **text only, up to about 200 bytes**. There are no
photos, voice notes, typing indicators, read receipts, edits, or unsend. Delivery can
take seconds or minutes, and "delivered" means *the recipient's radio* has the
message — not that a human has seen it. Hops states this in onboarding and in empty
states ("Text only, up to ~200 characters — that's LoRa"), keeps the composer's
affordances visibly complete (text and location; no "+" that implies more), and
words its delivery states to match what the protocol truly knows.

## How Hops stays in sync (the connection model)

**While the app is open:** Hops holds a live BLE connection. Incoming packets arrive
within a second of the radio hearing them.

**When the app is backgrounded:** the BLE connection stays alive under the standard
`bluetooth-central` background mode. Each packet the radio receives wakes Hops
briefly to decode, store, and notify. While phone and radio are in range, messages
arrive as they're received — event-driven, no polling, effectively better than a
15-minute check.

**When the connection drops:** Hops immediately re-arms a *pending connection
request* — on every disconnect path, before doing anything else. A pending
`connect()` doesn't expire, and with CoreBluetooth state restoration it means that
when iOS has suspended or even terminated Hops for resources, **the system usually
relaunches Hops in the background as soon as the radio is back in range**, at no
battery cost while idle. This — not a timer — is what stands in for "wake every 15
minutes": iOS doesn't reliably allow any app a scheduled BLE poll, but it does allow
exactly this event-driven wake. Hops also registers an opportunistic background
refresh task; it's a bonus sync when iOS offers one, not a safety net, and it runs
the same time-boxed message-first profile (connect, config, drain — never the node
database).

**What background wake honestly cannot cover** (and how Hops recovers):

- *Force-quit.* If the user swipes Hops away, iOS delivers nothing until the next
  open. One-time education when detected: "Hops can't listen for messages if it's
  swiped away — just like any Bluetooth app."
- *Phone reboot or Bluetooth toggled off.* Pending connects are lost until the next
  app open.
- *Bond loss (radio re-paired elsewhere).* Re-pairing needs a foreground PIN sheet;
  Hops posts a notification asking the user to open the app.

In every one of these cases, the next foreground open recovers: reconnect starts
instantly and silently, and if the last sync is stale the status capsule says
"Catching up — last synced 3h ago" rather than pretending nothing happened.

**Reconnect is retrieval, not scanning.** Hops reconnects by handing iOS the bonded
peripheral's identifier directly (`retrievePeripherals`) and connecting — no scan,
no waiting to catch an advertisement — falling back to a scan only if retrieval
fails. Target: **link up within ~5 seconds** of the radio being in range.

**Messages first, always.** On every reconnect Hops requests device config, then
immediately drains the radio's queued packets — the messages that arrived while the
phone was away. The node database (which can take minutes on large meshes) is
deferred to an incremental background refresh after messages are flowing. "Connected"
and "synced" are different promises; Hops optimizes the one users feel: *missed
messages appear within seconds of reconnecting*, not after a node-list download.

**About gaps:** the radio queues a bounded number of packets for the phone and drops
the excess silently; a power-cycled radio has an empty queue. Hops cannot detect
whether messages were actually missed — no app can, the protocol carries no such
signal — so it doesn't pretend to. After an extended offline period it shows a
single, transient status line ("Hops was offline 9:14 PM – 7:02 AM"), stored
nowhere, cluttering nothing.

**First run:** a single pairing screen. Hops scans, shows nearby radios sorted by
signal strength, one tap pairs (standard iOS PIN sheet). If the radio is
factory-fresh (region unset — it cannot transmit at all), onboarding flows directly
into **mesh setup** (see Settings: metro presets) so the first message actually
goes somewhere. From then on, that radio is *the* radio; no device manager, no
switcher. Changing radios later is one action in Settings.

## Structure: three tabs

A standard tab bar — **Chats, Map, Settings** — the same shape as Signal, WhatsApp,
and every multi-destination iOS app, per the HIG's own rule for 3–5 top-level
sections. (An earlier draft hid Map and Settings behind toolbar buttons "like
Messages"; the review killed it — Messages is tab-free because it has one
destination, and a map buried behind a toolbar glyph is a map never found.)

### 1. Chats (home)

- **One unified list** of conversations — channels and DMs together — sorted by most
  recent activity. Each row: avatar (channel glyph or short-name monogram), name,
  last-message preview, relative timestamp, unread indicator. DM rows carry a small
  hop/signal hint so mesh users keep their bearings.
- **Pinning:** swipe or long-press to pin; pinned conversations appear as the
  familiar grid of large avatars above the list, exactly like Messages.
- **Swipe actions:** pin/unpin, mute/unmute, mark read/unread. Mute means mute — no
  exceptions, no heuristics. (The review cut "@-mention breaks through mute":
  Meshtastic has no mention protocol, and a substring match against 4-character
  short names would pierce a mute the user explicitly set, on a guess.)
- **Search:** standard pull-down search over conversation names, node names, and
  full message text, results grouped (Conversations / Messages).
- **Compose:** the standard square-and-pencil button opens a picker of channels and
  messageable nodes (roles that can't answer — routers, repeaters, sensors — are
  filtered out). Picking a node with no history starts the thread.
- Empty states do real work: before pairing, the list *is* the onboarding; with no
  messages yet it explains channels, shows the primary channel ready to use, and
  sets the text-only expectation.

Reserved module channels (admin, gpio, serial, mqtt) never appear. Unknown nodes
appear in compose and search, not as empty conversations.

### 2. Conversation view

A chat transcript that feels like iMessage, worded like a mesh:

- **Bubbles**, day separators, timestamp on drag, scroll-to-bottom pill, unread
  divider; sender short-names shown in channels like any group chat.
- **Delivery state, truthfully.** DMs progress: *Sending…* → *Relayed* (the mesh
  forwarded it; not yet confirmed) → *Delivered to their radio* (their radio
  acknowledged — deliberately qualified wording, because no LoRa ack can promise a
  human saw it) → or *No response from their radio — Retry*. Channel messages:
  *Sending…* → *Sent to mesh* (terminal; a channel broadcast has no
  per-recipient confirmation). No label ever means "pending" in one context and
  "success" in another. Failure is driven primarily by the firmware's explicit
  routing NAK (which arrives fast), with a timeout fallback evaluated on next wake;
  after ~20 seconds a quiet annotation appears: "Still sending — mesh delivery can
  take a few minutes," so a slow mesh doesn't read as a broken app.
- **Retry is honest about the protocol:** a retry is a new packet (the mesh
  deduplicates recent packet IDs, so reusing one would be silently swallowed). If
  the original actually arrived but its ack was lost, the recipient may see a
  duplicate; that is the mesh's tradeoff and Hops accepts it rather than hiding it.
- **Outbox semantics everywhere.** A message composed with no radio connected — in
  the app or from a notification — is persisted immediately, shows *Waiting for
  radio…*, and transmits on the next connection. Nothing composed is ever lost to a
  missed BLE window.
- **Replies and tapbacks** use Meshtastic's native reply/reaction encoding and
  interoperate with the official apps (older clients render reactions as standalone
  emoji messages — a protocol reality, noted here so it isn't mistaken for a bug).
  One honest divergence from iMessage: the protocol has no retraction, so a
  reaction can't be un-tapped; the tapback bar is styled accordingly and the
  message-info sheet says "Reactions can't be removed on mesh."
- **Length awareness, quietly:** a character countdown appears only near the ~200
  byte limit and stops at it.
- **The context menu** carries the mesh extras: message info (hops, signal, error
  reason in plain language), copy, and in DMs the peer's node card — name, battery,
  last heard, distance/bearing when both positions are known — with a "locate on
  map" jump.
- **Location sharing:** a compose accessory sends your current position as a
  standard waypoint other apps understand. (Sharing your position — one tap, no
  authoring UI. Dropping and editing arbitrary pins is the official app's job.)

### 3. Map view

One purpose: *where is everyone?*

- Standard MapKit map (standard/hybrid, user location) showing **nodes at their
  last known positions**, clustered when dense, using the same monogram avatars as
  the rest of the app; nodes heard recently are vivid, stale ones fade.
- **Precision honesty:** deliberately-fuzzed positions render as translucent
  circles sized to the reported precision, never as falsely exact pins.
- **Received waypoints** appear with their emoji glyphs. The map is read-only in
  v1 — viewing the mesh, not authoring it.
- Tap a node for a card (identity, last heard, battery, distance) with two actions:
  **Message** and **Directions** (hands off to Apple Maps).

No overlays, offline tiles, traceroute flyovers, geofences, or route recording.

### 4. Settings view

Four sections — Radio, Channels, Notifications, About — short enough to never
scroll on most phones. (The review cut app-icon pickers, in-app appearance
overrides, and storage meters: the system already does appearance and type size,
and a decade of 200-byte messages is megabytes. Old nodes and messages are capped
automatically, no dial.)

- **Radio** (top card): the paired radio at a glance — name, connection state,
  battery, firmware version. Inside:
  - **Your identity:** long/short name — the one thing everyone must set.
  - **Mesh setup — the metro preset picker.** A single dropdown configures the
    radio for a known community in one tap: **NYC Mesh**, **Bay Area Mesh**, or
    **Standard (LongFast default)**, with room for more metros. Choosing one
    applies the community's published recommended settings — region, modem preset,
    frequency slot, hop limit, and calm telemetry/position intervals — after a
    one-screen confirmation showing exactly what will change. This same picker is
    what onboarding presents when a factory-fresh radio (region unset) is detected,
    so a new owner goes from unboxing to messaging their local mesh without ever
    touching the official app. Two design rules keep it trustworthy:
    - **Presets are versioned data, not code.** Metro communities change their
      recommendations (Bay Area moved MediumSlow → MediumFast in late 2025; NYC
      began migrating to MediumSlow in early 2026). Hops ships a bundled manifest
      and refreshes it from a maintained source, showing when a selected metro's
      recommendation has changed ("Bay Area Mesh now recommends MediumFast —
      update your radio?").
    - **It's a configurator, not a config panel.** Current region and preset are
      displayed; arbitrary hand-editing of LoRa parameters stays in the official
      app.
  - *Change radio… / Forget radio.*
- **Channels:** the channel list, join-by-QR, and share-as-QR — scanning a QR is
  how normal users join a mesh, so it's first-class. Because a Meshtastic channel
  QR *contains* LoRa settings (that's how communities distribute working configs),
  scanning shows the same one-screen confirmation when it would change the radio's
  preset or region — the review caught that "read-only radio config" and
  "first-class QR join" were contradictory as originally written. These two flows —
  metro presets and QR confirm — are the *only* radio-config writes in Hops beyond
  your name.
- **Notifications:** master toggle, DMs and channels toggles, link to system
  settings.
- **About:** version, licenses, credit to the Meshtastic project, and a pointer to
  the official app for device administration.

## Notifications

Local notifications only — no server, no push infrastructure; everything stays on
the phone and the mesh.

- **Communication notifications** (sender identity via the standard messaging
  intents) are the mechanism for prominence: per-conversation grouping, sender
  avatars, Siri/CarPlay announcement, and Focus breakthrough via the user's own
  people/app allowances — the way Messages actually does it. Time-sensitive
  interruption is reserved for DMs at most, never blanket channel traffic (blanket
  use is both against Apple's guidance and the fastest way to get the privilege
  revoked by the user).
- Per-conversation mute is absolute.
- **Reply and tapback from the notification**, backed by the outbox: if the radio
  is connected or reconnects within the wake window, the reply goes out
  immediately; otherwise it waits in the outbox and Hops posts "Couldn't send yet —
  will send when your radio reconnects." Never fire-and-forget.
- Opening a notification deep-links into the conversation. Reading a conversation
  clears its delivered notifications; the app badge always reflects the total
  count of unread conversations.

## What Hops leaves out (on purpose)

Device firmware updates, remote node administration, module configuration (MQTT,
serial, sensors, TAK…), offline map tiles and overlays, waypoint authoring,
traceroute visualization, range testing, telemetry charts, multi-device management,
and — for v1 — automatic Store & Forward history replay (see appendix). These are
the official app's job, or later work. Every screen Hops doesn't have is a screen
that can't be slow, confusing, or broken.

## Engineering commitments behind the vision

1. **Never block the UI on the radio.** All screens render from the local SwiftData
   store immediately; sync reconciles behind them. Views read value snapshots, not
   live database objects, so background writes can never stall or crash rendering.
2. **A first-class Conversation record** (channel-N or DM-with-node) carrying
   `lastMessageAt`, `unreadCount`, `pinned`, `muted`. The official app derives
   conversations by scanning messages and pays for it in list performance; Hops is
   designed around the list, so the list is O(conversations), not O(messages).
3. **Two-number reconnect target:** link-up ≤ ~5 s via peripheral retrieval +
   direct connect (scan only as fallback); *first missed message on screen* seconds
   after that, because the sync order is config → drain queue → (deferred,
   incremental) node database. Background sync windows run the same profile,
   time-boxed, and never attempt the node DB.
4. **Pending connect re-armed on every disconnect path** + CoreBluetooth state
   restoration as the background wake mechanism; `BGAppRefreshTask` as opportunistic
   extra, explicitly not a safety net. No background location, no keepalive hacks.
5. **Delivery truth from the protocol:** ACK tracking keyed on packet ID;
   recipient-ack vs mesh-relay distinguished; NAK-driven failure with
   wake-evaluated timeout fallback; retries mint a fresh packet ID (recipient-side
   duplicates possible and accepted).
6. **A persistent outbox** for every send path — foreground, background, and
   notification replies — with truthful pending states.
7. **Deduplicate on packet ID at ingest** (the radio echoes your own sends);
   self-echoes marked read.
8. **Metro presets as versioned data:** bundled manifest, remote refresh, explicit
   user confirmation before any radio write, change detection when a community
   updates its recommendation.
9. **Interoperate, never fork:** standard ports only (text, routing, nodeinfo,
   position, waypoint, telemetry for battery), standard reply/reaction encoding,
   standard channel QR format, PKI DMs with the standard first-use key policy and
   pre-shared contact push so key rollouts don't strand messages.

## Appendix: adversarial review outcomes

The draft was attacked from three angles — simplicity, fast/reliable (checked
against the official app's source), and familiarity/HIG. Material changes:

| Draft claimed | Review found | Resolution |
|---|---|---|
| Radio config fully read-only; setup deferred to official app | A factory-fresh radio has region unset and cannot transmit — the target user's first message silently dies | Metro preset picker (also satisfies the per-metro requirement); it and QR-join confirmation are the only radio writes |
| QR join first-class *and* LoRa config read-only | A channel QR contains LoRa config — the two claims contradicted | QR import shows a confirm screen when it changes radio settings |
| "iOS relaunches Hops the moment the radio is in range" (incl. after reboot) | Restoration doesn't survive force-quit, reboot, BT toggle, or bond loss | Softened to "usually"; failure modes enumerated with explicit recovery UX ("Catching up — last synced Xh ago") |
| Connected & draining in 3–5 s | That budget covers link-up only; node-DB download can take ~2 min and the draft ordered it before the message drain | Split into two targets; message-first sync order; node DB deferred |
| BGAppRefreshTask as "belt-and-braces backstop" | It fails in exactly the same cases as the primary mechanism and its ~30 s window can't fit a full sync | Demoted to opportunistic extra; time-boxed message-only profile |
| Automatic S&F history on every reconnect | S&F routers are rare; replays can't be deduped by packet ID (structural duplicates, wrong timestamps); separate ingest subsystem | Cut from v1; future work requires content-based dedup |
| "Messages may be missing between X and Y" markers | The protocol provides no gap signal; the marker would be permanent noise or a false claim of knowledge | Replaced with a single transient "offline from X to Y" status line |
| "Delivered", borrowed from iMessage | Imports a stronger guarantee than a LoRa ack provides; "Sent to mesh" meant both pending and terminal | Reworded states: *Relayed* / *Delivered to their radio* / *Sent to mesh* (terminal, channels only) |
| Toolbar-based Map/Settings, "like Messages" | Three top-level destinations is the HIG's tab-bar case; Messages is tab-free because it has one destination | Three tabs: Chats, Map, Settings |
| 5-minute silent "Sending…" then red "Not Delivered" | Reads as a broken app at minute three; red alarm state would fire routinely on a mesh | Progressive disclosure (*Relayed*, "still sending" annotation), NAK-first failure, calmer failure wording |
| "Retryable without duplicating" | Protocol-impossible: same ID is swallowed by dedup tables, new ID can duplicate | Fresh ID on retry; duplicates acknowledged as the mesh's tradeoff |
| Reply-from-notification over restored BLE | ~10 s action window; radio often out of range at exactly that moment; silent loss | Persistent outbox behind all send paths; "couldn't send yet" notification |
| @-mention breaks through mute | No mention protocol exists; substring matching on 4-char names pierces an explicit mute on a guess | Cut; mute is absolute |
| Time-sensitive notifications for messages | Wrong mechanism per Apple guidance; invites revocation | Communication notifications; time-sensitive at most for DMs |
| Waypoint creation, app icons, appearance override, storage UI | Authoring/vanity/hypothetical-problem scope in a v1 messaging app | Cut; map is read-only, system handles appearance, caps are automatic |
| "Indistinguishable from iMessage" | Inherits an implied contract (photos, receipts, typing) the mesh can't honor | "What mesh messaging is — and isn't" section; expectation-setting in onboarding, empty states, and composer design |
