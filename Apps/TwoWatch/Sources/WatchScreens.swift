// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TwoClient

private let navy = Color(red: 27 / 255, green: 46 / 255, blue: 70 / 255)
private let gold = Color(red: 246 / 255, green: 207 / 255, blue: 85 / 255)

struct WatchRootView: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.showsGlobe {
                WatchGlobeView(model: model)
            } else {
                WatchWaitingView(status: model.status)
            }
        }
        .background(navy.ignoresSafeArea())
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.session == nil {
                model.bootstrap()
            }
        }
    }
}

struct WatchWaitingView: View {
    let status: String

    var body: some View {
        VStack(spacing: 8) {
            Text("Majesta Two")
                .font(.headline)
                .foregroundStyle(gold)
                .multilineTextAlignment(.center)
            Text(status.isEmpty ? "Enroll on the iPhone." : status)
                .font(.caption)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WatchGlobeView: View {
    @ObservedObject var model: WatchModel
    @StateObject private var speech = PushToTalk()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            GoldGlobe(activity: globeActivity)
                .scaleEffect(speech.holding ? 0.96 : 1)
                .opacity(globeActivity == .unavailable ? 0.45 : 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel(globeActivity.accessibilityLabel)
                .accessibilityAddTraits(.isButton)
                .animation(.spring(response: 0.34, dampingFraction: 0.72), value: globeActivity)
                .onLongPressGesture(minimumDuration: 86_400, maximumDistance: 80, pressing: { pressing in
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
            Text(bannerText)
                .font(.caption2)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .frame(minHeight: 28)
                .opacity(bannerOpacity)
                .animation(.easeOut(duration: 0.8), value: bannerOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                speech.cancelWithoutSending()
            } else {
                Task { await model.refreshIfNeeded() }
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
