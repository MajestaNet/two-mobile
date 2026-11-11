// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TwoClient

private let navy = Color(red: 27 / 255, green: 46 / 255, blue: 70 / 255)
private let gold = Color(red: 246 / 255, green: 207 / 255, blue: 85 / 255)
private let phoneMetal = LinearGradient(
    colors: [
        Color(red: 1, green: 0.97, blue: 0.84),
        gold,
        Color(red: 212 / 255, green: 158 / 255, blue: 46 / 255),
    ],
    startPoint: .top,
    endPoint: .bottom
)

private enum PhonePage: Hashable {
    case talk
    case devices
}

struct PhoneRootView: View {
    @ObservedObject var model: PhoneModel
    @State private var page: PhonePage? = .talk

    var body: some View {
        Group {
            if model.showsGlobe {
                house
            } else {
                AuthView(model: model)
            }
        }
        .background { SpaceBackground() }
        .onReceive(NotificationCenter.default.publisher(for: .twoSiriApproval)) { note in
            guard let turnID = note.object as? String, !turnID.isEmpty else { return }
            Task { await model.presentVoiceTurn(turnID) }
        }
    }

    private var house: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                GlobeView(model: model, onDevices: { show(.devices) })
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(PhonePage.talk)
                DevicesPage(model: model, onTalk: { show(.talk) })
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(PhonePage.devices)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .overlay(alignment: .trailing) { pageMarks }
        .overlay(alignment: .bottom) { voiceDecision }
        .onChange(of: page) { _, next in
            if next == .devices {
                Task { await model.refreshAppliances() }
            } else {
                model.stopApplianceChecks()
            }
        }
    }

    @ViewBuilder
    private var voiceDecision: some View {
        if let approval = model.session?.voiceApproval {
            VoiceDecisionCard(
                approval: approval,
                enabled: model.session?.canDecide == true && model.session?.deciding != true,
                onReject: { model.decideVoice(.reject) },
                onApprove: { model.decideVoice(.approve) }
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var pageMarks: some View {
        VStack(spacing: 8) {
            pageMark(page != .devices)
            pageMark(page == .devices)
        }
        .padding(.trailing, 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pageMark(_ on: Bool) -> some View {
        Circle()
            .fill(on ? gold : Color.white.opacity(0.35))
            .frame(width: 7, height: 7)
    }

    private func show(_ next: PhonePage) {
        withAnimation(.easeInOut(duration: 0.35)) {
            page = next
        }
    }
}

struct AuthView: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Majesta Two")
                .font(.title)
                .foregroundStyle(phoneMetal)
            TextField("Username", text: $model.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .foregroundStyle(.white)
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            if model.discoveryFailed || !model.host.isEmpty {
                TextField("Private LAN host", text: $model.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Button("Enroll") {
                Task { await model.enroll() }
            }
            .disabled(!model.groupReady || model.username.isEmpty || model.authenticating)
            .foregroundStyle(navy)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(phoneMetal, in: Capsule())
            if !model.status.isEmpty {
                Text(model.status)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.discoverHost() }
    }
}

struct GlobeView: View {
    @ObservedObject var model: PhoneModel
    var onDevices: (() -> Void)? = nil
    @StateObject private var speech = PushToTalk()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack {
            Spacer()
            GoldGlobe(activity: globeActivity)
                .scaleEffect(speech.holding ? 0.96 : 1)
                .opacity(globeActivity == .unavailable ? 0.45 : 1)
                .padding(36)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel(globeActivity.accessibilityLabel)
                .accessibilityAddTraits(.isButton)
                .animation(.spring(response: 0.34, dampingFraction: 0.72), value: globeActivity)
                .onLongPressGesture(minimumDuration: 86_400, maximumDistance: 120, pressing: { pressing in
                    Task { @MainActor in
                        if pressing {
                            if canHold { speech.press() }
                        } else {
                            let text = await speech.release()
                            guard scenePhase == .active else { return }
                            await model.send(text)
                        }
                    }
                }, perform: {})
            Spacer()
            Text(bannerText)
                .font(.body)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, onDevices == nil ? 36 : 8)
                .opacity(bannerOpacity)
                .animation(.easeOut(duration: 0.8), value: bannerOpacity)
            if let onDevices {
                Button(action: onDevices) {
                    VStack(spacing: 2) {
                        Text("Devices")
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(gold)
                    .padding(.bottom, 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Devices")
                .accessibilityHint("Scroll down for appliances")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                speech.cancelWithoutSending()
            } else {
                Task { await model.refreshIfNeeded() }
            }
        }
        .onAppear {
            Task { await model.refreshIfNeeded() }
        }
        .onDisappear {
            speech.cancelWithoutSending()
            model.session?.leaveTalkScreen()
        }
    }

    private var globeActivity: GoldGlobeActivity {
        GoldGlobeActivity.talk(
            holding: speech.holding,
            sending: model.session?.voiceInFlight == true,
            available: model.session?.principalMatches == true && speech.unavailableReason == nil
        )
    }

    private var canHold: Bool {
        model.session?.principalMatches == true
            && model.session?.voiceInFlight != true
            && speech.unavailableReason == nil
    }

    private var bannerText: String {
        if let reason = speech.unavailableReason { return reason }
        if speech.holding { return speech.liveTranscript }
        if globeActivity == .unavailable, let notice = model.session?.notice, !notice.isEmpty {
            return notice
        }
        return model.banner
    }

    private var bannerOpacity: Double {
        if speech.holding { return speech.liveTranscript.isEmpty ? 0 : 1 }
        if let reason = speech.unavailableReason, !reason.isEmpty { return 1 }
        if globeActivity == .unavailable, let notice = model.session?.notice, !notice.isEmpty {
            return 1
        }
        return model.bannerVisible ? 1 : 0
    }
}

struct DevicesPage: View {
    @ObservedObject var model: PhoneModel
    var onTalk: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: onTalk) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.up")
                        Text("Talk")
                    }
                    .font(.caption)
                    .foregroundStyle(gold)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Talk")
                .accessibilityHint("Scroll up for the globe")
                Spacer()
                if model.checkingAppliances {
                    ProgressView()
                        .controlSize(.small)
                        .tint(gold)
                        .accessibilityLabel("Checking appliances")
                }
            }
            Text("Devices")
                .font(.title2)
                .foregroundStyle(phoneMetal)
            if !model.applianceNotice.isEmpty {
                Text(model.applianceNotice)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.appliances.isEmpty {
                Spacer()
                if model.applianceNotice.isEmpty {
                    Text(model.appliancesReady && !model.checkingAppliances
                        ? "No appliances are bound."
                        : "Looking for appliances.")
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.appliances) { card in
                            ApplianceRow(model: model, card: card)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .refreshable { await model.refreshAppliances() }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.trailing, 18)
    }
}

private struct ApplianceRow: View {
    @ObservedObject var model: PhoneModel
    let card: ApplianceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                LinkLamp(link: card.link)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.appliance.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !card.detail.isEmpty {
                        Text(card.detail)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Text(card.appliance.kindName)
                    .font(.caption)
                    .foregroundStyle(gold)
                    .multilineTextAlignment(.trailing)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(card.appliance.actions, id: \.self) { verb in
                    Button(verb.title) {
                        model.control(verb, card)
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(navy)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(phoneMetal, in: Capsule())
                    .opacity(model.controlsEnabled ? 1 : 0.45)
                    .disabled(!model.controlsEnabled)
                    .accessibilityLabel("\(verb.accessibilityTitle), \(card.appliance.title)")
                }
            }
            if model.busyApplianceID == card.id {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(gold)
                    Text("Sending")
                        .font(.caption)
                        .foregroundStyle(gold)
                }
                .accessibilityLabel("Sending")
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(gold.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct LinkLamp: View {
    let link: ApplianceLink

    var body: some View {
        Circle()
            .fill(link == .unknown ? Color.clear : color)
            .overlay {
                Circle().stroke(link == .unknown ? gold.opacity(0.85) : color, lineWidth: 1.5)
            }
            .frame(width: 12, height: 12)
            .shadow(color: link == .unknown ? .clear : color.opacity(0.9), radius: 5)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch link {
        case .online:
            Color(red: 0.30, green: 0.82, blue: 0.42)
        case .offline:
            Color(red: 0.90, green: 0.27, blue: 0.24)
        case .unknown:
            gold
        }
    }

    private var label: String {
        switch link {
        case .online: "Connected"
        case .offline: "Offline"
        case .unknown: "Connectivity unknown"
        }
    }
}

private struct VoiceDecisionCard: View {
    let approval: VoiceApproval
    let enabled: Bool
    let onReject: () -> Void
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("That needs a decision on the phone.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(approval.summary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
            Text(approval.actionDigest)
                .font(.caption2.monospaced())
                .foregroundStyle(gold)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button("Reject", action: onReject)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.12), in: Capsule())
                Button("Approve", action: onApprove)
                    .buttonStyle(.plain)
                    .foregroundStyle(navy)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(phoneMetal, in: Capsule())
            }
            .disabled(!enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}
