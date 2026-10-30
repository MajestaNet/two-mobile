// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TwoClient

@main
struct TwoWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            if let session = model.session {
                TabView {
                    TalkView(session: session)
                    HouseView(session: session)
                    ApprovalView(session: session)
                }
            } else {
                Text(model.status.isEmpty ? "Enroll on the iPhone." : model.status)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }
}
