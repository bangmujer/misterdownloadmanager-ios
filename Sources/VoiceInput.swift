import AVFoundation
import Speech
import SwiftUI

/// Live speech-to-text for the AI composers: tap the mic, talk, and
/// the transcript flows into the draft while recording. Indonesian
/// (id-ID) recognition; needs the speech-recognition + microphone
/// permissions (usage strings in project.yml).
@MainActor
final class SpeechTranscriber: ObservableObject {
    @Published private(set) var isRecording = false
    @Published var liveText = ""
    @Published var errorMessage: String?

    private var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "id-ID"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    func toggle() {
        if isRecording { stop(); return }
        errorMessage = nil
        liveText = ""
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "Izin pengenalan suara ditolak. Aktifkan di Pengaturan → app ini → Pengenalan Ucapan."
                    return
                }
                self.beginRecording()
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isRecording = false
    }

    private func beginRecording() {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Pengenalan suara tidak tersedia di perangkat ini."
            return
        }
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            startEngine(session: session, recognizer: recognizer)
        case .denied:
            errorMessage = "Izin mikrofon ditolak. Aktifkan di Pengaturan → app ini → Mikrofon."
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.startEngine(session: session, recognizer: recognizer)
                    } else {
                        self.errorMessage = "Izin mikrofon ditolak. Aktifkan di Pengaturan → app ini → Mikrofon."
                    }
                }
            }
        @unknown default:
            break
        }
    }

    private func startEngine(session: AVAudioSession, recognizer: SFSpeechRecognizer) {
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Mikrofon tidak bisa dipakai: \(error.localizedDescription)"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.liveText = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
        // The tap closure runs on the audio thread, so it appends to
        // the locally captured request instead of touching the
        // main-actor-isolated property.
        let audioRequest = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            audioRequest.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            errorMessage = "Mikrofon tidak bisa dipakai: \(error.localizedDescription)"
        }
    }
}
