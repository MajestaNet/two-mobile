this tree talks only to https://<enrolled-host>:8443
principal is client:watch
never POST /v1/tasks, never profile: self-build
never send X-Two-Edge-Token, X-Two-Client-Id, or TWO_API_TOKEN
pin ca.crt; answer client-cert challenges from the enrolled identity
transcript is text only; on-device SFSpeechRecognizer; no audio upload
protocol source of truth is two at a named commit; local copies live in docs/upstream/

## What this tree is

This repository is [two-mobile](https://github.com/MajestaNet/two-mobile), the iOS companion for [Majesta Two](https://github.com/MajestaNet/two). It is the iPhone app and the Apple Watch app, under the Apache License 2.0 (see `LICENSE` and `NOTICE`), the same license as `two`. The phone enrolls the watch. Push to talk, health, and approval. Profiles are `chat` and `home-action` only. This is not the B14 development-loop GUI, and that GUI does not belong in the watch target.

## Live loop on this Mac

The control plane is the sibling [Majesta Two](https://github.com/MajestaNet/two) checkout. How to start it, including enrollment, is `docs/local.md` in that repo. Do not modify `two` from a task whose job is this client. Do not add this repo to `config/repositories/two.yaml`.

Xcode and the simulators run here. `two api` stays on `127.0.0.1:8741`. The operator window's **Start enrollment** (or `two edge enroll`) listens on the private address. Caddy then serves `8443` on the home Wi-Fi address and the Tailscale address. The phone uses the address saved at enrollment. It does not use loopback, and it does not call the API port.

`swift test` is the offline gate. Fixture `URLProtocol` tests do not need Caddy. Open `Two.xcworkspace` and run the TwoPhone or TwoWatch scheme when a simulator is required.

This Mac still needs the Xcode license accepted (`sudo xcodebuild -license`) before `swift test` or an Xcode build will run.

## Pinned contract

`docs/upstream/PIN` names the `two` commit these copies came from. Today that is `0f58d70cf4944093ca890122264274a2dd867cae` (2026-11-08). `watch-client.md` was refreshed so it names this repository. ADR 0020, `client-api-design.md` §6, and `client-threat-model.md` are unchanged and still match that commit.

When the API changes, change `two` first, then refresh those copies and the PIN. Do not edit the copies to invent a contract. Where `watch-client.md` and ADR 0020 disagree, the ADR wins.

## Enrollment

`ca.crt`, `watch.p12`, the PKCS#12 password, `edge.env`, and LAN addresses stay out of git. The iPhone generates its own key and types a username. `two edge enroll --listen PRIVATE-LAN-IP` signs that CSR on port 8444, then exits. Caddy on 8443 still requires the client certificate. The watch PKCS#12 path remains for the watch target. Copy `ca.crt` and `watch.p12` by AirDrop or a cable from `$TWO_DATA_DIR/edge/` only when importing that file. The shared keychain stores the identity. The password and any p12 copy are not kept.

Bundle ids are placeholders in `Config/Signing.xcconfig`: `local.two.phone` and `local.two.phone.watch`. The watch id has to start with the phone id so the simulator will install the companion. The keychain access group is `$(AppIdentifierPrefix)local.two.shared` on both targets. Replace the ids when the Developer Program is on this Mac. Do not commit a team id.

The shared keychain group is how the watch is expected to see the identity. If a paired watch cannot see that group, the follow-up is one Watch Connectivity transfer of the PKCS#12, imported on the watch, then deleted. That transfer is not in this scaffold.

## Client rules

- `URLSession` and Security.framework only. No third-party networking or crypto.
- SwiftUI, Swift concurrency, iOS 17, watchOS 10.
- No `NSAllowsArbitraryLoads`.
- Server trust allows only the enrolled CA. A public CA is not enough.
- Client-certificate challenges use the enrolled identity, persistence `.forSession`.
- The bearer slot stays empty until ADR 0016 is accepted. Do not invent a token.
- The voice screen cannot construct `self-build` or `operator`.
- Do not call pause, resume, cancel, config, artifact content, or `tasks:message`.
- The digest on an approval is the digest in the body. It is not an editable field.
- A notification tap is not a decision. There is no notification action that approves.
- Airplane mode shows unreachable and does not queue a decide for later.
- Silence is not approval. The watch must be unlocked and in the foreground.
- Speech uses `requiresOnDeviceRecognition`. If the locale cannot do that, show it as unavailable and do not record. Do not upload audio.
- Do not speak `reply` in this build. Do not log the transcript after the operator leaves the talk screen.
- A diff projection keeps summary counts only. `source_included: false` does not render a patch.

## Layout

`Package.swift` is the shared client. `Apps/TwoPhone` enrolls. `Apps/TwoWatch` talks. `Two.xcworkspace` opens both.

Cursor should open a multi-root workspace next to these checkouts, not inside either git repo:

```json
{
  "folders": [
    { "path": "two", "name": "two" },
    { "path": "two-mobile", "name": "two-mobile" }
  ]
}
```

Save that as `../two-dev.code-workspace`. Agents read `two` and write this repo.
