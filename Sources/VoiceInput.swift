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

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    /// Guards delayed session starts: incremented on every toggle
    /// and stop, so a start queued behind a teardown never fires
    /// after the user already stopped.
    private var sessionNonce = 0

    func toggle() {
        if isRecording { stop(); return }
        sessionNonce += 1
        let nonce = sessionNonce
        errorMessage = nil
        liveText = ""
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, nonce == self.sessionNonce else { return }
                guard status == .authorized else {
                    self.errorMessage = "Izin pengenalan suara ditolak. Aktifkan di Pengaturan → app ini → Pengenalan Ucapan."
                    return
                }
                self.beginRecording()
            }
        }
    }

    func stop() {
        sessionNonce += 1
        guard isRecording else { return }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        // Finish gracefully instead of cancel: a hard cancel can
        // leave the speech service connection in a state where the
        // next task fails with kAFAssistantErrorDomain 1107
        // (connection interrupted). The result handler clears
        // recognitionTask on terminal events.
        recognitionTask?.finish()
    }

    /// A fresh recognizer per session: reusing one instance across
    /// sessions can keep a stale connection to the speech service,
    /// which surfaces as 1107 on the next start.
    private func freshRecognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: "id-ID"))
    }

    private func beginRecording() {
        guard let recognizer = freshRecognizer(), recognizer.isAvailable else {
            errorMessage = "Pengenalan suara tidak tersedia di perangkat ini. Periksa koneksi internet, lalu coba lagi."
            return
        }
        // If a previous task is still tearing down, cancel it and let
        // the speech service settle before starting a new one —
        // starting immediately can fail with 1107.
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
            request = nil
            let nonce = sessionNonce
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard nonce == self.sessionNonce else { return }
                self.startAfterMicCheck(recognizer: recognizer)
            }
            return
        }
        startAfterMicCheck(recognizer: recognizer)
    }

    private func startAfterMicCheck(recognizer: SFSpeechRecognizer) {
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
                if let error {
                    // A genuine mid-recording failure: name the cause
                    // in plain Indonesian instead of the raw
                    // NSError text ("kesalahan kAFAssistantErrorDomain
                    // 1107"). When stop() already ran, isRecording is
                    // false, so a user-initiated stop never surfaces
                    // a bogus error.
                    if self.isRecording {
                        self.errorMessage = Self.friendlyMessage(for: error)
                    }
                    self.recognitionTask = nil
                    self.stop()
                    return
                }
                if result?.isFinal == true {
                    self.recognitionTask = nil
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

    /// Maps Speech-framework errors to a specific, actionable
    /// Indonesian message. Codes follow Apple's SFSpeechRecognition
    /// error table: 1107/1101 = connection to the speech process
    /// interrupted/invalidated, 1100 = an earlier instance still
    /// active, 1110 = no speech recognized, 1700 = not authorized.
    private static func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain" {
            switch ns.code {
            case 1107, 1101:
                return "Koneksi ke layanan pengenalan suara terputus. Coba tekan mikrofon lagi — kalau terus gagal, periksa koneksi internet, lalu coba lagi."
            case 1100:
                return "Sesi pengenalan suara sebelumnya masih aktif. Tunggu sebentar, lalu tekan mikrofon lagi."
            case 1110:
                return "Tidak ada ucapan yang dikenali. Coba bicara lebih dekat dengan mikrofon dan lebih jelas."
            case 1700:
                return "Izin pengenalan suara tidak aktif. Aktifkan di Pengaturan → app ini → Pengenalan Ucapan."
            default:
                break
            }
        }
        if ns.domain == "kLSRErrorDomain" {
            switch ns.code {
            case 201:
                return "Dikte dimatikan di perangkat ini. Aktifkan di Pengaturan → Umum → Keyboard → Dikte, lalu coba lagi."
            case 102:
                return "Model bahasa untuk pengenalan suara belum terpasang di perangkat ini."
            default:
                break
            }
        }
        return "Pengenalan suara gagal. Coba tekan mikrofon lagi."
    }
}
