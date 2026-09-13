# Hops TODO

Working list from on-device testing. Items stay here until resolved.

## Open

197. [x] Settings lists every fleet radio inline in priority order — name,
         what it's doing (Sending & receiving / Receiving only / Out of
         range / Disconnected by you), battery — with Add Radio beneath and
         a Reorder control; the footer says the top in-range radio sends
         and the rest only receive. Tapping an attached radio opens its
         Device Configuration; a detached one opens its detail page. Mesh
         setup and Manage radios sit in a "Mesh · via <radio>" section.
         Disconnect/Connect moved into Device Configuration, per radio
         (userDisconnectedRadios: no pending connect until reconnected).

196. [x] Device Configuration per radio. The screen takes a radio; each
         link keeps its own bluetooth/device/display/position/power/
         network/LoRa/telemetry/module configs (configsByNode), reads and
         writes go through that radio's link (applyConfig/applyModuleConfig/
         begin/commit/request all take `via`). Radio detail has its own
         Device Configuration entry (attached radios only); the main
         Settings entry stays and says which radio it's for — the one
         sending now.

195. [x] Device Configuration: "Very low power" toggle, derived — on only
         while every recommended setting is in place, so any manual change
         switches it off; turning it on sets the form (Save applies),
         turning it off restores firmware defaults for what it touched.
         Checklist with the exact firmware fields: device telemetry off +
         interval never (this is where battery notices live), environment/
         power/air telemetry off, GPS disabled, fixed position off, position
         broadcast never, smart off, node info every 4 h, power saving on,
         screen off after 30 s, LED heartbeat off, Wi-Fi off, neighbor info/
         range test/store & forward/detection sensor/paxcounter/MQTT off.
         Sections gained explicit toggles for device telemetry, the three
         sensor telemetries, node info interval, power saving, LED, Wi-Fi,
         and each module. Separate "Transmit" toggle (lora.tx_enabled)
         written on top of the radio's full LoRa section.
         Correction (Sep 13): power.is_power_saving was in the profile and
         took a SenseCAP offline — the firmware docs: it "disables
         Bluetooth, Serial, WiFi, and the device's screen"; recovery is the
         user button or a reset. Removed from Very low power; now its own
         "Sleep between packets" switch with that warning.

194. [x] Node-info preload before DMs (fleet phase 2, ships alone). The
         radio tells us what it knows — its node-DB dump at connect and
         every packet heard — and a DM to anyone else first sends
         add_contact (user record + key from our store) and set_favorite
         so the radio's 80–100-entry table won't evict them, waits for the
         ack up to 2 s, then transmits. Once per peer per session (each
         add_contact is a flash write). A PKI NAK (34/39) clears the
         assumption so Retry preloads. Logged as "preloaded !xxxx onto the
         radio" in Mesh Traffic.

193. [x] Multi-radio ("fleet") support — product + implementation design
         with adversarial review in docs/MULTI_RADIO.md. Phased: data model
         → FleetConnector roaming → node-info preload before DMs (add_contact
         + favorite; independent, ships first) → add-radio flow with fleet
         settings and role/name recommendations → via-radio send/receive
         semantics and mailbox honesty (firmware keeps 8/32 packets for an
         absent phone) → forget & revoke with key rotation → test harness.
         Decisions made (draft 2). Progress: phase 2 (preload) done in
         194; phase 0 done — RadioEntity (synced; nickname, location,
         priority, firmware, last seen, battery), MessageEntity.viaNodeNum,
         store fleet CRUD, local-node SET for merge/prune/own-sender
         guards; phase 1 done — BLECentral (one CBCentralManager, pending
         connects for every fleet radio, BLELink per peripheral, up to all
         attached at once), RadioManager as a fleet of RadioLinks with a
         priority-ordered transmit radio and a facade (state, myNodeNum,
         loRa, configs) over it, per-link handshake/node-DB/known-peers/
         sync clock, Settings › Radios (attached now, fleet in order with
         drag-to-reorder, add radio, per-radio detail with mailbox note
         and companion line, forget), PairingView add-radio mode. Migration:
         the pre-fleet radio becomes fleet member #1. Phase 3 done — every link
         keeps its own channel table; drift vs the fleet (store channels +
         transmit LoRa) is computed at attach and shown per radio with
         Apply Fleet Settings (channels + LoRa via that link; never
         security or role); owner-name suggestion "<base> · <Location>" /
         "<3><L>" and role suggestion by location (second radio at a place
         → Client Mute; mobile → Client Mute) with explicit Use/Apply
         buttons, in both the radio detail and the add-radio flow. Phase 4
         done — Meshsites beacons through every attached radio and answers
         through the radio a request arrived on; sweeps skip messages
         whose radio is detached; Delivery Details shows Sent via / Heard
         by. Phase 6 done — RadioTransport protocol
         (BLECentral conforms), RadioManager takes an injected transport +
         defaults, HopsTests target with a scripted MockTransport: first
         radio becomes transmit; second attaches and reorder picks the
         sender; dropping the transmit radio fails over and re-arms; sends
         leave only through the transmit radio; forget removes from fleet
         and transport; store fleet CRUD; merge refused when any fleet
         radio shares a key, peers still fold; MeshName/MeshURL/routing
         words/partial-page helpers. Phase 5 done — Forget & Revoke Keys
         rotates every custom-keyed channel on the transmit radio, other
         radios show drift until re-applied. Field verification still
         needed with two radios: attach both, reorder, send, drop the top
         one mid-conversation, Apply Fleet Settings on the second.

192. [x] "Ask to Resend" did nothing visibly. It sent the NACK but recorded
         nothing: no pill state, no Mesh Traffic line, no ack tracking, and
         a disconnected radio returned silently. Now each request is tracked
         per gap: "Asking their radio…" → "Their radio has the request —
         waiting for their app…" on the routing ACK → the gap resolves on
         RESEND / hardens on TOO_OLD; a NAK shows the routing reason; 45 s
         without a reply explains that they may be out of direct range or
         not on Hops (relays here don't forward port 423). Not connected is
         said outright. Ask Again re-sends. Both directions log to Mesh
         Traffic as port "resend".

191. [x] My Site: "Notify me of form replies" toggle (off by default) next
         to Form Replies. A recorded POST from a reader posts a local
         notification: "New form reply on <site>" with the requester's
         node id, path, and sanitized, truncated field values. Preview
         submissions don't notify.

190. [x] My Site: Visitors row (unique radios, lifetime requests, last
         visit) with a list of who fetched pages and when, plus Reset.
         Counted per accepted request after retransmit/dup filtering,
         persisted in UserDefaults; beacons don't count.

189. [x] Meshsites render progressively. Each chunk rebuilds a live
         Transfer: the contiguous prefix of chunks is inflated with the
         streaming DEFLATE API (a truncated stream decodes to a valid page
         prefix), cut to whole UTF-8 characters and whole lines, and parsed
         in partial mode (an unclosed form at the bottom edge is withheld
         until it closes). The browser shows that partial page live and
         keeps it interactive — a link tap cancels the load and starts the
         next. A status card shows elapsed time, "n of N packets", bytes
         received of the expected total (known from the first chunk: 190 B
         per chunk but the last), decoded page bytes, silence duration, a
         retry marker, and a packet strip: the request cell (sent → acked
         or NAK) then one cell per chunk. Mesh Traffic now names Meshsites
         frames (request GET /path, chunk 3/8 · 190 B, beacon "…") on both
         directions. Verify on a real site: watch the strip fill and the
         page grow; tap a link mid-load.

188. [x] iOS killed Hops twice for CPU (Hops.cpu_resource_fatal, Sep 9 and
         10): 48 s CPU in 55 s while in the BACKGROUND, idle, one thread,
         382 MB. Symbolicated: main → SettingsView.body → radioSection →
         SettingsView.myNode (an all-nodes @Query scanned on every render)
         → SwiftData fetch. Every heard packet published trafficLog /
         meshPacketsHeard / lastMeshPacketAt on RadioManager, so every view
         observing the radio re-rendered per packet, Settings re-fetched
         every node each time, and on a busy mesh that never stopped. Fix:
         per-packet state moved to TrafficMonitor (publishes only while the
         app is active, once on return), Settings reads the local node
         through a one-row filtered @Query in a child view, and the traffic
         summary row is its own view. Watch for: further CPU reports, and
         whether Map/Chats need the same treatment.

187. [x] GitHub issues #1, #2, #4 (Max). #2: landed PR #3 (never delete
         the local radio's node record; refuse ambiguous same-key merges;
         guard the stale prune) with compile fixes, plus setOwner now
         requires MyInfo this session and merges/refusals log to Mesh
         Traffic as port "app". #4: mergeNode and the launch dedupe carry
         the real mesh name, battery, lastHeard, and position onto a
         placeholder keeper. #1: Trace Route in the node card's
         Reachability section — TRACEROUTE_APP request with want_response,
         reply rendered as "You → hop (SNR) → target" plus the return path,
         60 s timeout, one in flight per peer, logged in Mesh Traffic; the
         product vision now allows it as a text-only diagnostic.

186. [x] Tapping a notification crashed the app. ROOT CAUSE (from
         Hops-2026-09-11-205249.ips, symbolicated against a rebuild of
         c3df75b): SIGABRT from an NSAssertion in UIKit's
         _updateSnapshotAndStateRestorationWithAction, invoked from the
         completion of userNotificationCenter(_:didReceive:) on a
         cooperative background thread. The delegate used the `async`
         form; Swift calls the bridged completion from whatever executor
         the task ends on (after `await MainActor.run`, not main), and iOS
         26 asserts. Fix: both delegate methods now use the
         completion-handler form and complete on the main actor. The
         navigation rework from Sep 9 stays (it fixed the real
         pop-then-push loss) but was never the crash.
         Earlier notes — tapping a notification did not open the conversation;
         Sep 12: reporter confirms it is a CRASH on tap (build with the
         path-driven stack from Sep 9). Need the .ips: iOS Settings ›
         Privacy & Security › Analytics & Improvements › Analytics Data ›
         Hops-2026-09-… › share to the Mac. Prior attempts: TODO 6 (tab switch), 132-133
         (cold launch), 156 (land on the exact message). Investigate with
         evidence this time: crash reports on the Mac/phone, the tap
         delivery path (delegate set before didFinishLaunching returns?
         cold vs warm launch, pending-target consumption), and a log trail
         for every step of a tap.
         Sep 9: no Hops crash in the Sep 8 phone log (pid 15029 lived the
         whole window; the two ReportCrash corpses were other processes).
         Found a real mechanism: on iPhone the chat list used
         navigationDestination(item:) and, when another thread was already
         pushed, cleared the selection then re-set it on the next runloop —
         SwiftUI drops that push while the pop animation is in flight, so
         a tap for thread B while thread A was open did nothing. Now the
         compact stack is path-driven (NavigationStack(path:)) mirrored
         from selection; replacing the path swaps the detail atomically,
         and a back-button pop clears selection so the same key re-opens.
         The cold-launch replay is dispatched off the onAppear view update.
         Every step now logs to Mesh Traffic as port "app": "notification
         tap → handler|buffered", "open requested", "chat list opening
         (onChange|onAppear)". Verify: tap a notification with (a) the app
         killed, (b) backgrounded on another tab, (c) another thread open,
         (d) the same thread open. If it still fails, export Mesh Traffic
         and check iOS Settings › Privacy & Security › Analytics Data for
         Hops-*.ips crash files.

185. [x] Add/Edit Channel had no way to enter a specific key — only
         default, random, or none — so joining a friend's channel by hand
         was impossible. Added an "Enter a key" field (paste button when the
         clipboard has text): base64, URL-safe base64, or hex; must be 1,
         16, or 32 bytes, with the reason shown in red otherwise.

184. [ ] Map: tapping a node should offer a Message button. TODO 6/7 added
         one to the shared NodeCardView for "messageable" nodes only (role
         filter: routers, repeaters, trackers, sensors, TAK, hidden are
         excluded) — check whether the reporter's node fell through that
         filter or the map panel isn't showing the card's action at all.

183. [x] Channels: invite someone to a single channel, and show its key.
         Edit Channel now shows the key (base64, selectable) with Copy Key,
         and "Share This Channel…" opens a QR + link in the official
         add-mode form (meshtastic.org/e/?add=true#…, one channel, no LoRa
         config). Importing handles add mode both ways: an add link, or any
         link without LoRa config, appends to free slots and never touches
         the primary or radio settings; the confirm sheet says which slot.
         Verify: scan the invite with the official app and with Hops.

182. [x] Sends broke somewhere before build 9: DMs and channel messages
         used to ack in seconds, now every send errors.
         ROOT CAUSE (Sep 9): the reliability trailer (TODO 160, Aug 29) put
         the sequence number in bits 23–31 of Data.bitfield, but the
         firmware stores that field in one byte (mesh.options
         `*Data.bitfield int_size:8`). nanopb rejects the overflow, the
         whole ToRadio fails to decode, and the radio silently drops every
         non-tapback text Hops sends — no NAK, no QueueStatus, nothing on
         the air. Probes, admin, and emoji tapbacks carry no trailer, which
         is why they kept working (the decisive clue: "I can probe and get
         nodeinfo back but no acks"). Fix: trailer now lives in bits 2–7
         (bit 7 present, bits 2–6 seq mod 32; bits 0–1 stay the firmware's),
         gap window and counters are mod 32, Settings › Data has a kill
         switch, and the radio's QueueStatus for each send is logged in
         Mesh Traffic ("queue res=… free=…/…"). Build 11 on TestFlight
         still has the bug; Max's report in 176 was almost certainly this.
         Verify on device, then ship.
         Evidence so far (Sep 8): three channel broadcasts, all failed with
         the local timeout (-1), never a firmware NAK, no routing entry in
         Mesh Traffic, recipients received nothing, mesh quiet. So the
         radio never rejected the packet: either it never got it over BLE,
         or it transmitted something no neighbour could decode or relay
         (wrong PSK/hash → no rebroadcast in core-ports-only meshes → no
         implicit ack). Instrumentation added: every text and admin send
         now logs "→ channel N #ID" / "→ !node (PKI) #ID" in Mesh Traffic
         from our side; BLE write errors log as port "ble"; a 10 s watchdog
         detects a TORADIO write whose completion never comes, logs
         "Write to radio stalled", and resets the pump. Next: send once,
         read the log — a "sent" entry with no "ble" error and still no
         routing reply points at the radio/channel; a "stalled" entry is
         the BLE queue. Then pull-to-refresh in Settings: fresh battery
         proves the write path end-to-end.
         Phone log (sudo log collect, Sep 8 21:02–21:32) settles BLE: the
         radio link (CBDevice FD67A8FC) shows no disconnects at all; every
         Hops write is "Writing value with response to handle 0x002c"; the
         radio's FROMNUM notify follows some writes within ~130 ms and Hops
         reads the reply. The 21:20:49 link drop was the Apple Watch. So
         packets reach the firmware intact and it never NAKs them — the
         remaining fault is on the air: the radio does not transmit, or
         nobody hears/relays it. Mesh Traffic now has a share button that
         exports the log as text (in-memory only — export before
         relaunching). Decisive tests outstanding: does the rabbit node
         (direct, 8.8 dB) receive a phone send; does the official app send
         from the same radio; power-cycle the radio.
         Investigation plan (evidence first, then hypotheses in likelihood order):
         (1) Read the failure code on the phone — the transcript now shows
             it (TODO 181). "No response" (-1) means nothing came back at
             all; any firmware code means the radio got the packet.
         (2) Ask a recipient whether messages arrive anyway. If yes, this
             is ack accounting, not sending.
         (3) Instrument: log our own sends in Mesh Traffic ("You → message",
             packet id), log each BLE write completion/error, log every
             routing result with request id, and show that timeline in
             Delivery Details. Today the log only records received
             packets, so a send that never left the phone is invisible.
         (4) Send from the official app on the same radio. Fails there too
             → radio config (channel PSK/slot, rebroadcast mode, hop limit,
             firmware version). Works → Hops.
         (5) Bisect builds 6→9 (commits 823992c..b5951f1, Aug 26–30) on the
             phone with a radio; ~4 steps.
         Hypotheses: (a) BLE write queue head-of-line stall — `writing`
             stuck true or a poisoned frame (Meshsites beacon) retried, so
             every later ToRadio silently queues; tell-tale: pull-to-refresh
             telemetry also stops updating. (b) Radio TX pool saturated by
             the Aug 29 presence probes/announces + Meshsites beacons; test
             with both disabled. (c) Metro preset (Aug 29) left the sent
             channel on a slot whose PSK nobody shares — receives still
             work on another slot; broadcasts then get no rebroadcast, no
             implicit ack, only timeout. (d) Rebroadcast-mode / config
             transaction writes (Aug 25) left device config in a state the
             official app should reveal. (e) Sequence trailer in
             Data.bitfield (Aug 29) — firmware preserves it, low, but
             trivially testable by disabling. (f) Hold/re-hold path (TODO
             176) catching plain sends. (g) Firmware updated at the same
             time. (h) DM-only PKI codes 34/39 — secondary since channels
             fail too.

181. [x] Failed DMs now say why, as small text in the transcript: the
         failure line maps the firmware's Routing.Error to a short phrase
         (35 "Their radio didn't have your key — it does now, so retry",
         34 key mismatch, 39 your radio lacks their key, plus no-route,
         max-retransmit, too-large, duty-cycle, rate-limit) instead of a
         blanket "No response from their radio". One table
         (`RoutingFailure`) feeds both the transcript and Delivery Details,
         which also gained code 39. Still open from the send-path review:
         push an add_contact before each PKI DM (the official app does; a
         peer that rolled out of the radio's ~100-node DB otherwise NAKs
         39 before transmit), offer "trust their new key" on 34, and raise
         hop_limit to hops-away when larger.

180. [x] A just-sent message appeared below the fold with no auto-scroll.
         The transcript scrolled to the newest message's id: a no-op on the
         first pass (the row didn't exist in the hierarchy yet) and
         unreliable on the delayed pass inside a LazyVStack whose last row
         was still settling. Now the transcript ends in a permanent 1 pt
         anchor and every scroll-to-bottom targets that; the count change
         scrolls on the next runloop, then at 0.25 s and 0.6 s to catch late
         bubble layout. Verify on device: send from a scrolled-up position,
         send a 5-line message, send with the keyboard up.

179. [x] TestFlight feedback ×2 (builds 4 and 9): "messages come in out of
         order, possibly my node's clock is off" and "new messages I send
         appear before older messages". Screenshots: a channel with a
         "Jul 8, 2026" day header over messages clearly contemporaneous with
         the Aug 25 ones; a just-sent "Test" (Sending…) sitting above a
         dozen older incoming bubbles. Root cause: inbound messages were
         stamped with the packet's rx_time — the radio's clock — while
         sends use the phone's. Hops never set the radio's clock; a radio
         without GPS boots at the firmware build date (≈ Jul 8) and drifts,
         so live messages landed weeks back or in the future and sorted
         around sends arbitrarily. Fix: (1) set_time_only on every connect,
         as the official app does; (2) rx_time is believed only when it
         falls between the previous sync and this connect — a packet queued
         on the radio while we were away, the one case the phone has no
         better clock — everything else is stamped on arrival, strictly
         increasing so a replayed batch keeps its order; (3) RESEND
         recoveries clamp the peer-supplied time to now; (4) a startup
         repair pulls already-stored future-dated messages back to now in
         order. Not verified on a radio yet — check a reconnect replay and
         a fresh-boot radio.

178. [ ] App Review rejected 1.0 (7) under Guideline 2.5.4 (submission
         6fbef46d-02b4-4568-a452-5b8f1f9a422f, reviewed 2026-09-05 on an
         iPad Air 11" M3): "declares bluetooth-central in UIBackgroundModes
         but we are unable to locate any Bluetooth Low Energy
         functionality." Not a dispute about the permission — the reviewer
         had no Meshtastic radio, so nothing visibly used BLE. Apple's own
         next step: reply with a screen recording showing Bluetooth usage
         on a physical device, and put that recording in App Review
         Information > Notes for future submissions. To do:
         (a) record on a physical iPhone: Settings > Bluetooth showing the
             radio paired, then Hops pairing (scan, connect), a message
             round-trip with a second node, and backgrounding the app while
             a message arrives (that justifies the background mode);
         (b) reply in Resolution Center (draft below), attach the video;
         (c) add the video link + "requires a Meshtastic LoRa radio; BLE is
             the only transport" to App Review notes permanently;
         (d) DONE: BLETransport now creates its CBCentralManager lazily —
             at launch only when a radio is already paired (state
             restoration needs it early), otherwise on the first pairing
             scan, so a fresh install's Bluetooth prompt lands in context.
             Still optional: a reviewer demo mode (ScreenshotMode seed
             outside DEBUG).
         Reply draft: "Hops is a companion app for Meshtastic LoRa mesh
         radios; it has no function without one. All communication with
         the radio is over Bluetooth Low Energy via Core Bluetooth
         (BLETransport.swift: CBCentralManager scanning for the Meshtastic
         service UUID 6ba1b218-15a8-461f-9fa8-5dcae273eafd, connecting, and
         exchanging FromRadio/ToRadio characteristics). bluetooth-central
         background mode keeps that connection alive so incoming mesh
         messages can be delivered as notifications while the app is
         backgrounded. Attached is a screen recording on a physical iPhone
         showing pairing, a message round-trip, and delivery in the
         background. We've added the recording to the App Review notes."

177. [x] Bug report: a user couldn't reset their node name, possibly with an
         emoji in the short or long name. Probable cause: the firmware's
         nanopb limits are bytes (short_name max 4 + NUL, long_name 39 +
         NUL) but setOwner truncates by Swift Character (prefix(4) /
         prefix(36)), so a flag, skin-toned, or ZWJ emoji short name (8+
         bytes), or a long name of ~10+ emoji, overflows the field. nanopb
         then fails to decode the whole AdminMessage and the radio silently
         drops the set_owner — no error reaches the app (sendAdmin only
         wants a packet ack). Worse, IdentityView/PairingView write the new
         name into the local NodeEntity optimistically, so the UI shows it
         "saved" until the next NodeInfo from the radio reverts it — which
         reads exactly like "can't change my name". Fix: truncate by UTF-8
         byte count (4 / 39) without splitting a scalar, show a live byte
         budget in the fields, disable Save when over, and only mirror the
         name locally after the admin ack (or the radio's next NodeInfo).
         Also check whether the reporter's firmware rejects names on its own
         (newer firmware validates set_owner) and whether a blank/whitespace
         field was involved (the Save button already blocks those).
         Done: new `MeshName` helper clamps by UTF-8 bytes (4 / 39) without
         splitting a grapheme; both name editors clamp live and show a byte
         note whenever a name is non-ASCII; setOwner clamps again, mirrors
         the names via the store, and reverts them if the radio NAKs the
         admin packet (sendAdmin now returns the packet id). Not verified
         against a radio yet — needs an on-device check with a flag emoji.

176. [x] Released holds re-hold on timeout instead of failing (reported by
         Max): one heard packet proves the peer WAS transmitting, not that
         they're still in range — so a send-when-heard message whose
         release times out (no explicit NAK) quietly returns to waiting
         with a fresh packet id, up to 3 cycles, and the status line shows
         "tried Nx". Explicit NAKs and Send Now still fail honestly; only
         the device that released the hold re-holds it.

175. [x] Presence probes rate-limited to one per peer per 15 minutes (was
         5) — Probe Now on the node card still bypasses.

174. [x] Austin Mesh preset (manifest v6): LongFast defaults per
         austinmesh.org's own setup page (their custom energy went to
         MeshCore; Meshtastic runs stock), geo-tagged for the Near You
         badge. Also fixed OTA preset refresh: the remote manifest URL
         pointed at a repo that never existed — it now points at the app
         repo's own manifest, so committing a preset update to main ships
         it to every future install without an app update.

173. [x] Location-aware presets (manifest v5): each metro preset carries a
         service area (center + radius); when location is already
         authorized (never prompts), Mesh Setup sorts the local
         community's preset to the top with a "Near you" badge.

172. [x] Coverage map is prediction-only and less pixelated: the measured-
         signal dots (and 169's tap chips) are gone from the display —
         samples still feed the model as evidence, but the overlay IS the
         story. The field is now sampled at grid corners, smoothed one
         pass (kills single-cell islands), computed on a finer grid, and
         cells straddling a color bin split into triangles along the
         diagonal, so band boundaries run at angles instead of staircases.
         Legend copy rewritten to match.

171. [x] Metro preset research (manifest v4): added Puget Sound/Seattle
         (LongFast 20/3, pugetmesh.org), Greater Boston (LongFast
         defaults, bostonme.sh), Mountain Mesh N.GA/E.TN (MediumFast 45/5,
         mtnme.sh Oct 2025 migration), Freq51 Utah (MediumFast 51/7,
         freq51.net). Verified Bay Area is still MediumFast slot 45 per
         live bayme.sh docs (the meshtastic.org blog's MediumSlow mention
         was their earlier experiment). Colorado Mesh runs MediumFast but
         their site blocks fetches and the slot couldn't be confirmed —
         excluded rather than guessed.

170. [x] Coverage legend redesigned and relocated: bottom-leading (mapping
         convention; the old top-left floated oddly on iPad), width-capped,
         with a dedicated line — and matching glyph — explaining the
         measurement dots.

169. [x] The coverage dots explain themselves: they're spots where THIS
         phone paired its position with real measured SNR (the ground truth
         under the prediction). They're now tappable — 30 pt target, ring
         highlight, and a detail chip showing the dB and when it was
         sampled.

168. [x] The node card photo no longer renders translucent: the header
         avatar was inheriting the 2-hour "offline" dimming used in lists,
         which read as a broken image next to the explicit presence line.
         Full opacity on the card; lists keep the ambient cue.

167. [x] Key fingerprints render large for visual comparison: two rows of
         four groups, title-sized monospaced digits, alternating emphasis
         so two people can read them to each other without losing their
         place. Shared view used on node cards and your own identity
         screen.

166. [x] Node card redesigned as a contact card: big avatar + display name
         header with the mesh identity (SHRT · Long Name) and a live
         presence line always visible; Message/Directions right below;
         then Reachability (last heard, hops, probe forensics, Probe Now),
         Security (encryption, node ID, key fingerprint, reset), inline
         Custom Name editor (commits on return/Done) + photo, and a
         Details tail (mesh names, node number, battery, SNR).

165. [x] The DM (i) button is now a single glyph that says two things: a
         lock (encryption state — filled/open/orange shield) inside a ring
         whose color is their presence (green reachable / gray checking /
         orange not responding / faint unknown). Tapping opens the node
         card; the separate title-bar dot and shield are gone.

164. [x] Tapping the name in a DM title bar opens the node info panel.

163. [x] Node card gains a Reachability section: last probe time, whether
         it was answered, round-trip seconds, and reply hop count — plus a
         "Probe Now" button that bypasses the rate limit (disabled while
         one is in flight).

162. [x] Failed sends can be deleted from the long-press menu ("Delete",
         destructive) — local tidying alongside Retry; a failed message may
         still have been transmitted, so this is not an unsend. Same
         preview fix-up as delete-before-send.

161. [x] Reliability layer draft 1 (docs/RELIABILITY.md): outgoing texts
         carry a per-conversation sequence number in the undefined high bits
         of Data.bitfield (invisible to other clients, encrypted end-to-end);
         receivers detect gaps (mod-256 window, reset-tolerant) and render
         an inline "N messages didn't arrive · Ask to Resend" pill; a tiny
         port-423 protocol (NACK/RESEND/TOO_OLD) recovers the originals with
         their true timestamps, deduped by seq. Manual-tap NACKs only —
         airtime stays consented.

160. [x] Presence probe: opening a stale DM sends a unicast NodeInfo with
         want_response — the peer's FIRMWARE answers, no app needed. Title
         bar shows a presence dot (green reachable / dotted checking /
         hollow not-responding — never "offline"; RF is asymmetric). If the
         probe went unanswered, Send forks: "Send When They're Heard" /
         "Send Anyway". Any packet from the peer resolves the probe; 45 s
         timeout, one probe per peer per 5 min.

159. [x] Presence announce: on app-open and on radio connect, Hops
         broadcasts a nodeinfo (rate-limited to one per 30 min) so peers
         holding "send when their radio is heard" messages for us hear us
         and release them — coming online now actively triggers held mail
         instead of waiting for organic traffic.

158. [x] Notification deep-link hardening (reported as possible crash):
         a tap for conversation B while A was pushed popped-and-pushed in
         the same frame with an in-place identity swap — the classic
         SwiftUI navigation crash shape. Compact widths now pop first and
         push on the next runloop (fresh push = fresh state; the .id
         workaround is gone). Scroll targets are keyed to their
         conversation, so an open thread can no longer consume a target
         meant for the one being opened; target consumption runs outside
         the view-update transaction.

157. [x] Queued messages can be deleted before they send: long-press a
         message that's "Waiting for their radio" or in the outbox →
         "Delete — Don't Send" (destructive). Only statuses that have never
         touched a radio qualify; the conversation preview re-derives from
         the remaining messages.

156. [x] Notification taps land on the exact message: the packet id rides
         the deep link, the conversation grows its window until the message
         is loaded, centers it, and flashes a highlight — including when
         the conversation is already open. Compact-width deep links also
         stopped inheriting stale conversation state (.id on the pushed
         detail, matching the split-view path).

155. [x] Meshdown supports inline [label](target) links in paragraphs and
         list items: site paths navigate in the browser, http(s) opens in
         Safari, any other scheme stays literal text. Spec table updated.

154. [x] Node cards show the node's ID ("!xxxxxxxx", monospaced,
         selectable) above Last heard — pairs with hex node-id search and
         log correlation.

153. [x] Settings → Your name shows your own node ID ("!8ac3c723" form)
         and decimal node number, selectable, alongside the key
         fingerprint — the identity trio in one place.

152. [x] Single back button in the local site preview too: the served-site
         viewer (Preview Site, and Nearby Sites' "served by you" row) had
         the same double-chevron problem fixed for remote sites in 137 —
         same fix, one chevron that walks history then pops to the app.

151. [x] "Send My Node Info" failed 100% of the time: the broadcast never
         set want_ack (only want_response), so no routing result ever came
         back and the 5-minute stale sweep marked every note failed. Now
         sends with the same flags as channel texts (want_ack, no
         want_response — which on a broadcast would ask every receiver to
         reply with theirs).

150. [x] Meshdown supports web hyperlinks: `=> https://… Label` renders as
         an external link (distinct arrow-out icon) that opens in Safari.
         Spec table updated; site-internal `=> /path` links unchanged.

149. [x] Meshsite load failures say where the request died instead of a
         generic timeout: the client tracks routing results for its own
         request packets, so 45 s of silence now reports "never left your
         radio" vs "radio couldn't deliver (routing error N)" vs
         "transmitted but the site never answered — server offline or
         re-keyed radio (Reset Encryption Key hint)".

148. [x] One friend, four node entries: firmware renumbers a radio on node-
         number conflicts (and NodeDB resets), but the device keypair
         survives — and everything was keyed on the number. Nodes sharing a
         public key now auto-merge into the current number (messages, DM
         thread, channel attribution, custom name and photo follow the
         person), both live when an announce arrives and as a launch repair
         for existing ghosts. Ghosts without a pinned key can't be linked
         automatically — a manual merge action is the follow-up if needed.

147. [x] "Last heard 10 months ago" on a node being actively heard: every
         packet's liveness was stamped from the packet's rx_time — the
         radio's RTC, which is months stale on clockless nodes. Live
         packets now stamp the phone's own clock; the connect-time NodeDB
         import only moves lastHeard forward (clamped to now), so a stale
         dump can't bury fresh evidence. Stale-looking SNR/hops readings
         rode the same bug.

146. [x] My Site links out to github.com/morria/Meshsite — the open spec
         and the Python server — so anyone can host a site off-phone.

145. [x] The empty Sites tab calls out the Core-ports-only trap: when the
         radio's rebroadcast mode is CORE_PORTNUMS_ONLY (which silently
         drops port-421 traffic before it reaches the app — cost a tester
         an afternoon), the "No sites nearby" description turns orange and
         points at Device Configuration → Mesh Relay.

144. [x] "Send My Node Info" drops a centered gray note in the channel
         transcript ("Sending your node info…" → "You shared your node
         info", red on failure). The note rides the real packet id, so the
         ack/sweep machinery reports whether it actually transmitted.

143. [x] Conversation rows show the last message's delivery state beside
         the preview when it was outgoing: clock (waiting), up-arrow
         (sending), antenna (relayed), check (sent to mesh), filled check
         (delivered), red exclamation (failed). Status mirrors live on the
         conversation entity (CloudKit-safe additive fields), updated at
         every transition — including retries, which rename the packet id.

142. [x] iPad/macOS UX pass: Messages is a sidebar+detail split view on
         regular widths (compact keeps a real NavigationStack — a collapsed
         split view only auto-pushes List selection, which briefly broke
         iPhone tap navigation); hardware keyboard gets ⌘1-n tab switching,
         ⌘N compose, ⌘F search, Esc cancel, Return-to-send (Shift-Return
         newline); pointer hover on rows and pins; the map node card is a
         trailing inspector on iPad/Mac. Mac runs as "Designed for iPad" —
         verify the ASC availability box is checked before promising it to
         testers.

141. [x] Settings reorganized into 7 sections (was 9): Radio keeps only the
         hardware (status card absorbs the firmware row; Device Configuration
         moves in with a contents subtitle; Forget stays last). New "On the
         Mesh" (Your name, Channels & QR codes), "App" (units + Battery
         Saver merged), "Data" (Mesh traffic — moved out of Radio as a
         diagnostic — + node retention). Mesh setup untouched. Meshsites
         footer no longer claims "Development builds only" (stale since
         TODO 140).

140. [x] Meshsites ships in production builds: the AppStore config now
         carries the MESHSITES compilation flag (was dev/Release only), so
         TestFlight and App Store builds include the Sites tab + serving —
         still behind the Settings toggle, default off. Uploaded to
         TestFlight and submitted for beta review.

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
