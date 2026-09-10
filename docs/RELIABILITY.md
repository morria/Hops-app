# Hops Reliability Layer (draft 1)

Two mechanisms that make LoRa messaging honest about loss and able to repair
it: per-conversation **sequence numbers** riding invisibly on normal texts,
and a tiny **resend protocol** on port 423.

## Sequence trailer (Data.bitfield)

`Data.bitfield` is a `uint32` on the wire but the firmware stores it in **one
byte** (`mesh.options`: `*Data.bitfield int_size:8`). Anything above bit 7
makes nanopb reject the whole ToRadio and the radio silently drops the
packet — draft 1 used bits 23–31 and every Hops text vanished (TODO 182).
Bits 0–1 belong to the firmware (OK_TO_MQTT, WANT_RESPONSE). Outgoing
non-tapback texts therefore set:

| Bits | Meaning |
|---|---|
| 7 | Hops sequence present |
| 2–6 | sequence number, mod 32 |
| 0–1 | left exactly as found (firmware flags) |

- One counter per (sender → conversation): per-peer for DMs, per-(sender,
  channel) for channels. Persisted on both ends.
- Receiver gap rule (mod-32 window): forward delta 1 = in order; delta 2–8 =
  a gap of delta−1 messages, surfaced in the transcript where the hole is;
  anything else (duplicate, backward, larger) = counter reset — resync
  silently, never claim a giant gap after a reinstall.
- Senders that never set bit 7 (official app, old Hops) simply get no gap
  detection.
- Settings › Data has a kill switch ("Sequence numbers on sends"), default on.
- Known limit: two of the user's own devices share the conversation counter
  via iCloud; near-simultaneous sends from both can duplicate a seq. Receiver
  dedupe by (sender, conversation, seq) absorbs it.

## Resend protocol (port 423, unicast, want_ack)

Binary frames, big-endian. `kind`: 0 = DM (conversation implied by the two
nodes), 1 = channel (`ch` = channel index). All frames are addressed unicast
and encrypted by firmware like any DM (PKI when keys are known).

| Frame | Layout |
|---|---|
| NACK `0x01` | `01 kind ch count seq×count` (count ≤ 8) — "resend these" |
| RESEND `0x02` | `02 kind ch seq time_u32 utf8-text` — original send time carried so the message slots into its true place |
| TOO_OLD `0x03` | `03 kind ch seq` — sender no longer has it |

- NACKs are user-initiated ("Ask to Resend" on the gap pill) — no automatic
  NACKing in draft 1; tapping again re-asks. Airtime stays consented.
- Sender answers from its own store (messages keep their seq), most recent
  match wins; anything it can't find gets TOO_OLD, which hardens the gap pill
  into a permanent-loss marker.
- Receiver dedupes recovered messages by (sender, conversation, seq) and
  resolves gap markers as seqs arrive — organically or via RESEND.
