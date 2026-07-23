import AVKit
import MapKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var walkieTalkie: WalkieTalkie
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showDeviceSettings = false
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
                        Annotation(
                            device.name,
                            coordinate: CLLocationCoordinate2D(
                                latitude: location.latitude,
                                longitude: location.longitude
                            )
                        ) {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(colors[device.colorIndex % colors.count])
                                    .frame(width: 18, height: 18)
                                    .overlay {
                                        Circle().stroke(.white, lineWidth: 3)
                                    }
                                    .shadow(radius: 4)

                                Text(device.name)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.thinMaterial, in: Capsule())
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
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(walkieTalkie.status)
                            .font(.headline)

                        if walkieTalkie.remoteDevices.isEmpty {
                            Text("Brak połączonych urządzeń")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(walkieTalkie.remoteDevices.map(\.name).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button {
                        showDeviceSettings = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.gearshape")
                            .font(.title3)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)

                    AudioRoutePicker()
                        .frame(width: 42, height: 42)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassPanel()

                HStack {
                    Spacer()
                    Button {
                        withAnimation {
                            mapPosition = .automatic
                        }
                    } label: {
                        Image(systemName: "scope")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassPanel()
                }

                Spacer()

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
                                if !walkieTalkie.isTalking {
                                    walkieTalkie.isTalking = true
                                }
                            }
                            .onEnded { _ in
                                walkieTalkie.isTalking = false
                            }
                    )
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeInOut(duration: 2)) {
                talkButtonOpacity = 0.08
            }
        }
        .sheet(isPresented: $showDeviceSettings) {
            NavigationStack {
                Form {
                    Section("Urządzenie") {
                        TextField("Nazwa urządzenia", text: $walkieTalkie.deviceName)

                        HStack {
                            ForEach(colors.indices, id: \.self) { index in
                                Circle()
                                    .fill(colors[index])
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if walkieTalkie.deviceColorIndex == index {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .onTapGesture {
                                        walkieTalkie.deviceColorIndex = index
                                    }
                            }
                        }
                    }
                }
                .navigationTitle("To urządzenie")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Gotowe") {
                            showDeviceSettings = false
                        }
                    }
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func glassPanel() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
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
