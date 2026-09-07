//
//  SwiftUIView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 18/12/2023.
//

import SwiftUI
import AVFoundation

struct RecordingView: View {
    @StateObject var speechRecognizer: SpeechRecognizer = SpeechRecognizer()
    @Binding var isRecording: Bool
    var onComplete: (_ transcription: String) -> () = {_ in}
    
    private func toggleRecord() {
        Task {
            await speechRecognizer.userInit()
            await toggleTranscribing()
        }
        Haptics.shared.mediumTap()
    }
    
    private func toggleTranscribing() async {
        if isRecording {
            // Manual stop
            speechRecognizer.stopTranscribing()
            onComplete(speechRecognizer.transcript)
            isRecording = false
        } else {
            // Auto-stop handler
            speechRecognizer.onAutoStop = {
                Task { @MainActor in
                    print("Auto-stop triggered")
                    onComplete(speechRecognizer.transcript)
                    isRecording = false
                    // Force UI update
                    speechRecognizer.objectWillChange.send()
                }
            }
            speechRecognizer.resetTranscript()
            speechRecognizer.startTranscribing(onUpdate: onComplete)
            isRecording = true
        }
    }
    
    var body: some View {
        Button(action: toggleRecord) {
            if isRecording {
                ZStack {
                    Color(.systemBlue)
                    
                    Image(systemName: "square.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.white)
                        .frame(width: 14)
                }
                .clipShape(Circle())
                .frame(width: 44, height: 44)
            } else {
                Image(systemName: "waveform")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Color(.systemGray))
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(isRecording ? NSLocalizedString("Stop", comment: "Stop recording") : NSLocalizedString("Voice", comment: "Voice input"))
        .onChange(of: isRecording) { oldValue, newValue in
            if newValue == false {
                speechRecognizer.stopTranscribing()
            }
        }
    }
}


struct MeetingView_Previews: PreviewProvider {
    static var previews: some View {
        RecordingView(speechRecognizer: SpeechRecognizer(), isRecording: .constant(true))
    }
}
