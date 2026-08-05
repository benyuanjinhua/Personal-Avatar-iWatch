# Audio Realtime Agent Gateway (ESS-403)

Secure WSS entry that lets iPhone (and, transitively, Watch) speak realtime
audio directly with the upstream Agent, without routing media through the Mac
Remote Frontend Bridge. This is the server-side half of the ESS-388 direct
link: Bridge stays as a feature-flagged fallback but is no longer the default
realtime media plane.

## Red lines (from ESS-388 v_final / ESS-403)

- Clients (iPhone/Watch) never hold long-lived Agent or provider keys. Only
  device credentials pinned in Keychain and short-lived, single-use tokens
  minted by this Gateway ever leave the server side.
- Every media event carries `session_id`, `request_id` (a.k.a. `turn_id`),
  `response_id`, `generation`, and a monotonic `sequence`. `audio.done`
  carries `final_sequence`. Old-generation frames are dropped and counted as
  `stale_generation`.
- Server-authoritative cancel: on `cancel`, the current generation stops
  emitting deltas immediately, the client gets `cancel.ack`, and any late
  agent frames for that generation are discarded server-side.
- Every handshake, first-uplink, first-downlink, done, cancel, and disconnect
  is emitted as a structured log record with `request_id` + `session_id` so
  a single turn can be reconstructed end-to-end.
- No provider key or ephemeral token is ever written to logs.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/v1/health` | none (source-gated) | Liveness / build metadata |
| POST | `/v1/realtime/session-token` | HMAC device signature | Mint an ephemeral session token bound to a specific `device_id`, `session_id`, `request_id`, `generation`. |
| POST | `/v1/realtime/session-token/revoke` | HMAC device signature | Revoke a previously issued token before use (safety valve). |
| WSS | `/api/realtime` | Bearer <token> | Realtime bidirectional media plane. Token is single-use (single upgrade). |

The service listens over TLS (`wss://`) and honours an IP allowlist
(loopback + Tailnet CIDRs). Development-only `ws://` mode requires the
explicit config flag `dev_allow_plain_ws: true` and refuses to start on any
public address. Production defaults reject plain WS.

### Ephemeral session tokens

`POST /v1/realtime/session-token`

Request body (HMAC-signed with per-device shared secret, see `## Auth`):

```json
{
  "protocol_version": 1,
  "device_id": "jackson-iphone",
  "session_id": "session_...",
  "request_id": "req_...",
  "generation": 1,
  "ttl_ms": 30000
}
```

Response (201):

```json
{
  "token": "rtk_<opaque>",
  "expires_at": 1723145678901,
  "ttl_ms": 30000,
  "scope": {
    "device_id": "jackson-iphone",
    "session_id": "session_...",
    "request_id": "req_...",
    "generation": 1
  }
}
```

Semantics:

- The token is a random 32-byte opaque string; only its SHA-256 is stored
  server-side. It authorises **one** WSS upgrade whose query string /
  `Sec-WebSocket-Protocol` payload matches the pinned scope exactly.
- `ttl_ms` is clamped to `[1_000, max_token_ttl_ms]` (default 90 s per
  ESS-388 A1). Tokens are burned on first upgrade attempt (success or fail).
- Generation is monotonic per (device_id, session_id): the issuer refuses to
  step backwards. Barge-in sends `generation + 1`.
- Failure returns a structured JSON envelope with a stable `code` and never
  echoes the token or provider key.

`POST /v1/realtime/session-token/revoke` accepts the token id (SHA-256
prefix, 8 hex chars) and burns any matching unused token.

### WSS `/api/realtime`

Client sends the token in `Authorization: Bearer rtk_...` and pins scope in
query string (`?device_id=...&session_id=...&request_id=...&generation=...`).
All four fields are required; the server reads them verbatim from the URL and
rejects the upgrade with `ERR_TOKEN_INVALID` if any of the four disagrees with
the token's pinned scope (see `server.mjs` `presentedScope`).

Server verifies token scope matches the URL, burns the token, then upgrades.

#### Framing

All frames are JSON text messages. Binary frames are rejected with
`ERR_UNSUPPORTED_BINARY`.

Every non-`ping`/`pong` frame includes these five fields:

- `session_id` (string)
- `request_id` (string)  — the turn id
- `response_id` (string, optional until first server-produced response)
- `generation` (integer, monotonic per session)
- `sequence` (integer, monotonic within a generation for `audio.*`)

Additional per-type fields are described below. Fields not listed are
rejected as `ERR_UNKNOWN_FIELD` (strict schema — the contract must be
verifiable).

#### Client → Server events

| type | Body | Notes |
|---|---|---|
| `session.start` | scope + `protocol_version` | Must be first message. Establishes the session. Server replies `ready` on success. |
| `audio.append` | `sequence`, `audio` (base64 PCM16LE 16 kHz), `sample_rate?`, `codec?` | Sequences must be monotone and dense (no gaps within a turn). |
| `audio.commit` | `sequence` (last accepted) | Ends the uplink for the current turn. |
| `cancel` | `reason?` | Cancels the current `generation`. Server responds with `cancel.ack` and stops emitting deltas for the cancelled generation. |
| `playback.started` | `response_id` | Client reports first sample rendered. |
| `playback.ended` | `response_id` | Client reports last sample consumed. |
| `ping` | `nonce` | Heartbeat probe. Server replies `pong`. |
| `close` | `reason?` | Graceful close. |

#### Server → Client events

| type | Body | Notes |
|---|---|---|
| `ready` | echoes scope, adds `heartbeat_interval_ms` | Sent once after `session.start` is accepted. |
| `audio.delta` | `sequence`, `sample_rate`, `codec`, `audio` (base64 PCM16LE 24 kHz) | Sequences are monotone and dense per `response_id`. |
| `audio.done` | `final_sequence` | Barrier — client waits until it has seen every `0..final_sequence` before signalling playback complete. |
| `cancel.ack` | echoes scope + `cancelled_response_id?` | Response to a `cancel` message. |
| `error` | `code`, `retriable`, `detail?` | Structured failure; connection is closed with WebSocket code 1008 unless `retriable: true`. |
| `pong` | echoes `nonce` | Heartbeat reply. |

Server-initiated `ping` frames from `ws.ping()` are honoured but the
protocol also supports the JSON `ping`/`pong` pair for platforms that can't
inspect control frames.

#### Ordering / dedup guarantees

- Duplicated `sequence` values (same `generation`, same direction) are
  silently dropped and logged as `duplicate_sequence`.
- Out-of-order client uplink is rejected with `ERR_STREAM_SEQUENCE` (the
  client is expected to reserialise before send).
- Server downlink is emitted in strict monotone order per `response_id`; the
  client is allowed to reorder a small window (implementation-specific).
- `audio.done` carries a `final_sequence` value. **Server guarantee:**
  the emitted `final_sequence` equals the largest `N` such that every
  `0..N` delta has already been sent — the client can therefore treat
  `final_sequence` as an unconditional completion barrier without
  auditing density itself. If the upstream reports a `final_sequence`
  higher than the emitted-so-far dense prefix (because a delta was lost
  or the tail delta never arrived), the server clamps the emitted
  `final_sequence` down to the dense prefix and logs
  `done_barrier_clamped` with `reason` in {`gap_before_final_sequence`,
  `final_sequence_not_yet_emitted`}. A response that produced zero
  contiguous deltas ends with `final_sequence == -1`.

#### Barge-in

Client sends `cancel` for the current `generation`, then immediately opens a
new WSS handshake with a fresh token for `generation + 1`. Old-generation
late frames arriving on the previous connection are dropped (`stale_generation`).

#### Heartbeat / timeouts

- Server sends WS-level `ping` every `heartbeat_interval_ms` (default
  `15000`).
- No traffic for `idle_disconnect_ms` (default `60000`) → server closes with
  code `1001` and `ERR_IDLE_TIMEOUT`.
- Rate limits: max frames per second (`max_events_per_second`, default 200)
  and max bytes per frame (`max_frame_bytes`, default 64 KiB). Excess → close
  with `ERR_RATE_LIMIT`.

#### Error codes (stable)

| code | HTTP / WS close | Meaning |
|---|---|---|
| `ERR_TOKEN_INVALID` | 401 / 1008 | Token unknown, mangled, or scope mismatch. |
| `ERR_TOKEN_EXPIRED` | 401 / 1008 | Token past `expires_at`. |
| `ERR_TOKEN_CONSUMED` | 401 / 1008 | Token already used for an upgrade. |
| `ERR_SCOPE_MISMATCH` | 400 / 1008 | URL scope / event scope disagrees with token. |
| `ERR_STREAM_SEQUENCE` | — / 1008 | Client uplink sequence gap or reversal. |
| `ERR_STREAM_FRAME_SIZE` | — / 1009 | Frame exceeds `max_frame_bytes`. |
| `ERR_RATE_LIMIT` | — / 1008 | Event-per-second / bytes-per-second cap tripped. |
| `ERR_IDLE_TIMEOUT` | — / 1001 | No traffic within `idle_disconnect_ms`. |
| `ERR_GENERATION_STALE` | — / 1008 | Event tagged with a generation the server no longer accepts. |
| `ERR_UNKNOWN_FIELD` | — / 1008 | Strict schema rejection. |
| `ERR_UNSUPPORTED_BINARY` | — / 1008 | Binary WS frame received. |
| `ERR_UPSTREAM_UNAVAILABLE` | — / 1011 | Agent transport failed. |

## Auth

`session-token` calls carry the same HMAC-SHA256 signature scheme the Mac
Bridge already uses (see `MacRemoteFrontendBridge/auth.mjs`), namely
`x-device-id`, `x-request-timestamp`, `x-nonce`, `x-body-sha256`,
`x-signature`. Each device's shared secret is stored server-side hashed;
device registration happens out of band (bootstrap import from Bridge
`devices.json` for local dev, per-device provisioning API for prod).

The WSS upgrade never accepts the device HMAC directly — clients trade an
HMAC-signed request for a scope-bound ephemeral token first, then present
that token on the socket. This keeps the WSS surface stateless w.r.t.
long-lived secrets: a WSS handler compromise cannot leak provider keys or
device secrets.

The Gateway itself holds the **provider** key (upstream Agent auth) in its
own environment (env var / secrets store); the key is never sent to clients
and never logged.

## Structured logs

Every log line is a single JSON object with `ts`, `evt`, and, when
applicable, `request_id`, `session_id`, `response_id`, `generation`,
`sequence`. Reserved secret fields (`token`, `token_sha`, `signature`,
`provider_key`) are redacted by the logger.

Key events (stable names):

- `token_issued`, `token_rejected`, `token_consumed`, `token_expired`,
  `token_revoked`
- `ws_upgrade`, `ws_upgrade_rejected`, `ws_close`
- `session_ready`, `session_ended`
- `uplink_first_frame`, `uplink_committed`
- `downlink_first_frame`, `downlink_done`
- `cancel_received`, `cancel_ack_sent`, `stale_generation_dropped`
- `heartbeat_timeout`, `rate_limit_tripped`, `agent_upstream_error`

Grepping a single `request_id` yields the whole turn:
`token_issued → ws_upgrade → session_ready → uplink_first_frame → uplink_committed → downlink_first_frame → downlink_done → session_ended`.

## Configuration

`config.json` (all values overridable via `createGateway({...})` and env):

| key | default | notes |
|---|---|---|
| `port` | `8444` | TLS bind port |
| `bind` | `127.0.0.1` | Bind address |
| `tls_cert` / `tls_key` | `./certs/gateway.crt` / `.key` | PEM paths, resolved against the module directory (see below) |
| `state_dir` | `./state` | Device registrations + nonce store, resolved against the module directory |
| `allowed_peer_ips` | `[]` | Extra allowlist entries (Tailnet CIDRs) |
| `dev_allow_plain_ws` | `false` | Only for local integration |
| `max_token_ttl_ms` | `90000` | ESS-388 A1 ceiling |
| `default_token_ttl_ms` | `30000` | Applied when client omits `ttl_ms` |
| `heartbeat_interval_ms` | `15000` | WS-level ping cadence |
| `idle_disconnect_ms` | `60000` | Kill idle sockets |
| `max_frame_bytes` | `65536` | Per-frame hard cap |
| `max_events_per_second` | `200` | Per-connection rate limit |
| `max_uplink_bytes_per_second` | `524288` | 512 KiB/s uplink cap |
| `agent_transport` | `agent` | `agent` connects the production qwen-audio-agent loopback WSS; `mock` is test-only. |
| `agent_gateway_url` | `ws://127.0.0.1:3101/api/realtime` | Existing qwen-audio-agent endpoint. Keep loopback-only. |
| `agent_connect_timeout_ms` | `10000` | Fail the northbound turn with a structured upstream timeout. |
| `agent_max_pending_bytes` | `2097152` | Hard cap while waiting for upstream `voice.ready`. |
| `agent_takeover_voice` | `true` | Explicit Watch speech takes ownership from a stale/local frontend. |
| `provider_key_env` | `AUDIO_REALTIME_PROVIDER_KEY` | Legacy readiness metadata only; the qwen service owns the provider credential. |

Relative paths in `tls_cert` / `tls_key` / `state_dir` are all resolved
against the **module directory** (`AudioRealtimeGateway/`, i.e. the directory
containing `server.mjs`), never against `process.cwd()`. Launching the server
from any working directory — e.g. `node /abs/path/AudioRealtimeGateway/server.mjs`
under launchd / systemd / a deploy script — behaves identically to `npm start`
(ESS-428). Absolute paths in `config.json` are honored as-is.

## Deployment (quickstart)

Target host for ESS-447 dev cluster:
**`jackson-macmac-mini.magic.workspace.beer:8444`** — Jackson's Mac mini,
Tailnet-only (accessible from any device on the same Multica magic
workspace). `config.json` binds `0.0.0.0` and pins `public_host`; the
source allowlist accepts loopback (for the smoke) plus Tailnet CGNAT
(`100.64.0.0/10`) so real devices on the same magic workspace can connect.

1. Provision a TLS cert + key on the Tailnet address the Gateway will bind.
   The cert's SAN **must** include `DNS:jackson-macmac-mini.magic.workspace.beer`
   or iOS `URLSession` will refuse the connection (self-signed with matching
   SAN works only if the client trusts the CA; Multica magic-workspace
   auto-provisioned certs are trusted out-of-the-box).
2. Populate `state/devices.json` from Mac Bridge (or via a provisioning
   API); the two share the HMAC device format.
3. Confirm qwen-audio-agent is healthy on `127.0.0.1:3101` with voice
   configured. Its launchd service owns the provider key; do **not** copy that
   key into this Gateway or `config.json`.
4. `npm start`. The service logs `gateway_ready` when TLS + WSS + issuer
   are up; the log carries `bind`, `port`, and `public_host` so operators
   can grep the deployment address without reading config.
5. Confirm from the target host:
   `curl -k https://127.0.0.1:8444/v1/health` returns `{"ok": true, "service": "audio-realtime-gateway", "protocol_version": 1}`.
6. Confirm from a real device (e.g. iPhone on the same Tailnet):
   `curl https://jackson-macmac-mini.magic.workspace.beer:8444/v1/health`
   returns the same body without `-k` — that proves both DNS routing and
   the TLS trust chain.
7. Enable the client-side `audio_realtime_agent_direct_enabled` flag on
   iPhone; set `audio_realtime_agent_gateway_url` to
   `wss://jackson-macmac-mini.magic.workspace.beer:8444/api/realtime`
   (matches `AudioRealtimeAgentFeatureFlag.devDefaultGatewayURLString`).
   Keep the Mac Bridge `realtime_media_v1` flag as a fallback (per ESS-388).

For a persistent deployment on the Mac mini, wrap step 4 in a launchd
service (`~/Library/LaunchAgents/dev.wristagent.gateway.plist`) with
`WorkingDirectory` set to the module directory, `KeepAlive: true`, and
stdout / stderr redirected to a rotating log — the structured stdout
records are the operator's diagnostic surface.

## Fallback and rollback

The Bridge still exposes `WSS /v1/voice/realtime` (feature-flagged via
`realtime_media_v1`) and remains the fallback per ESS-388 (see ESS-395 for
the kill switch). Turning the direct link off is a client-side flag flip;
this Gateway can be stopped without impacting Bridge traffic. Nothing in the
Gateway writes to the Bridge state.

## Tests

`npm test` runs the Node `--test` suites under `test/`:

- `token-issuer.test.mjs` — success, expiry, replay/reuse, scope mismatch,
  revocation, unknown device.
- `realtime-session.test.mjs` — happy path handshake, delta sequences,
  duplicates dropped, gaps rejected, `audio.done` barrier with
  `final_sequence`.
- `cancel-generation.test.mjs` — server-authoritative cancel stops delta
  emission, `stale_generation` frames dropped, new generation is clean.
- `heartbeat-rate-limit.test.mjs` — idle disconnect, ping/pong, per-second
  cap, frame-size cap.
- `structured-logs.test.mjs` — every stage of a turn produces the expected
  log entries with `request_id` / `session_id` and no secret material.

Integration with real device auth and real Agent upstream is deliberately
out of scope of ESS-403 (integration lives in ESS-401 and downstream
stages).
