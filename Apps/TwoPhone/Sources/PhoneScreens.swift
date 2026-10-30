// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TwoClient
import UniformTypeIdentifiers

struct PhoneRootView: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        TabView {
            EnrollView(model: model)
                .tabItem { Label("Enroll", systemImage: "person.badge.key") }
            HouseView(session: model.session)
                .tabItem { Label("House", systemImage: "house") }
            ApprovalView(session: model.session)
                .tabItem { Label("Approval", systemImage: "checkmark.seal") }
        }
    }
}

struct EnrollView: View {
    @ObservedObject var model: PhoneModel
    @State private var chooseCertificate = false
    @State private var chooseEnrollment = false

    var body: some View {
        NavigationStack {
            Form {
                Button(model.certificateChosen ? "CA selected" : "Choose CA") {
                    chooseCertificate = true
                }
                Button(model.enrollmentChosen ? "Enrollment file selected" : "Choose enrollment file") {
                    chooseEnrollment = true
                }
                SecureField("PKCS#12 password", text: $model.password)
                TextField("Private LAN host", text: $model.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $model.port)
                    .keyboardType(.numberPad)
                Button("Enroll") { Task { await model.enroll() } }
                    .disabled(!canEnroll)
                Button("Check principal") { Task { await model.check() } }
                    .disabled(model.session == nil)
                if !model.status.isEmpty {
                    Text(model.status)
                }
                if let principal = model.session?.capabilities?.principal {
                    Text(principal)
                }
            }
            .navigationTitle("Enroll")
            .fileImporter(isPresented: $chooseCertificate, allowedContentTypes: certificateTypes) { result in
                accept(result, store: model.storeCertificate)
            }
            .fileImporter(isPresented: $chooseEnrollment, allowedContentTypes: enrollmentTypes) { result in
                accept(result, store: model.storeEnrollmentFile)
            }
        }
    }

    private var canEnroll: Bool {
        model.groupReady && model.certificateChosen && model.enrollmentChosen
            && !model.host.isEmpty && !model.password.isEmpty
    }

    private var certificateTypes: [UTType] {
        if let type = UTType(filenameExtension: "crt") { return [type] }
        return [.data]
    }

    private var enrollmentTypes: [UTType] {
        if let type = UTType(filenameExtension: "p12") { return [type] }
        return [.data]
    }

    private func accept(_ result: Result<URL, Error>, store: (Data) -> Void) {
        switch result {
        case .success(let url):
            do {
                store(try readSecurityScoped(url))
            } catch {
                model.status = "The file could not be read."
            }
        case .failure:
            model.status = "The file could not be read."
        }
    }
}

struct HouseView: View {
    let session: WatchSession?

    var body: some View {
        NavigationStack {
            if let session {
                HouseContent(session: session)
            } else {
                Text("Enroll on this iPhone before reading health.")
                    .padding()
            }
        }
    }
}

private struct HouseContent: View {
    @ObservedObject var session: WatchSession

    var body: some View {
        let picture = session.housePicture()
        List {
            Text(picture.healthLine)
            if !picture.queueLine.isEmpty {
                Text(picture.queueLine)
            }
            if !picture.notice.isEmpty {
                Text(picture.notice)
            }
            if let correlationID = picture.correlationID {
                Text(correlationID).font(.footnote)
            }
        }
        .navigationTitle("House")
        .toolbar {
            Button("Refresh") { Task { await session.refreshHouse() } }
        }
        .task { await session.refreshHouse() }
    }
}

struct ApprovalView: View {
    let session: WatchSession?

    var body: some View {
        NavigationStack {
            if let session {
                ApprovalContent(session: session)
            } else {
                Text("Enroll on this iPhone before deciding.")
                    .padding()
            }
        }
    }
}

private struct ApprovalContent: View {
    @ObservedObject var session: WatchSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let picture = session.approvalPicture()
        List {
            pictureBody(picture)
            if !session.notice.isEmpty {
                Text(session.notice)
            }
            if let correlationID = session.correlationID {
                Text(correlationID).font(.footnote)
            }
        }
        .navigationTitle("Approval")
        .toolbar {
            Button("Refresh") { Task { await session.refreshApprovals() } }
        }
        .task { await session.refreshApprovals() }
    }

    @ViewBuilder
    private func pictureBody(_ picture: ApprovalPicture) -> some View {
        switch picture.body {
        case .needsRefresh:
            Text("No approval yet.")
        case .missingScope:
            Text("approvals:decide is not granted.")
        case .empty:
            Text("No open approval.")
        case .unreachable:
            Text("The mini is unreachable.")
        case .task(let approval):
            Text(approval.actionClass)
            Text(approval.actionDigest).font(.system(.body, design: .monospaced))
            if !approval.paths.isEmpty {
                Text(approval.paths.joined(separator: "\n"))
            }
            decideButtons { decision in
                Task {
                    await session.decide(approval, decision: decision, foreground: scenePhase == .active)
                }
            }
        case .voice(let approval):
            Text(approval.summary)
            Text(approval.actionDigest).font(.system(.body, design: .monospaced))
            decideButtons { decision in
                Task {
                    await session.decideVoice(approval, decision: decision, foreground: scenePhase == .active)
                }
            }
        }
    }

    @ViewBuilder
    private func decideButtons(_ send: @escaping (ApprovalDecision) -> Void) -> some View {
        Button("Approve") { send(.approve) }
            .disabled(buttonsDisabled)
        Button("Reject") { send(.reject) }
            .disabled(buttonsDisabled)
    }

    private var buttonsDisabled: Bool {
        session.deciding || !session.canDecide || session.unreachable || scenePhase != .active
    }
}

private func readSecurityScoped(_ url: URL) throws -> Data {
    let started = url.startAccessingSecurityScopedResource()
    defer { if started { url.stopAccessingSecurityScopedResource() } }
    return try Data(contentsOf: url)
}
