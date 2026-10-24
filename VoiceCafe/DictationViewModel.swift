import AppKit
import AVFoundation
import Combine
import Speech

@MainActor
final class DictationViewModel: ObservableObject {
    @Published private(set) var sessions: [DictationSession]
    @Published var activeSessionID: UUID?
    @Published private(set) var status: DictationStatus = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var microphoneInputs: [AudioInput] = []
    @Published var selectedMicrophoneID: String?
    @Published var selectedLanguageID: String
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false

    private let store = SessionStore()
    private let service = LocalSpeechService()
    private var timer: AnyCancellable?

    init() {
        let loadedSessions = store.load()
        var removedModelMarkers = false
        let migratedSessions = loadedSessions.map { storedSession in
            var session = storedSession
            let cleanRawText = TextPolisher.removingModelMarkers(from: session.rawText)
            let cleanText = TextPolisher.removingModelMarkers(from: session.cleanedText)
            if cleanRawText != session.rawText || cleanText != session.cleanedText {
                removedModelMarkers = true
                session.rawText = cleanRawText
                session.cleanedText = cleanText
            }
            return session
        }
        sessions = migratedSessions
        activeSessionID = migratedSessions.first?.id
        selectedMicrophoneID = UserDefaults.standard.string(forKey: "selectedMicrophoneID")
        selectedLanguageID = UserDefaults.standard.string(forKey: "selectedLanguageID") ?? Locale.current.identifier
        if removedModelMarkers { store.save(migratedSessions) }
        refreshMicrophones()
    }

    let speechLanguages = ["en-US", "en-GB", "en-IN", "hi-IN", "bn-IN", "fr-FR", "de-DE", "es-ES", "ja-JP"]

    var activeSession: DictationSession? { sessions.first { $0.id == activeSessionID } }
    var formattedDuration: String {
        let seconds = Int(elapsedSeconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func refreshMicrophones() {
        microphoneInputs = LocalSpeechService.availableInputs()
        if selectedMicrophoneID == nil { selectedMicrophoneID = microphoneInputs.first?.id }
    }

    func select(_ session: DictationSession) { activeSessionID = session.id; errorMessage = nil }

    func startNewRecording() {
        guard !isRecording && !isTranscribing else { return }
        Task { await startRecording() }
    }

    func persistPreference() {
        UserDefaults.standard.set(selectedMicrophoneID, forKey: "selectedMicrophoneID")
        UserDefaults.standard.set(selectedLanguageID, forKey: "selectedLanguageID")
    }

    func dismissError() { errorMessage = nil }

    func toggleRecording() {
        if isRecording { stopRecording() } else { Task { await startRecording() } }
    }

    private func startRecording() async {
        errorMessage = nil
        refreshMicrophones()
        guard !microphoneInputs.isEmpty else {
            fail("No microphone was found. Connect or enable a microphone, then try again.")
            return
        }
        let micAllowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micAllowed = true
        case .notDetermined: micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: micAllowed = false
        }
        guard micAllowed else {
            fail("Microphone access is off. Allow Voice Café in System Settings → Privacy & Security → Microphone.")
            return
        }

        // Apple Speech supplies live partial transcripts. Ask for its permission
        // when needed, but do not block recording if the user declines; WhisperKit
        // can still transcribe the saved audio locally after recording stops.
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
            }
        }

        var session = DictationSession()
        session.audioFileName = "\(session.id.uuidString).wav"
        session.steps = [ProcessingStep(title: "Microphone ready", detail: "Recording audio locally on this Mac.")]
        activeSessionID = session.id
        sessions.insert(session, at: 0)
        persist()
        do {
            try service.start(deviceID: selectedMicrophoneID, locale: Locale(identifier: selectedLanguageID),
                              audioURL: store.newAudioURL(for: session.id),
                              onTranscript: { [weak self] text in
                                  Task { @MainActor in self?.updateRaw(text) }
                              },
                              onError: { [weak self] message in
                                  Task { @MainActor in self?.transcriptionFailed(message) }
                              },
                              onLevel: { [weak self] level in
                                  Task { @MainActor in self?.microphoneLevel = level }
                              },
                              onWhisperFallback: { [weak self] in
                                  Task { @MainActor in
                                      guard let self, let id = self.activeSessionID,
                                            let index = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                                      self.status = .transcribing
                                      self.sessions[index].steps.append(ProcessingStep(
                                          title: "Local Whisper model ready",
                                          detail: "Transcribing the saved audio on this Mac. The transcript will appear automatically when this finishes."
                                      ))
                                      self.sessions[index].updatedAt = .now
                                      self.persist()
                                  }
                              })
            isRecording = true
            status = .recording
            elapsedSeconds = 0
            microphoneLevel = 0
            timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self else { return }
                self.elapsedSeconds += 1
            }
        } catch {
            sessions.removeAll { $0.id == session.id }
            fail(error.localizedDescription)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        timer?.cancel()
        status = .transcribing
        isTranscribing = true
        guard let id = activeSessionID else { isTranscribing = false; return }
        service.stop { [weak self] raw, duration, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let index = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                let transcript = TextPolisher.removingModelMarkers(from: raw)
                guard duration >= 0.45, !transcript.isEmpty else {
                    self.sessions[index].steps.append(ProcessingStep(title: "No speech detected", detail: "The recording was too short or contained no recognizable words.", success: false))
                    self.sessions[index].summary = "No transcription was created. Try speaking a little longer and closer to the selected microphone."
                    self.sessions[index].updatedAt = .now
                    self.errorMessage = "No speech was detected. This empty recording was not submitted."
                    self.status = .failed
                    self.isTranscribing = false
                    self.persist()
                    return
                }
                self.status = .processing
                self.sessions[index].rawText = transcript
                self.sessions[index].duration = duration
                self.sessions[index].steps.append(ProcessingStep(title: "On-device transcription", detail: "Speech was recognized with the system model. No audio was sent to a server."))
                let polished = TextPolisher.polish(transcript)
                self.sessions[index].cleanedText = polished.text
                self.sessions[index].steps.append(ProcessingStep(title: "Readability cleanup", detail: polished.explanation))
                self.sessions[index].title = self.sessionTitle(from: polished.text)
                self.sessions[index].summary = "Recorded \(Int(duration.rounded())) seconds of audio. Produced \(polished.text.split(whereSeparator: \.isWhitespace).count) words, with local cleanup applied."
                self.sessions[index].updatedAt = .now
                self.sessions[index].steps.append(ProcessingStep(title: "Session saved", detail: "Transcript and audio are stored on this Mac."))
                self.persist()
                self.status = .completed
                self.isTranscribing = false
                self.elapsedSeconds = duration
                self.microphoneLevel = 0
            }
        }
    }

    func updateCleanedText(_ text: String) {
        guard let id = activeSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].cleanedText = text
        sessions[index].updatedAt = .now
        persist()
    }

    func copyText() {
        guard let text = activeSession?.cleanedText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func playAudio() {
        guard let session = activeSession else { return }
        guard let url = store.audioURL(for: session) else {
            errorMessage = "The audio recording for this dictation could not be found on this Mac."
            return
        }
        if !NSWorkspace.shared.open(url) { errorMessage = "macOS could not open the audio file at \(url.path)." }
    }

    func audioFileName(for session: DictationSession) -> String {
        store.audioURL(for: session)?.lastPathComponent ?? session.audioFileName ?? "Recording"
    }

    func deleteSession(_ session: DictationSession) {
        guard !isRecording && !isTranscribing else { return }
        do {
            try store.deleteAudio(for: session)
        } catch {
            errorMessage = "Could not delete the saved audio file: \(error.localizedDescription)"
            return
        }

        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
            elapsedSeconds = sessions.first?.duration ?? 0
            status = sessions.isEmpty ? .idle : .completed
        }
        persist()
    }

    func endSession() {
        if isRecording { stopRecording() }
        activeSessionID = nil
        status = .idle
    }

    private func updateRaw(_ text: String) {
        guard let id = activeSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].rawText = TextPolisher.removingModelMarkers(from: text)
        sessions[index].updatedAt = .now
        persist()
    }

    private func sessionTitle(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return words.isEmpty ? "Untitled dictation" : String(words.prefix(48))
    }

    private func fail(_ message: String) {
        errorMessage = message
        status = .failed
        isRecording = false
        isTranscribing = false
        microphoneLevel = 0
    }

    private func transcriptionFailed(_ message: String) {
        guard isRecording || isTranscribing else { return }
        service.cancel()
        timer?.cancel()
        isRecording = false
        isTranscribing = false
        microphoneLevel = 0
        status = .failed
        errorMessage = message
        if let id = activeSessionID, let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].steps.append(ProcessingStep(title: "Transcription failed", detail: message, success: false))
            sessions[index].updatedAt = .now
            persist()
        }
    }

    private func persist() {
        sessions.sort { $0.updatedAt > $1.updatedAt }
        store.save(sessions)
    }
}
