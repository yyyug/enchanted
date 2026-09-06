//
//  ReadingAloudView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 26/05/2024.
//

import SwiftUI

struct ReadingAloudView: View {
    var onStopTap: () -> ()
    @State private var animationsRunning = false

    var body: some View {
        HStack {

            if UIAccessibility.isReduceMotionEnabled {
                Image(systemName: "speaker.wave.3")
                    .scaledToFit()
                    .frame(width: 18)
            } else {
                Image(systemName: "speaker.wave.3")
                    .scaledToFit()
                    .frame(width: 18)
                    .symbolEffect(.variableColor.iterative, options: .repeat(100), value: animationsRunning)
            }

            Text("Reading Aloud")
                .font(.subheadline)

            Spacer()

            Button(action: onStopTap) {
                Image(systemName: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(5)
            }
            .buttonStyle(GrowingButton())
            .accessibilityLabel(NSLocalizedString("Stop Reading", comment: "Stop reading button"))

        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 24).fill(.regularMaterial)
        }
        .padding()
        .onAppear {
            animationsRunning = !UIAccessibility.isReduceMotionEnabled
        }
    }
}

#Preview {
    ReadingAloudView(onStopTap: {})
}
