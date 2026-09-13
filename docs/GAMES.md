# Games over the mesh — design (draft 1)

Two-player, one-turn-at-a-time games between Hops users, carried on their
own port, where a move counts only once both sides hold the same state.
Feature-flagged: Settings › Experimental › Games adds a Games tab.

## 1. What the network allows

LoRa gives us packets of ~200 bytes, seconds to minutes of latency, loss,
duplication, and reordering, plus the fleet's "the ack may land on another
radio" semantics. Every game here fits that: a move is a few bytes, turns
are rare, and nobody minds waiting. The design leans on three rules:

1. **State is the move log.** Both phones rebuild the position from the
   ordered list of moves; nothing else is ever transmitted about state.
2. **A move is committed only on agreement.** The mover's turn ends when the
   opponent's app acknowledges the move *and* reports the same state hash.
   A radio-level ack proves delivery to a radio, not agreement, so it is
   ignored for game purposes.
3. **Everything is idempotent.** Moves and acks carry the session id and a
   sequence number; anything already seen is re-acknowledged and dropped.

## 2. Protocol (port 425, `GAMES`)

Unicast frames, `want_ack` on, default hop limit (games cross the mesh;
unlike Meshsites there is no direct-RF requirement). Big-endian.

| Type | Layout | Notes |
|---|---|---|
| `0x01 INVITE` | `01 ver session:u32 game:u8 options[n]` | inviter proposes; `options` are game-specific (e.g. who moves first, seed) |
| `0x02 ACCEPT` | `02 session` | acceptor's app confirms; both create the session locally |
| `0x03 DECLINE` | `03 session` | |
| `0x04 MOVE` | `04 session seq:u16 prevHash:u32 move[n]` | `prevHash` = hash of the state this move is played on |
| `0x05 ACK` | `05 session seq:u16 stateHash:u32` | receiver applied `seq`; hash of the resulting state |
| `0x06 NAK` | `06 session seq:u16 reason:u8` | illegal move / wrong prevHash / unknown session |
| `0x07 RESYNC` | `07 session fromSeq:u16` | "send me moves from here" |
| `0x08 SYNC` | `08 session fromSeq:u16 moves…` | reply, as many moves as fit; repeat |
| `0x09 END` | `09 session reason:u8` | resign / draw offer / draw accept / abandon |

Commit rule, mover side: after sending `MOVE n`, the session is
`waitingForAgreement(n)`. It becomes the opponent's turn only when
`ACK n` arrives with `stateHash == hash(S_n)`. A `NAK` rolls the move back
and shows why. No ack after 60 s → resend the same frame (same seq, same
bytes) on every reconnect and on a "Nudge" tap, forever; there is no clock.

Commit rule, receiver side: on `MOVE n` with `prevHash == hash(S_{n-1})`,
apply, persist, `ACK n`. If `prevHash` mismatches, the two sides diverged:
reply `NAK wrongPrev` and send `RESYNC fromSeq = mySeq+1`; the peer answers
with `SYNC`. Duplicates (`seq <= mySeq`) are re-acked and dropped.

Hash: FNV-1a 32-bit over the canonical state encoding each engine defines.

Session id: 32 random bits chosen by the inviter; the pair (peer node,
session) is unique. Ids and seqs in the clear; the payload is encrypted by
the radio like any DM (PKI when keys are known).

## 3. Library

```
protocol GameEngine {
    static var id: UInt8 { get }            // wire id
    static var title: String { get }
    associatedtype State: Codable, Equatable
    associatedtype Move: Codable, Equatable
    static func initialState(options: Data) -> State
    static func apply(_ move: Move, to state: State, by player: Player) throws -> State
    static func legalMoves(in state: State, for player: Player) -> [Move]
    static func result(of state: State) -> GameResult?    // nil = ongoing
    static func encode(_ move: Move) -> Data               // fixed width, ≤ 8 bytes
    static func decode(_ data: Data) -> Move?
    static func canonical(_ state: State) -> Data          // for the hash
}
```

- `GameSession` (SwiftData, synced): `id`, `gameId`, `peerNum`, `myPlayer`,
  `options`, `moves: Data` (concatenated encoded moves), `seq`,
  `phase` (invited / accepted / myTurn / waitingForAgreement / theirTurn /
  finished / declined / abandoned), `pendingMove`, `result`, `updatedAt`,
  `viaNodeNum`.
- `GameCoordinator` (main actor): owns sessions, encodes/decodes frames,
  runs the commit rules, resends on reconnect, posts "your turn"
  notifications, and hands the UI a `GameSnapshot`. Registered with
  RadioManager for port 425 the way the reliability port is.
- `GameRegistry`: the list of engines; each engine ships with a SwiftUI
  `GameBoardView(state:, legalMoves:, onMove:)`.
- Fleet-aware: moves leave through the transmit radio; acks and moves in
  are accepted from any attached radio; `viaNodeNum` recorded like
  messages. Multi-device: sessions sync via iCloud; the device that sends
  the move owns the pending state until agreement, others show "waiting".

## 4. UI

- Settings › Experimental › **Games** toggle (Meshsites keeps its own
  section). On → a Games tab.
- Games tab: **In progress** (sessions, most recent first, with "Your
  turn" / "Waiting for Max" / "Finished · you won"), then **Games**, one
  row per engine with New Game… (node picker, same as New Message; only
  nodes that are messageable) and the count of open sessions.
- Board screen: the board, whose turn it is, a "Move sent — waiting for
  agreement" state that can't be interacted with, Nudge, Resign, and a
  move log. An invite shows Accept / Decline.
- Incoming invite: a notification and a row at the top of the tab.

## 5. Games, in order

1. Tic-tac-toe (1-byte move), Connect Four (1 byte), Dots and Boxes (2
   bytes) — tiny engines, prove the protocol.
2. Checkers (2 bytes: from/to squares, multi-jump as a sequence).
3. Battleship (placement is local; a shot is 1 byte; the hit/miss travels
   back inside the ACK's `stateHash`… no — it's a move by the defender:
   `report` move 1 byte, so both boards stay a move log).
4. Chess: 3 bytes (from, to, promotion). Full legality (check, castling,
   en passant, repetition) is the largest engine; consider vendoring a
   permissively-licensed Swift rules library rather than writing one.
5. Later: Go 9×9, Reversi, Mancala, Hangman, Wordle-by-seed.

## 6. Phases

| Phase | Scope | Size |
|---|---|---|
| A | Protocol + coordinator + session model + port registration + tests with the mock transport (lost ack, duplicate move, wrong prevHash → resync, resend on reconnect) | 2 days |
| B | Games tab, toggle, node picker, board scaffold, notifications | 1.5 days |
| C | Tic-tac-toe, Connect Four, Dots and Boxes with engine unit tests | 1 day |
| D | Checkers, Battleship | 1.5 days |
| E | Chess (with a vendored rules library) | 2 days |

## 7. Adversarial notes

- Two moves cross in flight (both think it's their turn after a resync):
  `prevHash` rejects the loser; the NAK reason says "not your turn".
- A peer on an old Hops without Games: no reply, ever. Show "No answer —
  they may not have Games on" after a day; the invite stays resendable.
- Cheating is out of scope; both engines validate every move, so at worst a
  modified client can only make legal moves.
- Airtime: a game is a handful of ~20-byte packets a day. A Nudge is rate
  limited to once per 15 minutes per session.
- Storage: move logs are bytes; a thousand chess games is under a megabyte.
