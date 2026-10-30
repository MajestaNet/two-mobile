// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TwoClient

private enum ProfileChoice: Hashable {
    case route
    case chat
    case house

    var profile: VoiceProfile? {
        switch self {
        case .route: return nil
        case .chat: return .chat
        case .house: return .homeAction
        }
    }
}

struct TalkView: View {
    @ObservedObject var session: WatchSession
    @StateObject private var speech = PushToTalk()
    @State private var choice: ProfileChoice = .route
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let reason = speech.unavailableReason {
                    Text(reason)
                } else {
                    Picker("Profile", selection: $choice) {
                        Text("Route").tag(ProfileChoice.route)
                        if session.showsChat { Text("Chat").tag(ProfileChoice.chat) }
                        if session.showsHomeAction { Text("House").tag(ProfileChoice.house) }
                    }
                    Button(speech.holding ? "Release" : "Hold to talk") {}
                        .disabled(!canHold)
                        .onLongPressGesture(minimumDuration: 86_400, maximumDistance: 80, pressing: { pressing in
                            Task { @MainActor in
                                if pressing {
                                    speech.press()
                                } else {
                                    let text = await speech.release()
                                    guard scenePhase == .active else { return }
                                    await session.sendTranscript(text, profile: choice.profile, foreground: true)
                                }
                            }
                        }, perform: {})
                }
                if !session.confirmationTranscript.isEmpty {
                    Text(session.confirmationTranscript)
                } else if !speech.liveTranscript.isEmpty {
                    Text(speech.liveTranscript)
                }
                if let reply = session.replyText {
                    Text(reply)
                }
                if !session.notice.isEmpty {
                    Text(session.notice)
                }
                if let correlationID = session.correlationID {
                    Text(correlationID).font(.footnote)
                }
            }
            .padding()
        }
        .navigationTitle("Talk")
        .onDisappear {
            speech.cancelWithoutSending()
            session.leaveTalkScreen()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                speech.cancelWithoutSending()
            }
        }
        .task { await session.checkCapabilities() }
    }

    private var canHold: Bool {
        session.principalMatches && !session.voiceInFlight && speech.unavailableReason == nil
    }
}

struct HouseView: View {
    @ObservedObject var session: WatchSession

    var body: some View {
        let picture = session.housePicture()
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
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
                Button("Refresh") { Task { await session.refreshHouse() } }
            }
            .padding()
        }
        .navigationTitle("House")
        .task { await session.refreshHouse() }
    }
}

struct ApprovalView: View {
    @ObservedObject var session: WatchSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let picture = session.approvalPicture()
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                pictureBody(picture)
                if !session.notice.isEmpty {
                    Text(session.notice)
                }
                if let correlationID = session.correlationID {
                    Text(correlationID).font(.footnote)
                }
                Button("Refresh") { Task { await session.refreshApprovals() } }
            }
            .padding()
        }
        .navigationTitle("Approval")
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
            Text(approval.actionDigest).font(.system(.caption, design: .monospaced))
            if !approval.paths.isEmpty {
                Text(approval.paths.joined(separator: "\n")).font(.caption)
            }
            decideButtons { decision in
                Task { await session.decide(approval, decision: decision, foreground: scenePhase == .active) }
            }
        case .voice(let approval):
            Text(approval.summary)
            Text(approval.actionDigest).font(.system(.caption, design: .monospaced))
            decideButtons { decision in
                Task { await session.decideVoice(approval, decision: decision, foreground: scenePhase == .active) }
            }
        }
    }

    @ViewBuilder
    private func decideButtons(_ send: @escaping (ApprovalDecision) -> Void) -> some View {
        Button("Approve") { send(.approve) }.disabled(buttonsDisabled)
        Button("Reject") { send(.reject) }.disabled(buttonsDisabled)
    }

    private var buttonsDisabled: Bool {
        session.deciding || !session.canDecide || session.unreachable || scenePhase != .active
    }
}
