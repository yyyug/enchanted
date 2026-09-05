//
//  SpeechRecogniser.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 21/12/2023.
//

//#if os(iOS)
import Foundation
import Speech

final class SilenceTimerManager {
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 1.5
    private var onFire: (() -> Void)?

    func start(onFire: @escaping () -> Void) {
        stop()
        self.onFire = onFire
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            self?.onFire?()
        }
    }

    func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    func reset() {
        stop()
        guard let onFire = onFire else { return }
        start(onFire: onFire)
    }

    nonisolated static func isAudioLevelAboveThreshold(buffer: AVAudioPCMBuffer) -> Bool {
        guard let channelData = buffer.floatChannelData?[0] else { return false }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return false }

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += abs(channelData[i])
        }
        let averageLevel = sum / Float(frameLength)
        return averageLevel > 0.01
    }
}

@MainActor
final class SpeechRecognizer: ObservableObject {
    enum RecognizerError: Error {
        case nilRecognizer
        case notAuthorizedToRecognize
        case notPermittedToRecord
        case recognizerIsUnavailable
        
        var message: String {
            switch self {
            case .nilRecognizer: return "Can't initialize speech recognizer"
            case .notAuthorizedToRecognize: return "Not authorized to recognize speech"
            case .notPermittedToRecord: return "Not permitted to record audio"
            case .recognizerIsUnavailable: return "Recognizer is unavailable"
            }
        }
    }
    
    var transcript: String = ""

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    var recognizer: SFSpeechRecognizer?
    private var onUpdate: ((String) -> ())?
    var onAutoStop: (() -> ())?
    private let silenceTimerManager = SilenceTimerManager()
    
    /**
     Initializes a new speech recognizer. If this is the first time you've used the class, it
     requests access to the speech recognizer and the microphone.
     */
    func userInit() async {
        if recognizer != nil {
            return
        }

        // Try current locale first, then fallback to English
        let currentLocale = Locale.current
        recognizer = SFSpeechRecognizer(locale: currentLocale)

        if recognizer == nil || !recognizer!.isAvailable {
            print("Speech recognizer not available for locale: \(currentLocale.identifier), falling back to English")
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }

        guard let rec = recognizer, rec.isAvailable else {
            print("Speech recognizer not available for any locale")
            transcript = "<< Speech recognizer not available >>"
            return
        }

        print("Using locale: \(rec.locale.identifier)")

        // Request authorization - this shows the permission dialog
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        print("Current speech auth status: \(authStatus.rawValue)")

        if authStatus == .notDetermined {
            print("Requesting speech authorization...")
            let authorized = await SFSpeechRecognizer.hasAuthorizationToRecognize()
            print("Speech authorization result: \(authorized)")
            if !authorized {
                transcript = "<< Speech recognition not authorized >>"
                return
            }
        } else if authStatus == .denied || authStatus == .restricted {
            print("Speech authorization denied or restricted")
            transcript = "<< Speech recognition not authorized >>"
            return
        }

        // Request microphone permission
        #if os(iOS)
        let micAuthorized = await AVAudioSession.sharedInstance().hasPermissionToRecord()
        print("Microphone authorization result: \(micAuthorized)")
        if !micAuthorized {
            transcript = "<< Microphone not authorized >>"
            return
        }
        #endif

        print("Speech recognizer initialized successfully")
    }
    
    private func setUpdateHandler(_ handler: @escaping (_ message: String) -> ()) {
        onUpdate = handler
    }
    
    func startTranscribing(onUpdate: @escaping (_ message: String) -> ()) {
        setUpdateHandler(onUpdate)
        transcribe()
    }

    func resetTranscript() {
        reset()
    }

    func stopTranscribing() {
        reset()
    }
    
    /**
     Begin transcribing audio.
     
     Creates a `SFSpeechRecognitionTask` that transcribes speech to text until you call `stopTranscribing()`.
     The resulting transcription is continuously written to the published `transcript` property.
     */
    private func transcribe() {
        guard let recognizer, recognizer.isAvailable else {
            print("Recognizer not available")
            self.transcribe(RecognizerError.recognizerIsUnavailable)
            return
        }

        do {
            print("Starting speech recognition...")
            let (audioEngine, request) = try Self.prepareEngine { [weak self] buffer in
                if SilenceTimerManager.isAudioLevelAboveThreshold(buffer: buffer) {
                    self?.silenceTimerManager.reset()
                }
            }
            self.audioEngine = audioEngine
            self.request = request
            self.task = recognizer.recognitionTask(with: request, resultHandler: { [weak self] result, error in
                if let error = error {
                    print("Recognition error: \(error.localizedDescription)")
                }
                if let result = result {
                    print("Recognition result: \(result.bestTranscription.formattedString)")
                }
                self?.recognitionHandler(audioEngine: audioEngine, result: result, error: error)
            })
            silenceTimerManager.start(onFire: { [weak self] in
                self?.reset()
                self?.onAutoStop?()
            })
            print("Speech recognition started")
        } catch {
            print("Transcribe error: \(error.localizedDescription)")
            self.reset()
            self.transcribe(error)
        }
    }

    /// Reset the speech recognizer.
    private func reset() {
        silenceTimerManager.stop()
        task?.cancel()
        audioEngine?.stop()
        audioEngine = nil
        request = nil
        task = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        #endif
    }

    private static func prepareEngine(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws -> (AVAudioEngine, SFSpeechAudioBufferRecognitionRequest) {
        let audioEngine = AVAudioEngine()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

#if os(iOS) || os(visionOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        print("Audio session configured successfully")
#endif
        let inputNode = audioEngine.inputNode

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            request.append(buffer)
            onBuffer(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        return (audioEngine, request)
    }
    
    private func recognitionHandler(audioEngine: AVAudioEngine, result: SFSpeechRecognitionResult?, error: Error?) {
        let receivedFinalResult = result?.isFinal ?? false
        let receivedError = error != nil
        
        if receivedFinalResult || receivedError {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        if let result {
            transcribe(result.bestTranscription.formattedString)
        }
    }
    
    
    private func transcribe(_ message: String) {
        transcript = message
        if !message.isEmpty {
            onUpdate?(message)
        }
    }
    private func transcribe(_ error: Error) {
        var errorMessage = ""
        if let error = error as? RecognizerError {
            errorMessage += error.message
        } else {
            errorMessage += error.localizedDescription
        }
        transcript = "<< \(errorMessage) >>"
    }

}


extension SFSpeechRecognizer {
    static func hasAuthorizationToRecognize() async -> Bool {
        await withCheckedContinuation { continuation in
            requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}


#if os(iOS)
extension AVAudioSession {
    func hasPermissionToRecord() async -> Bool {
        await withCheckedContinuation { continuation in
            requestRecordPermission { authorized in
                continuation.resume(returning: authorized)
            }
        }
    }
}
#endif
//#endif
