# Meshsites — Protocol Specification v1 (draft 5)

Tiny sites served by Meshtastic nodes to directly-reachable clients. A server
is any node (typically radio + attached computer) that answers requests with
small text pages. A client discovers nearby servers passively and browses
their pages. Think Gopher-over-LoRa: read-mostly, slow, local by physics.

Design goals, in order:

1. **Zero mesh burden.** Meshsites traffic never consumes relay airtime.
   Everything is direct RF between two radios that can already hear each other.
2. **One-packet requests.** A request always fits a single LoRa frame.
3. **Small pages.** Hard cap 3 056 bytes compressed (16 × 191) per response.
4. **Trivially implementable.** A weekend project in any language with a
   Meshtastic serial/BLE API.

## 1. Transport

- Carried in Meshtastic `MeshPacket` / `Data` payloads on **port 421**
  (private application range 256–511).
- All frames are unicast except BEACON, which is broadcast (`to = 0xFFFFFFFF`).
- Every Meshsites packet MUST be sent with **`hop_limit = 1`**.
- Receivers MUST discard any Meshsites frame that was relayed: if the received
  packet has `hop_start > 0 && hop_limit < hop_start`, drop it silently.
  Combined with `hop_limit = 1`, this bounds all Meshsites traffic to the
  direct RF link between client and server.
- REQUEST, CHUNK, and NOT_MODIFIED frames SHOULD set `want_ack` (a lost
  NOT_MODIFIED otherwise costs the client a full timeout). The server SHOULD
  pace chunk transmission: send chunk *n+1* only after chunk *n* is acked or
  8 seconds have passed. ERROR and BEACON frames MUST NOT set `want_ack`.
- Maximum Meshsites frame payload: **200 bytes** (fits every modem preset).
  Received frames larger than this are malformed — ignore them.
- All frames travel on the sending node's **primary channel** (index 0) with
  that channel's encryption. PKI-encrypted unicast MUST NOT be used — pages
  are public by nature and channel-key crypto keeps servers simple.
- **Sender verification**: a client MUST accept CHUNK, ERROR, and
  NOT_MODIFIED frames only from the node its REQUEST was addressed to.
  Frames matching a pending id but arriving from any other node are ignored
  (ids travel in the clear; without this rule any nearby node could forge a
  response).
- Servers and clients MUST ignore frames with unknown type bytes (forward
  compatibility). Malformed frames are ignored silently, with one exception:
  a malformed REQUEST addressed to the server whose id is still parseable
  (e.g. empty path, body bytes on a GET) gets ERROR 3 so the client can fail
  fast instead of timing out.

## 2. Frames

The first payload byte is the frame type. Multi-byte integers are big-endian.

### 0x01 BEACON  (server → broadcast)

```
[0x01][version u8 = 1][site name, UTF-8, 1–40 bytes]
```

Sent on server startup and every 5 minutes ± 30 s jitter thereafter.
Clients treat a site as gone if no beacon is heard for 20 minutes.
Version is the highest protocol version the server speaks; v1 clients
MAY browse any server whose beacon version ≥ 1. Out-of-spec beacons
(version 0, empty name, name longer than 40 bytes) are discarded whole —
clients MUST NOT truncate-and-accept, so all clients agree on which sites
exist.

### 0x02 REQUEST  (client → server)

```
[0x02][id u16][method u8][etag u32][path_len u8][path+query UTF-8][body bytes…]
```

- `id`: random nonzero, chosen by the client, echoed in every response
  frame. A client MUST NOT reuse an id it has an outstanding request for.
- `method`: 0 = GET, 1 = POST.
- `etag`: the client's cached validator for this exact path+query (see §3.5),
  or 0 if it has none. MUST be 0 for POST.
- `path+query`: absolute path starting `/`, optionally `?k=v&k2=v2`
  (URL-encoded). `path_len` counts these bytes. Max 120 bytes.
- `body`: POST only — `application/x-www-form-urlencoded` pairs, uncompressed.
  A GET frame MUST NOT carry bytes after the path; servers reject one that
  does with ERROR 3.
- The whole frame MUST fit in one packet (≤ 200 bytes). Clients enforce this
  by truncating form values before sending.

### 0x03 CHUNK  (server → client)

```
[0x03][id u16][seq u8][total u8][etag u32][data bytes…]
```

- Response content = **raw DEFLATE (RFC 1951, no zlib/gzip header)** of the
  UTF-8 Meshdown page, split in order across `total` chunks.
- `seq` is 0-based; `total` is identical in every chunk and MUST be ≤ 16.
- `etag` is the validator of the page being served (§3.5), identical in every
  chunk of a response.
- All chunks except the last SHOULD carry the maximum data payload
  (**191 bytes**) so the client can estimate progress.

### 0x04 ERROR  (server → client)

```
[0x04][id u16][code u8][message UTF-8, optional, ≤ 120 bytes]
```

Codes: 1 NOT_FOUND · 2 TOO_LARGE · 3 BAD_REQUEST · 4 SERVER_ERROR · 5 BUSY.

### 0x05 NOT_MODIFIED  (server → client)

```
[0x05][id u16][etag u32]
```

Sent instead of chunks when the REQUEST's etag matches the current page
(§3.5). One packet ends the transaction — this is what makes revalidation
nearly free.

## 3. Reliability

- Link-level retransmission comes from `want_ack` (firmware handles it).
  A client MAY additionally treat a transport-level NAK (routing error) for
  its REQUEST packet as immediate failure instead of waiting out the timeout.
- If a client's reassembly is incomplete **45 seconds** after the most recent
  frame for that id (or after the request, if nothing arrived), the request
  fails. The client MAY retry once, and SHOULD reuse the same id so the
  server's response cache can re-serve the already-rendered chunks.
- The server SHOULD cache the rendered response (chunks or NOT_MODIFIED)
  per `(requester, id)` for 2 minutes, keyed by the *full* request content:
  if the same id arrives with a different method/etag/path/body (random u16
  ids do collide), render fresh and replace the entry. A duplicate of a
  request that is still being answered is dropped silently — it is most
  likely a link-level retransmit, and BUSY would be wrong.
- The server maintains at most **one in-flight response per requester**; a
  second concurrent REQUEST from the same node gets ERROR 5 BUSY. Distinct
  requesters MAY be served concurrently but the server SHOULD serialize radio
  writes.

## 3.5 Caching and cache busting

Airtime is the scarce resource; a full page is up to 16 packets while a
revalidation is 2. Caching is validator-based — there are no freshness
lifetimes to get wrong, and busting is automatic because the validator is a
content hash.

- **etag** = FNV-1a 32-bit hash of the page's UTF-8 Meshdown bytes
  (*before* compression, so implementations' DEFLATE differences don't
  matter): `h = 2166136261; for each byte b: h = (h XOR b) × 16777619 mod 2³²`.
  If the result is 0, substitute 1 (0 on the wire means "no validator").
- **Server**: render the page, compute its etag. If the REQUEST carried the
  same etag, answer 0x05 NOT_MODIFIED; otherwise serve chunks carrying the
  etag. Applies to GET only — POST is never answered NOT_MODIFIED. Dynamic
  pages need no special handling: when their content changes, the hash
  changes, and the cache busts itself.
- **Client**: cache at most one entry per `(server, path+query)`:
  `{etag, page, fetched-at}`. On GET, send the cached etag; on NOT_MODIFIED
  render the cached page; on chunks replace the entry. A client MUST only
  send an etag whose page it still holds. POST responses MUST NOT be cached
  or served from cache.
- **Back navigation** MAY be served straight from cache with no request at
  all. Ordinary navigation and user-initiated refresh SHOULD revalidate
  (send the etag). Cache entries SHOULD be dropped after 24 hours — the
  hash guarantees correctness, expiry just bounds storage.

## 4. Meshdown

Line-oriented UTF-8. Every line is one of:

| Line | Meaning |
|---|---|
| `# T` / `## T` / `### T` | heading, levels 1–3 |
| `* text` | list item |
| `=> /path Label text` | link (path may carry `?query`) |
| `---` | horizontal rule |
| `[form get /path]` or `[form post /path]` | opens a form |
| `[field name Label text]` | text input inside a form (name = `[a-z0-9_]+`) |
| `[submit Label]` | submit button inside a form |
| `[/form]` | closes a form |
| blank | block separator |
| anything else | paragraph text |

- Form lines outside `[form]`…`[/form]` are rendered as plain paragraphs.
- Submission: `get` → request `path?name=value&…` (joined with `&` if the
  form path already carries a query); `post` → pairs go in the REQUEST body.
  Both URL-encoded (space as `%20`). Clients enforce the one-packet request
  rule by truncating form values before sending.
- Clients render unknown `[…]` lines as plain text (forward compatibility).
- Edge cases, pinned down so every client renders alike:
  - Servers SHOULD emit LF line endings; clients MUST tolerate CRLF and
    trailing whitespace on any line.
  - Plain text inside an open form renders as if it preceded the form.
  - An unclosed `[form]` at end of page is implicitly closed.
  - A form with no `[submit]` line gets a default "Submit" button; a form
    with zero fields is legal (button-only actions).
  - Duplicate `[field]` names within one form: later duplicates are dropped.
  - Malformed bracket lines (bare `[submit]`, bad method, bad field name)
    render as plain text like any unknown line.

## 5. Server behavior

- `GET /` MUST return the home page.
- Static mapping: `/foo` → `foo.md` in the site directory; `/` → `index.md`.
  Requests containing `..`, empty paths, or paths not starting `/` get
  ERROR 3. Unknown paths get ERROR 1.
- Dynamic handlers (e.g. a guestbook POST target) are server-local details;
  a handler answers with a normal Meshdown page or an ERROR.
- If a page deflates to more than 16 chunks, respond ERROR 2 (preferred) or
  serve a server-trimmed page.
- Servers MUST NOT initiate anything toward a client except BEACON and
  responses to that client's requests.

## 6. Client behavior

- Discovery is **passive only** — no probe frames; sites appear as beacons
  are heard and expire 20 minutes after the last one.
- Enforce the relay-discard and sender-verification rules (§1) on every
  received frame.
- Enforce the one-packet request rule by bounding form input length.
- Decompressed page size cap: 65 536 bytes inclusive; a response exceeding
  it is discarded as malformed (defense against decompression bombs).
- One in-flight request per server; UI SHOULD show chunk progress.

## 7. Versioning

Frame-type space and the beacon version byte are the extension points. v2
candidates (explicitly out of scope for v1): chunk re-request (selective
NACK), binary resource frames (images), multi-packet requests.
