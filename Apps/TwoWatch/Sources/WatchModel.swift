// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation
import TwoClient

@MainActor
final class WatchModel: ObservableObject {
    @Published var session: WatchSession?
    @Published var status = ""

    init() {
        bootstrap()
    }

    func bootstrap() {
        guard let accessGroup = AccessGroup.resolved() else {
            status = "Select a Development Team so the keychain access group can be signed."
            return
        }
        do {
            guard let enrollment = try WatchKeychain.loadEnrollment(accessGroup: accessGroup) else {
                status = "Enroll on the iPhone."
                return
            }
            session = WatchSession(
                api: WatchAPI.makeLive(
                    endpoint: enrollment.endpoint,
                    pinnedCertificate: enrollment.pinnedCertificate,
                    accessGroup: accessGroup
                )
            )
        } catch let error as KeychainError {
            status = error.screenText
        } catch {
            status = "The keychain could not be read."
        }
    }
}
