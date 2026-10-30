# Pinned excerpt

Source file: docs/client-api-design.md
Commit: b1b5df6a2374f782db96419232355ca888320cc4
Section: 6. Authentication and authorization, through Watch edge.
The rest of that design, including the development-loop GUI, is not this client.

## 6. Authentication and authorization

### Deployment boundary

- Unix socket or loopback remains the normal CLI path.
- A mobile client reaches HTTPS only over a private Tailscale/WireGuard
  overlay. Public internet binds, public tunnels, and direct Ollama access
  remain forbidden.
- The current shared `TWO_API_TOKEN` is a transitional single-operator
  mechanism for trusted CLI/overlay use. It must not be copied into or
  embedded in the mobile app.

Today that bearer is coarse authentication, not multi-user authorization.
B14 slice 1 derives the network principal as `token:operator` and attaches
the full operator scope set. Request `principal`/`actor` fields cannot
establish authority for authenticated network clients. They remain audit
labels for trusted Unix/loopback callers. `/v1/tasks/{id}/events` requires
`events:audit` (granted to local-trust and the shared operator token).
Network event payloads are policy-filtered (slice 2). Unix/loopback CLI
keeps current event payloads. Do not embed the token in a mobile app or
grant it to mutually untrusted users.

### Mobile identity

The first-party native app is an OAuth 2.1 public client using Authorization
Code with PKCE against an operator-configured OIDC issuer. It has no client
secret. Access tokens are short-lived; refresh tokens rotate and are stored
only in iOS Keychain or Android Keystore with device-unlock protection.
Logout or server-side device revocation invalidates the session.

If an installation has no configured trusted issuer, mobile sign-in is
unavailable; the server fails closed and CLI/Unix access remains available.
The implementation must validate issuer, audience, expiry, signature,
authorized-party/client id, and PKCE flow. It must not invent a custom
password or cryptographic protocol inside the app.

### Roles and scopes

Suggested scopes:

| Scope | Allows |
| --- | --- |
| `tasks:read` | Task lists, projections, conversation summaries, graph, reports. |
| `tasks:message` | Post task messages and answer ordinary questions. |
| `tasks:control` | Submit, pause, resume, and cancel tasks. |
| `approvals:decide` | Approve/reject exact action digests; may require recent sign-in. |
| `source:read` | Request bounded diffs, paths, and source-bearing artifacts. |
| `events:audit` | Read policy-filtered controller events; never raw Harness trajectories. |
| `config:read` | Read redacted repository/project configuration. |
| `config:write` | Draft and activate permitted config candidates. |
| `system:read` | Aggregate health and queue summaries. |
| `admin` | Sensitive config and device/session administration; never implicit. |

Target behavior: the server computes the effective principal and scopes.
Existing request `actor`/`principal` fields are ignored for authenticated
network clients. Trusted in-process/Unix callers may still send those labels
for CLI audit compatibility; scopes stay server-derived.

Approval screens show action class, target, paths, digest, requesting stage,
and consequences. Approval requires a fresh projection and cannot be queued
offline. High-risk policy may require recent authentication or local
operator confirmation. Silence and notification taps are never approval.

### Watch edge

ADR 0020 adds a device gate in front of this API. Caddy on a private
address terminates mutual TLS and proxies to loopback. The watch
principal is `client:watch`. It cannot submit `self-build`. The native
app contract is [watch-client.md](watch-client.md). The app does not
embed `TWO_API_TOKEN`. OIDC stays deferred until ADR 0016 is accepted.
