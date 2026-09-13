# Multi-radio Hops — product and implementation design (draft 2)

Draft 2 folds in the owner's decisions: multi-attach with a priority order,
companion devices recommended, roles suggested only, the phased order in
§2.5, and one Meshsite served through every attached radio.

Goal, in the owner's words: attach to several radios as I move around — one
upstairs at home, one downstairs, one in my backpack, one at the office —
and have them work together so I can send and receive from any of them at
any time. Like a cell network. Adding a radio should recommend settings and
put it on the same channels. If I message someone one radio has seen but the
current one hasn't, load their node info onto the current radio first.

This document has three parts: what the physics allows, the product design,
and the implementation plan. An adversarial review follows each part and its
findings are folded back in; the ones that survive are listed as open risks
and as decisions for the owner.

---

## 0. What the physics allows (read this first)

A cell network hands a phone off between towers that share one identity and
one back-haul. A Meshtastic mesh has neither, and the design is honest about
where the analogy breaks.

**Each radio is its own node.** It has a node number and a keypair; other
people direct-message a *node*, and their radios pin that node's key. Four
radios are four identities on the mesh. Cloning one identity across radios
is not an option: firmware detects its own node number in use by a different
MAC and re-rolls a new number (`NodeDB::pickNewNodeNum`), so cloned radios
renumber themselves the moment they hear each other, and duplicated keypairs
are treated as a security defect (GHSA-gq7v-jr8c-mfr7). Hops's own store
already refuses merges between rows that share a key (PR #3).

**A radio without its phone is a small mailbox, not a server.** While the
phone is away, firmware queues packets for it — `MAX_RX_TOPHONE` is **8 on
classic ESP32, 32 on nRF52 and ESP32-S3/C3**. When the queue is full, an
arriving text evicts the oldest queued packet; anything else arriving is
dropped. Positions, node info and telemetry share that queue. On a busy mesh
like NYC's, an unattended radio holds roughly the last few minutes of
traffic, and a DM sent to it in the morning is gone by lunch. The sender,
meanwhile, sees "delivered to their radio" — true, and misleading.

**There is no handoff signalling.** Nothing tells a peer "send to my other
node now". Official-app users reply to whichever node they saw. Only Hops
users could learn otherwise, through a Hops-level convention.

**The reliable back-haul that exists today is iCloud.** Hops already syncs
its store across the owner's devices, and a device attached to a radio
ingests everything that radio hears. A Book at home attached to the
downstairs radio, or a Mac at the office attached to that radio, turns an
unattended radio into a real mailbox — with minutes of latency, not seconds.

So the achievable product is: **send from any radio, any time; receive live
from the radio you're attached to; receive from the others when you
reconnect to them (bounded by their queue) or, with a companion device
attached, through iCloud.** That is a good product. It is not a cell
network, and the UI must not pretend it is.

---

## 1. Product design

### 1.1 Concepts

- **Fleet** — the owner's radios, as one named set. Synced through iCloud so
  every device knows every radio.
- **Radio** — one physical unit: node number, public key, nickname ("Home
  upstairs"), location tag (Home / Office / Mobile / Other), hardware model,
  firmware, last seen, last battery. Its Bluetooth identifier is per iOS
  device and is kept locally, not synced.
- **Attached radios** — every fleet radio the phone currently holds a
  Bluetooth link to. Core Bluetooth allows several at once; each Meshtastic
  radio accepts one phone, which is all we need. Capped at four links.
- **Priority order** — the fleet list is sortable by the owner. The highest
  attached radio is the **transmit radio**; the others receive only.
- **Fleet profile** — the settings every radio should share: channel set
  (names + keys), LoRa region / preset / slot / hop limit, rebroadcast mode.
  Never includes a radio's identity or keypair.
- **Me** — the set of the fleet's node numbers. Anything from any of them is
  mine; a DM to any of them is for me.

### 1.2 Attaching and roaming

- The phone keeps a pending Bluetooth connection to every paired fleet
  radio. Each one that comes into range connects and runs its own handshake;
  all of them stay attached. Walking in the door attaches both home radios;
  leaving drops them and the backpack radio carries on. Nothing is cancelled
  in favour of anything else.
- **Transmit radio = the highest-priority attached radio.** The owner sorts
  the fleet list; the order is the whole policy. No RSSI voting, no
  ping-pong: a message goes out through the top attached radio at the moment
  of sending. When it drops, the next attached one takes over.
- The Settings radio card shows the transmit radio ("Sending via Home
  upstairs") and every other attached radio underneath ("also hearing:
  Home downstairs"), then the rest of the fleet with last seen and last
  battery.
- Everything that used to say "your radio" now says which one.

### 1.3 Sending

- A message goes out through the transmit radio, from that radio's
  identity — never through more than one, which would put the same text on
  the air twice under two identities.
  The transcript stamps it "via Home upstairs" (subtle, tappable in Delivery
  Details).
- **Node-info preload.** Before a DM, Hops checks whether the transmit radio
  knows the peer. It learns this from the node-database dump at connect and
  from packets heard during the session. If not, it sends an `add_contact`
  admin message with the peer's user record and public key (from the fleet's
  shared store), waits for the radio's ack (about a second), then transmits.
  It also marks the contact a favorite so the radio's 80–100-entry node table
  doesn't evict it. This also fixes today's error-39 failures where a peer
  had rolled out of the radio's table.
- Delivery state stays attached to the sending radio. If the phone roams
  before the ack arrives, the message shows "sent via Office — waiting to
  reconnect" instead of failing at the 5-minute sweep.

### 1.4 Receiving

- Live from **every** attached radio. At home that is both home radios; the
  same packet heard twice collapses by packet id, which the store already
  does.
- On attaching to any fleet radio, its queue is drained and merged the same
  way.
- Every DM thread is keyed by the peer, so a conversation is one thread no
  matter which of my radios carried each message. Each incoming bubble can
  reveal which radio heard it.
- **Mailbox honesty (decided: recommend).** The fleet screen shows, per
  stationary radio, "holds the last 8 / 32 packets while you're away" from
  its hardware model, with one line: "Keep the Book attached to this radio
  and its messages reach you through iCloud."

### 1.5 Adding a radio

1. Settings › Radios › Add Radio. Pair as today.
2. Hops reads the new radio's config and diffs it against the fleet profile:
   channels (names, keys), LoRa, rebroadcast mode, role, owner name.
3. It shows the diff and offers **Apply fleet settings**. Applying writes
   channels and LoRa (a reboot), and rebroadcast mode. It never touches the
   security section.
4. It proposes an owner name from a pattern — long name "Andrew · Home up",
   short name "W2AU" — and **suggests** a role by location tag: stationary
   radios `CLIENT`, one per location relaying and any second co-located
   radio `CLIENT_MUTE`, mobile radios `CLIENT_MUTE` (the NYC Mesh
   guidance). Decided: suggestions only. Role is shown in the diff,
   unselected; the owner can put any radio in any configuration and Hops
   never overrides a role on its own.
5. The radio joins the fleet. Drift is re-checked on every connect; a radio
   whose channels differ from the profile gets an orange row and a one-tap
   re-apply.
6. The fleet profile is seeded from the first radio and editable in one
   place; changing it flags every other radio as drifted until re-applied.

### 1.6 Meshsites under a fleet (decided)

One site, served from the phone, going out through every attached radio.
Each attached radio beacons the site on its primary channel and answers
requests that arrive on it; the server keys in-flight requests and caches by
(radio, requester) so two radios never race on one reader. Visitors are
counted once per requester across radios. Until the protocol carries a site
id, readers with two of my radios in range will see the site listed twice —
spec draft 9 should add `site_id` to BEACON so clients can merge; the Python
server needs the same field.

### 1.7 Peers who are also fleets (later)

Others will see four "Andrew" nodes. Nothing in the protocol links them. A
later Hops-to-Hops convention (a signed "these nodes are one person" record
on the reliability port) could group them and steer replies to the node that
last spoke. Out of scope for v1; noted so the data model leaves room.

### 1.8 Adversarial review of the product design

| Attack / failure | Consequence | Design response |
|---|---|---|
| Owner expects cell-network receive | Missed DMs at unattended radios, blamed on Hops | §0 language in the fleet screen; per-radio queue size shown; companion-device recommendation |
| Peer replies to the node that spoke, owner has roamed | Reply sits in a mailbox of 8–32 packets | Same; plus §1.6 later |
| Two co-located home radios both relay | Double airtime, both ack, both rebroadcast | Role recommendation: one relays, the other CLIENT_MUTE |
| Owner applies fleet settings with the official app's config export | Copies `security.private_key` → duplicate identities | Hops never writes the security section; warns if two fleet radios share a public key |
| Backpack radio stolen | Holds channel keys and one identity | "Forget and revoke": remove from fleet, rotate channel keys across the fleet in one action, tell peers to reset the key for that node |
| Two home radios both attached, both relaying | Double airtime, duplicate receive | Duplicates collapse by id; role suggestion: one relays, the other CLIENT_MUTE |
| Transmit radio changes mid-conversation | Peer sees a new sender identity | Transcript stamps "via …"; priority order is stable, so switches happen only when the top radio drops |
| Four BLE links drain the phone | Battery | Cap at four; links idle when quiet; measured with Instruments before testers |
| Node-info preload evicts something the radio needed | Peer's key lost on the radio | Favorite the contact; the eviction policy spares favorites |
| Preload sends a stale or wrong key | Firmware refuses to overwrite a manually verified key; otherwise PKI_FAILED | Preload uses the newest key the fleet store has; NAK 34 reason shown in the transcript (TODO 181) |
| Four identities confuse peers | "Which Andrew do I message?" | Owner-name pattern with location; §1.6 later |
| iCloud back-haul assumed real-time | Minutes of delay | Stated in the fleet screen; no "instant" language |

---

## 2. Implementation design

### 2.1 Data model

- `RadioEntity` (SwiftData, synced): `nodeNum`, `publicKey`, `nickname`,
  `locationTag`, `hwModel`, `firmware`, `addedAt`, `lastSeenAt`,
  `lastBattery`, `phoneQueueSize` (8 or 32 from model), `profileHash`
  (hash of channels + LoRa last seen on it, for drift).
- `FleetProfileEntity` (synced, single row): channel settings array, LoRa
  snapshot, rebroadcast mode, owner long-name pattern.
- `FleetProfileEntity` also carries `priority: [Int64]` — the owner's sort
  order of node numbers; the transmit radio is the first of these that is
  attached.
- Local only (UserDefaults): `peripheralId` per `nodeNum` for this iOS
  device; per-link session cache of known peers.
- `MessageEntity` gains `viaNodeNum` (which of my radios sent or heard it).
- Store: `localNodeNums: Set<Int64>` replaces `localNodeNum`. `isOwnSender`,
  the local-node merge refusal, the stale-prune guard, and `myNode` lookups
  all consult the set.

### 2.2 Radio layer

- `BLETransport` becomes a `RadioLink` per peripheral, each with its own
  handshake state, node-database drain, write queue, and `knownPeers` set.
  A new `FleetConnector` owns up to four links: on activate,
  `retrievePeripherals` for every known id and issues pending connects;
  every `didConnect` becomes a link; on disconnect that link is re-armed.
  State restoration may hand back several peripherals; each is adopted.
- `RadioManager` keeps its public surface (`state`, `myNodeNum`, `send…`)
  over the fleet: `state` summarises (connected if any link is), `myNodeNum`
  becomes `transmitNodeNum` (the top attached radio by priority), and a
  published `links` array feeds the UI. Inbound frames from every link go
  through the same `process(frame:)` tagged with their link's node number.
  Sends are refused with a clear reason when nothing is attached.
- Per-link `knownPeers: Set<Int64>` filled from `.nodeInfo` during that
  link's handshake and from every packet's `from` on that link.
- `preloadContact(peer:)` runs on the transmit link: builds
  `SharedContact { nodeNum, user{id, long, short, publicKey} }`, sends
  `AdminMessage.addContact`, then `setFavoriteNode`, awaits the routing ack
  or 2 s, then proceeds. Logged in Mesh Traffic. Ships first, against
  today's single link.
- `sendText` records `viaNodeNum`; the stale sweep skips messages whose
  radio is not attached; re-attaching that radio re-runs the sweep for it.
- Meshsites: `MeshsiteServer` beacons and answers on every link; its
  in-flight and response caches are keyed by (link, requester).

### 2.3 Settings and onboarding

- Settings › Radios: transmit-radio card with the other attached radios
  beneath it; the fleet list in priority order with drag-to-reorder (the
  order *is* the transmit policy); Add Radio; Fleet Settings (profile
  editor); per-radio detail (nickname, location, suggested role with
  one-tap apply, drift diff, Apply, Forget, Forget & Revoke).
- Add-radio flow reuses PairingView, then a new `FleetJoinView` for the diff
  and apply.
- Drift check runs in `handleConfigComplete` once channels and LoRa are in.

### 2.4 Everything else that assumed one radio

81 references to `myNodeNum` across ten files; each is one of three kinds:
"is this packet mine" (→ the fleet set), "what identity do I send as" (→ the
transmit radio), or "which record is me for display" (→ the transmit radio,
falling back to any attached one). Presence probes and holds key on the
peer and stay as they are.

### 2.5 Phases

| Phase | Scope | Size |
|---|---|---|
| 0 | Data model, `localNodeNums` set, `viaNodeNum`, migration of the single paired radio into a one-member fleet | 1 day |
| 1 | FleetConnector: per-peripheral RadioLink, up to four attached, priority-ordered transmit radio, drag-to-reorder fleet list | 3 days |
| 2 | Node-info preload before DMs, favorite marking, Mesh Traffic lines | half a day |
| 3 | Add-radio flow: diff, apply (channels, LoRa, rebroadcast), name pattern, role suggestion, drift on connect | 2 days |
| 4 | Send/receive semantics: via-radio stamps, sweep by attached radio, mailbox notes with the companion-device line; Meshsites served over every link | 1.5 days |
| 5 | Forget & Revoke with fleet key rotation; duplicate-key warning | 1 day |
| 6 | Test harness: `Transport` protocol with a scripted mock, roaming scenarios in the simulator; a unit-test target (none exists today) | 1–2 days |

Decided order: **2 first** (independent, fixes error-39 DMs today), then
**0–1**, then **3–4**, with **6 before anything roaming-related reaches
testers**, and **5** last. About nine working days.

### 2.6 Adversarial review of the implementation

| Risk | Where | Mitigation |
|---|---|---|
| Pending connects to four peripherals drain the battery | FleetConnector | iOS pending connects are passive scans; measured cost is low. Cap at 8 radios. Verify on device with Instruments |
| iOS restores only one peripheral after relaunch | State restoration | `willRestoreState` may return several; adopt the connected one, re-arm the rest |
| Two radios connect at once (both in range at launch) | FleetConnector | Both become links; the transmit radio is chosen by priority, not by arrival order; test explicitly |
| Same packet from two links at once | Ingest | Dedup by packet id is already in place; a link tag on each frame keeps Mesh Traffic honest about which radio heard it |
| A write meant for the transmit radio lands after it dropped | Link switch | Every write names its link; a dropped link fails its queued writes to the sender, which re-issues on the new transmit radio |
| Packet-id collisions across radios | Routing correlation | Ids are random 32-bit from the phone; negligible, but correlate on (id, viaNodeNum) |
| Stale `knownToRadio` (radio evicted the peer after we learned it) | Preload skipped, PKI 39 | Treat NAK 39 as "preload then retry once" |
| Preload for a peer with no key | `add_contact` without key | Send anyway (names help), skip favorite; DM goes channel-encrypted as today |
| Flash wear from `add_contact` saves | Firmware `saveNodeDatabaseToDisk` per call | Preload at most once per peer per radio per session |
| Sweep marks messages failed while their radio is away | `sweepStaleSending` | Skip non-current `viaNodeNum`; sweep on reconnect |
| CloudKit merges a second device's `currentNodeNum` | Local vs synced fields | Current radio and peripheral ids are local-only by design |
| `mergeRenumberedNodes` sees two fleet radios | PR #3 logic | Fleet nums are all local; refusal covers the set; a real renumber is detected by MyInfo ≠ stored, handled per radio |
| Owner name pattern exceeds byte limits | `MeshName` | Reuse the clamp (TODO 177) |
| Fleet-profile apply mid-drift reboots a radio the user is talking through | Apply flow | Confirm; apply LoRa last; reconnect automatically as today |
| Test coverage: none of this is unit-testable today | Phase 6 | Do phase 6 before phase 1 ships to testers |

### 2.7 Open risks (not solvable in Hops)

1. Unattended-radio mailbox size (8/32). Only a companion device or an MQTT
   bridge changes it. MQTT is outside the product vision today.
2. Peer-side identity fragmentation (§1.6).
3. Meshsites lists a site once per attached radio until BEACON carries a
   site id (spec draft 9).

---

## 3. Decisions (made)

1. Companion device: recommended in the fleet screen, one line per
   stationary radio.
2. Roles: suggested only, never applied automatically; any radio, any
   configuration.
3. Scope and order: preload first, then data model and multi-attach, then
   add-radio and semantics, harness before testers, revoke last.
4. Meshsites: one site, served from the phone through every attached radio.
