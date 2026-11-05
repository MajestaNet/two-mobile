# two-mobile

iOS companion for [Majesta Two](https://github.com/MajestaNet/two).

This repository is the iPhone app and the Apple Watch app. The phone enrolls the device. The watch is the push-to-talk client. Both talk to a Majesta Two install on the operator's own network. They do not run the control plane, the model, or the operator console. Those stay in `MajestaNet/two`.

Profiles are `chat` and `home-action` only. This app does not submit a self-build task.

Licensed under the [Apache License 2.0](LICENSE), the same license as Majesta Two. Copyright 2026 MajestaNet. See [NOTICE](NOTICE).

## What is in this tree

- `Apps/TwoPhone` — iOS 17 enrollment, health, and approval
- `Apps/TwoWatch` — watchOS 10 push to talk, health, and approval
- `Sources/TwoClient` — shared client (`URLSession` and Security.framework only)
- `docs/upstream/` — copies of the `two` contract this client was built against

`swift test` is the offline check. Open `Two.xcworkspace` and run the TwoPhone or TwoWatch scheme when a simulator is required.
