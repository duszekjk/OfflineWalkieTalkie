import AVKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var walkieTalkie: WalkieTalkie

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text(walkieTalkie.status)
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack {
                Text("Wyjście audio")
                Spacer()
                AudioRoutePicker()
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal)

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

            Text("Przycisk wyjścia audio otwiera systemową listę rzeczywiście dostępnych urządzeń.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .padding()
    }
}

struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
