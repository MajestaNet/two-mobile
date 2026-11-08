# two-mobile

iOS companion for [Majesta Two](https://github.com/MajestaNet/two).

This repository is the iPhone app and the Apple Watch app. The phone enrolls the device. The watch is push-to-talk. Both talk to a Majesta Two install on the operator's own network. They do not run the control plane, the model, or the operator console. Those stay in [MajestaNet/two](https://github.com/MajestaNet/two).

Profiles are `chat` and `home-action` only. This app does not submit a self-build task and does not open the operator profile.

The short path for the Mac and this app together is [docs/local.md in Majesta Two](https://github.com/MajestaNet/two/blob/main/docs/local.md).

Licensed under the [Apache License 2.0](LICENSE), the same license as Majesta Two. Copyright 2026 MajestaNet. See [NOTICE](NOTICE).

## Run it against a local Majesta Two

Start [Majesta Two](https://github.com/MajestaNet/two) on the Mac first. Open its operator window, start the server, and install Caddy (`brew install caddy`). That side of the steps is [docs/local.md](https://github.com/MajestaNet/two/blob/main/docs/local.md). This app cannot use `127.0.0.1`.

Then, in this repository:

```bash
swift test
open Two.xcworkspace
```

`swift test` is the offline check. It does not need Caddy or a running API. The Mac needs the Xcode license accepted (`sudo xcodebuild -license`) before `swift test` or an Xcode build will run.

In Xcode:

1. Select a Development Team so the shared keychain group can be signed. Do not commit a team id.
2. Run the **TwoPhone** scheme on a simulator or a phone. Run **TwoWatch** when you want the watch.
3. On the Mac, on the Server page, choose **Start enrollment**.
4. On the phone, on the same Wi-Fi, enter a username (letters, digits, hyphen) and tap **Enroll**. If a host field appears, use the address the window printed.
5. Hold the globe to speak. Recognition stays on the device. The Mac receives text.
6. On the Mac, **Stop enrollment** once the phone is on the globe. The API and Caddy stay up.

The phone stores the home Wi-Fi address and the Mac's Tailscale address. Away from that Wi-Fi it uses Tailscale. At home it uses the Wi-Fi address. Caddy on port 8443 requires the client certificate. The phone does not call port 8741.

Bundle ids in `Config/Signing.xcconfig` are placeholders: `local.two.phone` and `local.two.phone.watch`. The watch id has to start with the phone id so the simulator will install the companion.

## What is in this tree

- `Apps/TwoPhone` — iOS 17 enrollment, health, and the house
- `Apps/TwoWatch` — watchOS 10 push to talk, health, and approval
- `Sources/TwoClient` — shared client (`URLSession` and Security.framework only)
- `docs/upstream/` — copies of the `two` contract this client was built against

Open both checkouts with a `two-dev.code-workspace` file saved beside them, not inside either git repository. Agent instructions are in [AGENTS.md](AGENTS.md).
