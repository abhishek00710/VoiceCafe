import AVFoundation
import AudioToolbox
import CoreAudio
import Speech
@preconcurrency import WhisperKit

final class LocalSpeechService {
    private let engine = AVAudioEngine()
    private let audioWriteQueue = DispatchQueue(label: "com.codecafe.voicecafe.audio-writer", qos: .utility)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var fileRequest: SFSpeechURLRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var currentAudioURL: URL?
    private var startTime: Date?
    private var recognizer: SFSpeechRecognizer?
    private var latestText = ""
    private var onTranscript: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var pendingStop: ((String, TimeInterval, URL?) -> Void)?
    private var stoppedDuration: TimeInterval = 0
    private var stopTimeout: DispatchWorkItem?
    private var onLevel: ((Float) -> Void)?
    private var onWhisperFallback: (() -> Void)?
    private var lastLevelUpdate = Date.distantPast
    private var peakLevelDuringRecording: Float = 0
    private var whisperKit: WhisperKit?
    private var whisperTask: Task<Void, Never>?
    private var isWhisperRunning = false
    private var whisperLanguageCode: String?

    static func availableInputs() -> [AudioInput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var inputAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                          mScope: kAudioDevicePropertyScopeInput,
                                                          mElement: kAudioObjectPropertyElementMain)
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &inputAddress, 0, nil, &inputSize) == noErr, inputSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }
            return AudioInput(id: String(device), name: name as String)
        }
    }

    func start(deviceID: String?, locale: Locale, audioURL: URL, onTranscript: @escaping (String) -> Void,
               onError: @escaping (String) -> Void, onLevel: @escaping (Float) -> Void,
               onWhisperFallback: @escaping () -> Void) throws {
        // Apple's recognizer provides live text when it supports this locale. Keep it
        // optional: the local Whisper model can still transcribe the saved recording
        // when Apple Speech is unavailable or returns no words.
        let recognizer = SFSpeechRecognizer(locale: locale)
        let localeIdentifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        whisperLanguageCode = String(localeIdentifier.prefix(while: { $0 != "-" })).lowercased()
        self.recognizer = (SFSpeechRecognizer.authorizationStatus() == .authorized
                           && recognizer?.isAvailable == true
                           && recognizer?.supportsOnDeviceRecognition == true)
            ? recognizer : nil
        self.onTranscript = onTranscript
        self.onError = onError
        self.onLevel = onLevel
        self.onWhisperFallback = onWhisperFallback
        latestText = ""
        peakLevelDuringRecording = 0
        lastLevelUpdate = .distantPast
        currentAudioURL = audioURL

        try? FileManager.default.removeItem(at: audioURL)
        let input = engine.inputNode
        if let id = deviceID.flatMap({ AudioDeviceID($0) }) {
            var selectedDevice = id
            if let unit = input.audioUnit {
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &selectedDevice,
                                                  UInt32(MemoryLayout<AudioDeviceID>.size))
                guard status == noErr else { throw ServiceError.unavailable("Could not switch to the selected microphone.") }
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw ServiceError.unavailable("No microphone input is available.") }
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        audioFile = file
        if let recognizer = self.recognizer {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.request = request
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.latestText = result.bestTranscription.formattedString
                    self.onTranscript?(self.latestText)
                    if result.isFinal, self.pendingStop != nil {
                        if self.latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.startFileFallback()
                        } else {
                            self.completePendingStop()
                        }
                    }
                }
                if let error, (error as NSError).code != 216, self.pendingStop != nil {
                    self.startFileFallback()
                } else if let error, (error as NSError).code != 216 {
                    self.onError?("Live transcription stopped: \(error.localizedDescription)")
                }
            }
        }
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let peak = Self.peakLevel(buffer)
            self.peakLevelDuringRecording = max(self.peakLevelDuringRecording, peak)
            let now = Date()
            if now.timeIntervalSince(self.lastLevelUpdate) >= 0.12 {
                self.lastLevelUpdate = now
                DispatchQueue.main.async { self.onLevel?(peak) }
            }
            guard let copy = Self.copyBuffer(buffer) else { return }
            self.audioWriteQueue.async { [weak self] in
                guard let self, let file = self.audioFile else { return }
                do { try file.write(from: copy) }
                catch {
                    DispatchQueue.main.async { self.onError?("Could not save the audio recording: \(error.localizedDescription)") }
                }
            }
            self.request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            startTime = Date()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop(completion: @escaping (String, TimeInterval, URL?) -> Void) {
        guard engine.isRunning else { completion(latestText, 0, currentAudioURL); return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stoppedDuration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        audioWriteQueue.sync { audioFile = nil }
        pendingStop = completion
        guard let task else {
            startWhisperFallback()
            return
        }
        request?.endAudio()
        task.finish()
        let timeout = DispatchWorkItem { [weak self] in self?.startFileFallback() }
        stopTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
    }

    private func startFileFallback() {
        guard pendingStop != nil else { return }
        stopTimeout?.cancel()
        stopTimeout = nil
        task?.cancel()
        task = nil
        request = nil
        guard let url = currentAudioURL else {
            failPendingStop("The recording file could not be found.")
            return
        }
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            failPendingStop("The microphone did not produce an audio recording. Check the selected input and macOS microphone privacy settings.")
            return
        }
        guard peakLevelDuringRecording >= 0.003 else {
            failPendingStop("The recording contains almost no microphone signal. In System Settings → Sound → Input, select the same microphone and check that its input level moves when you speak. Also check that another app is not holding the microphone.")
            return
        }
        guard let recognizer else {
            startWhisperFallback()
            return
        }
        let fileRequest = SFSpeechURLRecognitionRequest(url: url)
        fileRequest.shouldReportPartialResults = true
        fileRequest.requiresOnDeviceRecognition = true
        self.fileRequest = fileRequest
        task = recognizer.recognitionTask(with: fileRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.latestText = result.bestTranscription.formattedString
                    self.onTranscript?(self.latestText)
                    if result.isFinal { self.completePendingStop() }
                }
                if let error, (error as NSError).code != 216, self.pendingStop != nil {
                    self.startWhisperFallback()
                }
            }
        }
        // File transcription may need extra time for the local model, particularly on its first run.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.startWhisperFallback()
            } else {
                self.completePendingStop()
            }
        }
        stopTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    private func completePendingStop() {
        guard let completion = pendingStop else { return }
        guard !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            startWhisperFallback()
            return
        }
        pendingStop = nil
        stopTimeout?.cancel()
        stopTimeout = nil
        completion(latestText, stoppedDuration, currentAudioURL)
        task = nil
        request = nil
        fileRequest = nil
        recognizer = nil
        whisperTask?.cancel()
        whisperTask = nil
    }

    private func startWhisperFallback() {
        guard pendingStop != nil, !isWhisperRunning else { return }
        isWhisperRunning = true
        onWhisperFallback?()
        stopTimeout?.cancel()
        stopTimeout = nil
        task?.cancel()
        task = nil
        request = nil
        fileRequest = nil
        guard let url = currentAudioURL else {
            failPendingStop("The recording file could not be found.")
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.failPendingStop("The local Whisper model is taking too long to load. Keep Voice Café open and try again.")
        }
        stopTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)
        let languageCode = whisperLanguageCode
        whisperTask = Task { [weak self] in
            do {
                let pipeline: WhisperKit
                if let cached = self?.whisperKit {
                    pipeline = cached
                } else {
                    pipeline = try await WhisperKit(WhisperKitConfig(model: "base"))
                }
                let options = DecodingOptions(task: .transcribe, language: languageCode, skipSpecialTokens: true)
                let results = try await pipeline.transcribe(audioPath: url.path, decodeOptions: options)
                let transcription = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard let self, self.pendingStop != nil else { return }
                    self.isWhisperRunning = false
                    self.whisperKit = pipeline
                    self.latestText = transcription
                    if transcription.isEmpty {
                        self.failPendingStop("Both local speech models returned no words. Check that you are speaking close to the selected microphone.")
                    } else {
                        self.onTranscript?(transcription)
                        self.completePendingStop()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isWhisperRunning = false
                    self?.failPendingStop("The local Whisper model could not run: \(error.localizedDescription)")
                }
            }
        }
    }

    private func failPendingStop(_ message: String) {
        guard pendingStop != nil else { return }
        pendingStop = nil
        isWhisperRunning = false
        stopTimeout?.cancel()
        stopTimeout = nil
        task?.cancel()
        whisperTask?.cancel()
        whisperTask = nil
        isWhisperRunning = false
        task = nil
        request = nil
        fileRequest = nil
        onError?(message)
        recognizer = nil
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else { return nil }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffer.mDataByteSize = sourceBuffer.mDataByteSize
            destinationBuffers[index] = destinationBuffer
        }
        return copy
    }

    private static func peakLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let sampleCount = Int(buffer.frameLength)
        guard sampleCount > 0 else { return 0 }
        var peak: Float = 0
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for sample in 0..<sampleCount { peak = max(peak, abs(channels[channel][sample])) }
            }
        } else if let channels = buffer.int16ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for sample in 0..<sampleCount { peak = max(peak, abs(Float(channels[channel][sample])) / Float(Int16.max)) }
            }
        } else if let channels = buffer.int32ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for sample in 0..<sampleCount { peak = max(peak, abs(Float(channels[channel][sample])) / Float(Int32.max)) }
            }
        }
        return peak
    }

    func cancel() {
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        task?.cancel()
        stopTimeout?.cancel()
        pendingStop = nil
        audioWriteQueue.sync { audioFile = nil }
        request = nil
        fileRequest = nil
        task = nil
    }

    enum ServiceError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            if case .unavailable(let message) = self { return message }
            return "A local speech recognition error occurred."
        }
    }
}
