// Copyright 2026 MajestaNet
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

@MainActor
final class PushToTalk: ObservableObject {
    @Published private(set) var liveTranscript = ""
    @Published private(set) var unavailableReason: String?
    @Published private(set) var holding = false

#if canImport(Speech)
    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    init() {
        let recognizer = SFSpeechRecognizer()
        self.recognizer = recognizer
        if recognizer?.supportsOnDeviceRecognition != true {
            let locale = recognizer?.locale.identifier ?? "this locale"
            unavailableReason = "\(locale) is unavailable on device."
        }
    }

    func press() {
        guard unavailableReason == nil, !holding else { return }
        holding = true
        liveTranscript = ""
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.holding else { return }
                guard granted else {
                    self.unavailableReason = "The microphone is off."
                    self.holding = false
                    return
                }
                SFSpeechRecognizer.requestAuthorization { status in
                    Task { @MainActor in
                        guard self.holding else { return }
                        guard status == .authorized else {
                            self.unavailableReason = "Speech recognition is off."
                            self.holding = false
                            return
                        }
                        do {
                            try self.startEngine()
                        } catch {
                            self.holding = false
                            self.unavailableReason = "The microphone did not start."
                        }
                    }
                }
            }
        }
    }

    func release() async -> String {
        if engine.isRunning {
            engine.stop()
        }
        removeTapIfNeeded()
        request?.endAudio()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        return text
    }

    func cancelWithoutSending() {
        teardown()
        liveTranscript = ""
    }

    private func startEngine() throws {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw SpeechStartError.unavailable
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        removeTapIfNeeded()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in
                self?.liveTranscript = text
            }
        }
    }

    private func teardown() {
        holding = false
        if engine.isRunning {
            engine.stop()
        }
        removeTapIfNeeded()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }
#else
    init() {
        unavailableReason = "On-device speech recognition is not in this SDK."
    }

    func press() {}

    func release() async -> String { "" }

    func cancelWithoutSending() {
        liveTranscript = ""
    }
#endif
}

#if canImport(Speech)
private enum SpeechStartError: Error {
    case unavailable
}
#endif
