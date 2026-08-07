# Crewspace cross-platform chat

The Crewspace person chat uses PostgreSQL and REST as its canonical data source.
Foreground clients receive best-effort realtime events over WebSocket. Firebase
Cloud Messaging uses Firebase Installation IDs (FIDs) for background delivery.
Every protected request is authorized with a Firebase ID token; request body IDs
never authorize an identity.

The standalone Nauti assistant chat is not part of this service.

## Runtime configuration

The server requires Go 1.25 or newer for Firebase Admin Go `v4.21.0`.
Apply `schema.sql` before deploying the new binary. The migration is additive and
can be applied before the compatible clients are released.

Set these environment variables in the runtime or secret manager:

- `DATABASE_URL`: PostgreSQL connection string.
- `FIREBASE_PROJECT_ID`: the Firebase project shared by Android and iOS.
- `GOOGLE_APPLICATION_CREDENTIALS`: path to a service-account JSON file outside
  the repository. On Google Cloud, prefer the workload's Application Default
  Credentials and omit this variable.
- `PUBLIC_BASE_URL`: externally reachable HTTPS origin, for example
  `https://api.example.invalid`.
- `UPLOAD_PUBLIC_ORIGIN`: exact origin returned in Crewspace media URLs, for
  example `https://uploads.example.invalid`. Message media is rejected when no
  upload origin can be determined. If this variable is omitted, the configured
  `S3_PUBLIC_BASE_URL` or `LOCAL_UPLOAD_PUBLIC_BASE_URL` origin is used.
- Existing storage settings remain supported: `S3_ENDPOINT`, `S3_REGION`,
  `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`,
  `S3_PUBLIC_BASE_URL`, `LOCAL_UPLOAD_DIR`, and
  `LOCAL_UPLOAD_PUBLIC_BASE_URL`.
- Local uploads additionally require `LOCAL_UPLOAD_SIGNING_SECRET` with at
  least 32 bytes. Each local PUT URL expires after 15 minutes and its HMAC binds
  the path and required `Content-Type`; a successfully published object cannot
  be overwritten by replaying the URL. Local upload directories, temporary
  files, dotfiles, and symlinks are never served.
- Set `APP_ENV=production` (or `ENVIRONMENT=production`) in production.
  Production startup fails without Firebase Admin or with a non-HTTPS/missing
  public API or upload origin. `/healthz` is fail-closed in every environment:
  it returns `503` if Firebase identity/push or either public URL is unavailable.
- Plain HTTP is accepted only outside production and only with the explicit
  local-development opt-in `ALLOW_INSECURE_LOCAL_HTTP=true`. The default remains
  HTTPS-only; the backend may still listen on HTTP behind a TLS reverse proxy.
- `ADDR`: listen address; defaults to `:8080`.

Do not commit service-account files, APNs keys, database credentials, or storage
credentials. Upload and API origins should use HTTPS in production.

## Authentication and endpoints

Send `Authorization: Bearer <Firebase ID token>` on every mutation and every
Crewspace request. The token subject (`uid`) is the sole caller identity.

- `PUT /crewspace/me`, body `{"name":"Alice"}`.
- `POST /crewspace/direct`, body `{"skipper_id":"target-firebase-uid"}`.
- `GET /crewspace/conversations`.
- `GET /crewspace/conversations/{id}/messages` keeps the legacy JSON array.
- `GET /crewspace/conversations/{id}/messages/page?before=...&limit=100`.
- `GET /crewspace/conversations/{id}/messages/page?after=...&limit=100`.
- `POST /crewspace/conversations/{id}/messages`, body:

  ```json
  {
    "client_message_id": "device-generated-uuid",
    "text": "Moin",
    "media_url": null,
    "media_type": null,
    "media_duration_seconds": null
  }
  ```

  A retry with the same conversation, authenticated sender, and
  `client_message_id` returns the same server message. For compatibility, old
  clients that omit the field receive a generated legacy ID, but cannot gain
  retry idempotency.

- `PUT /crewspace/devices`, body
  `{"installation_id":"firebase-installation-id","platform":"android"}` (or
  `"ios"`).
- `DELETE /crewspace/devices`, body
  `{"installation_id":"firebase-installation-id","platform":"android"}`.
  `platform` is optional for deletion. The legacy
  `DELETE /crewspace/devices/{url-escaped-installation-id}` route remains
  compatible.
- `GET /crewspace/blocks` returns `{"blocked_uids":["uid"]}`.
- `PUT /crewspace/blocks/{url-escaped-uid}` and
  `DELETE /crewspace/blocks/{url-escaped-uid}` return `204`.
- `GET /crewspace/realtime` upgrades to WebSocket.

The cursor page response is:

```json
{
  "messages": [],
  "next_before_cursor": null,
  "next_after_cursor": null,
  "has_more": false
}
```

Cursors are opaque. `before` and `after` are mutually exclusive; the default
limit is 100 and the maximum is 200.

Conversation objects include `chat_available`. For direct chats it becomes
`false` if either participant blocks the other. Direct creation and message
sending then return `403 {"error":"chat_unavailable"}`. History remains
readable. Groups are unaffected.

## WebSocket protocol v1

Authenticate the HTTP upgrade request with the same Bearer header. The server
sends JSON envelopes and clients do not send chat messages over the socket:

```json
{
  "version": 1,
  "type": "message.created",
  "event_id": "server-event-uuid",
  "occurred_at": "2026-07-25T12:00:00Z",
  "message": {}
}
```

Event types are `ready`, `message.created`, and `conversation.updated`.
`message` or `conversation` is present only for its matching event. Deduplicate
messages first by server `id`, then by `client_message_id`. After every reconnect,
request `messages/page?after=<last-cursor>`; WebSocket delivery is best effort.

The in-memory hub supports up to five sockets per Firebase UID. Slow consumers
are disconnected when their bounded event queue fills, which causes the client
to reconnect and recover through the cursor API.

## Push behavior

The message transaction commits both the canonical message and one durable
outbox record per recipient. The worker retries transient Firebase errors with
bounded exponential backoff, batches all registered devices in groups of at
most 500, and deletes invalid FIDs. FCM data contains only
`conversation_id`, `message_id`, and `message_type`. The visible notification is
the sender name plus `Neue Nachricht`; message text and media content are never
included. Android receives a high-priority data-only message, verifies the
currently bound account, and creates the local notification on its
`crewspace_messages` channel. APNs receives a visible alert containing the
sender name and generic body directly.

The Android and iOS clients must send the Firebase Installation ID, not an FCM
registration token, as `installation_id`. APNs credentials are configured in
the Firebase console and are not stored by this service.

## TLS reverse proxy

Terminate TLS in a reverse proxy and forward both HTTPS and WebSocket traffic.
For nginx, the essential location is:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 180s;
    proxy_send_timeout 180s;
}
```

Define nginx's `$connection_upgrade` with a `map` in the `http` block. Redirect
plain HTTP to HTTPS and expose only the proxy publicly. Clients derive `wss://`
from the same production API host.

## Verification

Run:

```sh
env GOCACHE=/tmp/toern-social-feed-go-cache go test -race ./...
```

Live Firebase, APNs/FCM, PostgreSQL migration, and cross-device acceptance still
require production-equivalent credentials and infrastructure.
