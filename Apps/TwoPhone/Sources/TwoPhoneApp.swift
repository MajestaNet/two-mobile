// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TwoClient

@main
struct TwoPhoneApp: App {
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            PhoneRootView(model: model)
        }
    }
}
