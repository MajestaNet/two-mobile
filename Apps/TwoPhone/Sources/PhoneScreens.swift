// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TwoClient

private let navy = Color(red: 27 / 255, green: 46 / 255, blue: 70 / 255)
private let gold = Color(red: 246 / 255, green: 207 / 255, blue: 85 / 255)

struct PhoneRootView: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        Group {
            if model.showsGlobe {
                GlobeView(model: model)
            } else {
                AuthView(model: model)
            }
        }
        .background(navy.ignoresSafeArea())
    }
}

struct AuthView: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Majesta Two")
                .font(.title)
                .foregroundStyle(gold)
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
            .background(gold, in: Capsule())
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
                .padding(.bottom, 36)
                .opacity(bannerOpacity)
                .animation(.easeOut(duration: 0.8), value: bannerOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                speech.cancelWithoutSending()
            }
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
        return model.banner
    }

    private var bannerOpacity: Double {
        if speech.holding { return speech.liveTranscript.isEmpty ? 0 : 1 }
        if let reason = speech.unavailableReason, !reason.isEmpty { return 1 }
        return model.bannerVisible ? 1 : 0
    }
}
