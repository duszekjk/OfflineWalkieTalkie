import AVKit
import MapKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var walkieTalkie: WalkieTalkie
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showColorPicker = false
    @State private var talkButtonOpacity = 1.0

    private let colors: [Color] = [.blue, .red, .green, .orange, .purple, .pink, .teal, .yellow]

    var body: some View {
        ZStack {
            Map(position: $mapPosition) {
                ForEach(walkieTalkie.devicesForMap) { device in
                    if device.locations.count > 1 {
                        MapPolyline(coordinates: device.locations.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .stroke(colors[device.colorIndex % colors.count], lineWidth: 4)
                    }

                    if let location = device.locations.last {
                        Annotation(device.name, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)) {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(colors[device.colorIndex % colors.count])
                                    .frame(width: 18, height: 18)
                                    .overlay { Circle().stroke(.white, lineWidth: 3) }
                                    .shadow(radius: 4)

                                Text(device.name)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .glassEffect(.regular, in: .capsule)
                            }
                        }
                    }
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        Picker("Tryb", selection: $walkieTalkie.mode) {
                            ForEach(CommunicationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(6)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        HStack(spacing: 10) {
                            Circle()
                                .fill(colors[walkieTalkie.deviceColorIndex % colors.count])
                                .frame(width: 14, height: 14)

                            TextField("Nazwa tego urządzenia", text: $walkieTalkie.deviceName)
                                .font(.headline)
                                .textFieldStyle(.plain)
                                .submitLabel(.done)

                            Button { showColorPicker = true } label: {
                                Image(systemName: "paintpalette")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.glass)
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 6)
                        .padding(.vertical, 6)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(walkieTalkie.callActive ? "Rozmowa aktywna" : walkieTalkie.status)
                                    .font(.subheadline.weight(.semibold))

                                Text(
                                    walkieTalkie.remoteDevices.isEmpty
                                    ? "Brak połączonych urządzeń"
                                    : walkieTalkie.remoteDevices.map(\.name).joined(separator: ", ")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            AudioRoutePicker()
                                .frame(width: 36, height: 36)
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 10)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        withAnimation { mapPosition = .automatic }
                    } label: {
                        Image(systemName: "scope")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                }

                Spacer()

                if walkieTalkie.mode == .walkieTalkie {
                    Circle()
                        .fill(walkieTalkie.isTalking ? Color.red : Color.blue)
                        .frame(width: 280, height: 280)
                        .overlay {
                            Text(walkieTalkie.isTalking ? "MÓW" : "PRZYTRZYMAJ\nABY MÓWIĆ")
                                .font(.title.bold())
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        }
                        .scaleEffect(walkieTalkie.isTalking ? 1.05 : 1)
                        .opacity(walkieTalkie.isTalking ? 1 : talkButtonOpacity)
                        .animation(.easeOut(duration: 0.12), value: walkieTalkie.isTalking)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    if !walkieTalkie.isTalking { walkieTalkie.isTalking = true }
                                }
                                .onEnded { _ in walkieTalkie.isTalking = false }
                        )
                        .padding(.bottom, 18)
                } else {
                    VStack(spacing: 16) {
                        Button {
                            walkieTalkie.callActive.toggle()
                        } label: {
                            Circle()
                                .fill(walkieTalkie.callActive ? Color.red : Color.green)
                                .frame(width: 220, height: 220)
                                .overlay {
                                    VStack(spacing: 12) {
                                        Image(systemName: walkieTalkie.callActive ? "phone.down.fill" : "phone.fill")
                                            .font(.system(size: 44, weight: .bold))
                                        Text(walkieTalkie.callActive ? "ZAKOŃCZ" : "ROZPOCZNIJ\nROZMOWĘ")
                                            .font(.title2.bold())
                                            .multilineTextAlignment(.center)
                                    }
                                    .foregroundStyle(.white)
                                }
                        }
                        .buttonStyle(.plain)

                        if walkieTalkie.callActive {
                            Button {
                                walkieTalkie.microphoneMuted.toggle()
                            } label: {
                                Label(
                                    walkieTalkie.microphoneMuted ? "Włącz mikrofon" : "Wycisz mikrofon",
                                    systemImage: walkieTalkie.microphoneMuted ? "mic.slash.fill" : "mic.fill"
                                )
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.bottom, 18)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeInOut(duration: 2)) { talkButtonOpacity = 0.08 }
        }
        .sheet(isPresented: $showColorPicker) {
            NavigationStack {
                VStack(spacing: 24) {
                    Text("Kolor urządzenia")
                        .font(.title2.bold())

                    HStack(spacing: 14) {
                        ForEach(colors.indices, id: \.self) { index in
                            Circle()
                                .fill(colors[index])
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if walkieTalkie.deviceColorIndex == index {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { walkieTalkie.deviceColorIndex = index }
                        }
                    }
                    Spacer()
                }
                .padding()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Gotowe") { showColorPicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
