// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import Foundation
import TwoClient

@MainActor
final class PhoneModel: ObservableObject {
    @Published var session: WatchSession?
    @Published var host = ""
    @Published var port = "8443"
    @Published var password = ""
    @Published var status = ""
    @Published var certificateChosen = false
    @Published var enrollmentChosen = false

    private var certificate: Data?
    private var pkcs12: Data?
    private var accessGroup = AccessGroup.resolved()

    var groupReady: Bool { accessGroup != nil }

    init() {
        bootstrap()
    }

    func storeCertificate(_ data: Data) {
        certificate = data
        certificateChosen = true
    }

    func storeEnrollmentFile(_ data: Data) {
        pkcs12 = data
        enrollmentChosen = true
    }

    func bootstrap() {
        accessGroup = AccessGroup.resolved()
        guard let accessGroup else {
            status = "Select a Development Team so the keychain access group can be signed."
            return
        }
        do {
            guard let enrollment = try WatchKeychain.loadEnrollment(accessGroup: accessGroup) else {
                return
            }
            host = enrollment.endpoint.host
            port = String(enrollment.endpoint.port)
            session = WatchSession(api: liveAPI(enrollment.endpoint, enrollment.pinnedCertificate, accessGroup))
        } catch let error as KeychainError {
            status = error.screenText
        } catch {
            status = "The keychain could not be read."
        }
    }

    func enroll() async {
        guard let accessGroup else {
            status = "Select a Development Team so the keychain access group can be signed."
            return
        }
        guard let certificate, let pkcs12 else {
            status = "Choose the CA and the enrollment file."
            return
        }
        let secret = password
        password = ""
        let certificateCopy = certificate
        let pkcsCopy = pkcs12
        self.certificate = nil
        self.pkcs12 = nil
        certificateChosen = false
        enrollmentChosen = false
        do {
            let endpoint = try EdgeEndpoint(parsingHost: host, portField: port)
            try WatchKeychain.saveEnrollment(
                pkcs12: pkcsCopy,
                password: secret,
                certificate: certificateCopy,
                endpoint: endpoint,
                accessGroup: accessGroup
            )
            let next = WatchSession(api: liveAPI(endpoint, certificateCopy, accessGroup))
            session = next
            await next.checkCapabilities()
            status = next.notice
        } catch let error as EndpointError {
            status = error.screenText
        } catch let error as KeychainError {
            status = error.screenText
        } catch {
            status = "Enrollment failed."
        }
    }

    func check() async {
        guard let session else {
            status = "Enroll before checking the principal."
            return
        }
        await session.checkCapabilities()
        status = session.notice
    }

    private func liveAPI(_ endpoint: EdgeEndpoint, _ certificate: Data, _ accessGroup: String) -> WatchAPI {
        WatchAPI.makeLive(endpoint: endpoint, pinnedCertificate: certificate, accessGroup: accessGroup)
    }
}
