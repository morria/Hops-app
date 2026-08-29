# Hops Reliability Layer (draft 1)

Two mechanisms that make LoRa messaging honest about loss and able to repair
it: per-conversation **sequence numbers** riding invisibly on normal texts,
and a tiny **resend protocol** on port 423.

## Sequence trailer (Data.bitfield)

Outgoing non-tapback texts set, in the `Data.bitfield` uint32 (which travels
inside the encrypted payload, end-to-end, and is ignored by clients that
don't know it):

| Bits | Meaning |
|---|---|
| 23 | Hops sequence present |
| 24–31 | sequence number, mod 256 |

- One counter per (sender → conversation): per-peer for DMs, per-(sender,
  channel) for channels. Persisted on both ends.
- Receiver gap rule (mod-256 window): forward delta 1 = in order; delta 2–8 =
  a gap of delta−1 messages, surfaced in the transcript where the hole is;
  anything else (duplicate, backward, larger) = counter reset — resync
  silently, never claim a giant gap after a reinstall.
- Senders that never set bit 23 (official app, old Hops) simply get no gap
  detection. Bits 0–22 are left exactly as found (OK_TO_MQTT etc.).
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
