import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var walkieTalkie: WalkieTalkie

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text(walkieTalkie.status)
                .font(.headline)
                .multilineTextAlignment(.center)

            Picker("Wyjście audio", selection: $walkieTalkie.audioOutput) {
                ForEach(AudioOutput.allCases) { output in
                    Text(output.rawValue).tag(output)
                }
            }
            .pickerStyle(.menu)

            Circle()
                .fill(walkieTalkie.isTalking ? Color.red : Color.blue)
                .frame(width: 230, height: 230)
                .overlay {
                    Text(walkieTalkie.isTalking ? "MÓW" : "PRZYTRZYMAJ\nABY MÓWIĆ")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .scaleEffect(walkieTalkie.isTalking ? 1.06 : 1)
                .animation(.easeOut(duration: 0.12), value: walkieTalkie.isTalking)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !walkieTalkie.isTalking {
                                walkieTalkie.isTalking = true
                            }
                        }
                        .onEnded { _ in
                            walkieTalkie.isTalking = false
                        }
                )

            Text("Pierwsza faza: bezpośrednie audio PCM przez lokalne połączenie peer-to-peer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .padding()
    }
}
