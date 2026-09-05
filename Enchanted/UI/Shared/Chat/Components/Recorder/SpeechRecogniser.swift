//
//  SpeechRecogniser.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 21/12/2023.
//

//#if os(iOS)
import Foundation
import Speech

actor SpeechRecognizer: ObservableObject {
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
    
    @MainActor var transcript: String = ""

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    var recognizer: SFSpeechRecognizer?
    private var onUpdate: ((String) -> ())?
    var onAutoStop: (() -> ())?
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 1.5
    private let silenceThreshold: Float = 0.01
    
    /**
     Initializes a new speech recognizer. If this is the first time you've used the class, it
     requests access to the speech recognizer and the microphone.
     */
    func userInit() {
        if recognizer != nil {
            return
        }
        
        recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard recognizer != nil else {
            transcribe(RecognizerError.nilRecognizer)
            return
        }
        
        Task {
            do {
                
            
                let authStatus = SFSpeechRecognizer.authorizationStatus()
                
                switch authStatus {
                case .authorized:
                   print("authorised")
                case .denied, .restricted, .notDetermined:
                    print("denicd")
                @unknown default:
                    print("wtf")
                    break
                }
                
                guard await SFSpeechRecognizer.hasAuthorizationToRecognize() else {
                    throw RecognizerError.notAuthorizedToRecognize
                }
#if os(iOS)
                guard await AVAudioSession.sharedInstance().hasPermissionToRecord() else {
                    throw RecognizerError.notPermittedToRecord
                }
#endif
            } catch {
                transcribe(error)
            }
        }
    }
    
    private func setUpdateHandler(_ handler: @escaping (_ message: String) -> ()) {
        onUpdate = handler
    }
    
    @MainActor func startTranscribing(onUpdate: @escaping (_ message: String) -> ()) {
        Task {
            await self.setUpdateHandler(onUpdate)
            await transcribe()
        }
    }
    
    @MainActor func resetTranscript() {
        Task {
            await reset()
        }
    }
    
    @MainActor func stopTranscribing() {
        Task {
            await reset()
        }
    }
    
    /**
     Begin transcribing audio.
     
     Creates a `SFSpeechRecognitionTask` that transcribes speech to text until you call `stopTranscribing()`.
     The resulting transcription is continuously written to the published `transcript` property.
     */
    private func transcribe() {
        guard let recognizer, recognizer.isAvailable else {
            self.transcribe(RecognizerError.recognizerIsUnavailable)
            return
        }

        do {
            let (audioEngine, request) = try Self.prepareEngine { [weak self] buffer in
                self?.handleAudioBuffer(buffer)
            }
            self.audioEngine = audioEngine
            self.request = request
            self.task = recognizer.recognitionTask(with: request, resultHandler: { [weak self] result, error in
                self?.recognitionHandler(audioEngine: audioEngine, result: result, error: error)
            })
            startSilenceTimer()
        } catch {
            print("error here")
            self.reset()
            self.transcribe(error)
        }
    }

    /// Reset the speech recognizer.
    private func reset() {
        stopSilenceTimer()
        task?.cancel()
        audioEngine?.stop()
        audioEngine = nil
        request = nil
        task = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        #endif
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        if isAudioLevelAboveThreshold(buffer: buffer) {
            resetSilenceTimer()
        }
    }

    private static func prepareEngine(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws -> (AVAudioEngine, SFSpeechAudioBufferRecognitionRequest) {
        let audioEngine = AVAudioEngine()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

#if os(iOS) || os(visionOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
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
    
    nonisolated private func recognitionHandler(audioEngine: AVAudioEngine, result: SFSpeechRecognitionResult?, error: Error?) {
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
    
    
    nonisolated private func transcribe(_ message: String) {
        Task { @MainActor in
            transcript = message
            if !message.isEmpty {
                await onUpdate?(message)
            }
        }
    }
    nonisolated private func transcribe(_ error: Error) {
        var errorMessage = ""
        if let error = error as? RecognizerError {
            errorMessage += error.message
        } else {
            errorMessage += error.localizedDescription
        }
        Task { @MainActor [errorMessage] in
            transcript = "<< \(errorMessage) >>"
        }
    }

    private func startSilenceTimer() {
        Task { @MainActor in
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceTimeout, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.autoStopRecording()
                }
            }
        }
    }

    private func stopSilenceTimer() {
        Task { @MainActor in
            self.silenceTimer?.invalidate()
            self.silenceTimer = nil
        }
    }

    private func resetSilenceTimer() {
        Task { @MainActor in
            self.startSilenceTimer()
        }
    }

    private func autoStopRecording() {
        stopSilenceTimer()
        stopTranscribing()
        onAutoStop?()
    }

    private func isAudioLevelAboveThreshold(buffer: AVAudioPCMBuffer) -> Bool {
        guard let channelData = buffer.floatChannelData?[0] else { return false }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return false }

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += abs(channelData[i])
        }
        let averageLevel = sum / Float(frameLength)
        return averageLevel > silenceThreshold
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
