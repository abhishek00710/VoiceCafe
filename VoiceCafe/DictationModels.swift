import Foundation

enum DictationStatus: String, Codable {
    case idle = "Ready"
    case recording = "Recording"
    case transcribing = "Transcribing"
    case processing = "Polishing text"
    case completed = "Completed"
    case failed = "Needs attention"
}

struct ProcessingStep: Identifiable, Codable {
    var id = UUID()
    var title: String
    var detail: String
    var date = Date()
    var success = true
}

struct DictationSession: Identifiable, Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var rawText: String
    var cleanedText: String
    var audioFileName: String?
    var duration: TimeInterval
    var steps: [ProcessingStep]
    var summary: String

    init(id: UUID = UUID(), title: String = "Untitled dictation", createdAt: Date = .now, updatedAt: Date = .now,
         rawText: String = "", cleanedText: String = "", audioFileName: String? = nil, duration: TimeInterval = 0,
         steps: [ProcessingStep] = [], summary: String = "") {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.audioFileName = audioFileName
        self.duration = duration
        self.steps = steps
        self.summary = summary
    }
}

struct AudioInput: Identifiable, Hashable {
    let id: String
    let name: String
}

enum TextPolisher {
    static func removingModelMarkers(from input: String) -> String {
        let marker = "\u{E000}"
        var text = input.replacingOccurrences(
            of: #"\[BLANK_AUDIO\]"#,
            with: marker,
            options: [.regularExpression, .caseInsensitive]
        )
        let duplicatePunctuationPattern = "([.!?])\\s*\(NSRegularExpression.escapedPattern(for: marker))\\s*[.!?]?"
        text = text.replacingOccurrences(of: duplicatePunctuationPattern, with: "$1", options: .regularExpression)
        return text
            .replacingOccurrences(of: marker, with: " ")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func polish(_ input: String) -> (text: String, explanation: String) {
        var text = removingModelMarkers(from: input)
        let original = text
        let rules: [(String, String)] = [
            (#"(?i)\b(um+|uh+|erm|er)\b[ ,]*"#, ""),
            (#"(?i)\bnew paragraph\b"#, "\n\n"),
            (#"(?i)\bnew line\b"#, "\n"),
            (#"(?i)\bcomma\b"#, ","),
            (#"(?i)\b(full stop|period)\b"#, "."),
            (#"(?i)\bquestion mark\b"#, "?"),
            (#"(?i)\b(exclamation mark|exclamation point)\b"#, "!")
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+([,?!\.])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([,?!\.])(?=\S)"#, with: "$1 ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        if let last = text.last, !".!?".contains(last) { text.append(".") }

        let notes: [String] = [
            original.range(of: #"(?i)\b(um+|uh+|erm|er)\b"#, options: .regularExpression) != nil ? "Removed filler words" : nil,
            original.range(of: #"(?i)\b(new paragraph|new line|comma|full stop|period|question mark|exclamation mark|exclamation point)\b"#, options: .regularExpression) != nil ? "Applied spoken formatting commands" : nil,
            text != original ? "Adjusted spacing, capitalization, and sentence punctuation" : nil
        ].compactMap { $0 }
        return (text, notes.isEmpty ? "No cleanup was needed." : notes.joined(separator: " • ") + ".")
    }
}

final class SessionStore {
    private let root: URL
    private let sessionsURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("VoiceCafe", isDirectory: true)
        sessionsURL = root.appendingPathComponent("sessions.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func audioURL(for session: DictationSession) -> URL? {
        if let name = session.audioFileName {
            let storedURL = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: storedURL.path) { return storedURL }
        }

        // Earlier app builds could save the recording under a different extension
        // than the one persisted in the session. Recover it by the stable session ID.
        for fileExtension in ["wav", "m4a", "caf"] {
            let candidate = root.appendingPathComponent("\(session.id.uuidString).\(fileExtension)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func newAudioURL(for id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).wav") }

    func deleteAudio(for session: DictationSession) throws {
        guard let url = audioURL(for: session), FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func load() -> [DictationSession] {
        guard let data = try? Data(contentsOf: sessionsURL),
              let sessions = try? JSONDecoder().decode([DictationSession].self, from: data) else { return [] }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ sessions: [DictationSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }
}
