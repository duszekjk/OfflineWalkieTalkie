import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var chat: ChatManager

    @State private var text = ""
    @State private var locationToOpen: ChatMessage?
    @State private var showSettings = false
    @State private var showCamera = false

    private let colors: [Color] = [.blue, .red, .green, .orange, .purple, .pink, .teal, .yellow]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tryb", selection: $chat.appMode) {
                    ForEach(AppMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(6)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.horizontal)
                .padding(.top, 8)

                HStack {
                    Circle()
                        .fill(chat.connected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(chat.connected ? "Czat połączony" : "Szukam urządzenia do czatu…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(chat.messages) { message in
                                let ownMessage = message.sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == chat.localName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                let colorIndex = chat.colorIndex(for: message.sender) % colors.count

                                HStack {
                                    if ownMessage { Spacer(minLength: 64) }

                                    VStack(alignment: ownMessage ? .trailing : .leading, spacing: 4) {
                                        if !ownMessage {
                                            Text(message.sender)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.leading, 8)
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            if message.kind == .image,
                                               let data = message.imageData,
                                               let image = UIImage(data: data) {
                                                Image(uiImage: image)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(maxWidth: 280, maxHeight: 320)
                                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                            } else if message.kind == .location {
                                                Button {
                                                    if chat.preferredMapsApp == .ask {
                                                        locationToOpen = message
                                                    } else {
                                                        chat.openLocation(message)
                                                    }
                                                } label: {
                                                    Label("Otwórz udostępnioną lokalizację", systemImage: "map.fill")
                                                }
                                                .buttonStyle(.plain)
                                            } else {
                                                Text(message.text)
                                                    .textSelection(.enabled)
                                            }

                                            Text(message.date, style: .time)
                                                .font(.caption2)
                                                .opacity(0.72)
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                        }
                                        .foregroundStyle(foregroundColor(for: colorIndex))
                                        .padding(message.kind == .image ? 6 : 12)
                                        .background(colors[colorIndex])
                                        .clipShape(
                                            UnevenRoundedRectangle(
                                                topLeadingRadius: 20,
                                                bottomLeadingRadius: ownMessage ? 20 : 5,
                                                bottomTrailingRadius: ownMessage ? 5 : 20,
                                                topTrailingRadius: 20
                                            )
                                        )
                                    }
                                    .frame(maxWidth: 310, alignment: ownMessage ? .trailing : .leading)

                                    if !ownMessage { Spacer(minLength: 64) }
                                }
                                .frame(maxWidth: .infinity)
                                .id(message.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: chat.messages.count) {
                        if let id = chat.messages.last?.id {
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        showCamera = true
                    } label: {
                        Image(systemName: "camera.fill")
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                    .disabled(!chat.connected || !UIImagePickerController.isSourceTypeAvailable(.camera))

                    TextField("Wiadomość", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.interactive(), in: .capsule)

                    Button {
                        chat.send(text: text)
                        text = ""
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.connected)
                }
                .padding()
            }
            .navigationTitle("Czat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraView { image in
                    chat.send(image: image)
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .confirmationDialog("Otwórz lokalizację w", isPresented: Binding(
                get: { locationToOpen != nil },
                set: { if !$0 { locationToOpen = nil } }
            )) {
                Button("Apple Maps") {
                    if let message = locationToOpen { chat.openLocation(message, using: .apple) }
                    locationToOpen = nil
                }
                Button("Google Maps") {
                    if let message = locationToOpen { chat.openLocation(message, using: .google) }
                    locationToOpen = nil
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    Form {
                        Picker("Preferowana aplikacja map", selection: $chat.preferredMapsApp) {
                            ForEach(PreferredMapsApp.allCases) { app in
                                Text(app.rawValue).tag(app)
                            }
                        }
                    }
                    .navigationTitle("Ustawienia")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Gotowe") { showSettings = false }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func foregroundColor(for colorIndex: Int) -> Color {
        switch colorIndex {
        case 2, 3, 5, 7:
            return .black
        default:
            return .white
        }
    }
}

struct CameraView: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPhoto: onPhoto)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onPhoto: (UIImage) -> Void

        init(onPhoto: @escaping (UIImage) -> Void) {
            self.onPhoto = onPhoto
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onPhoto(image)
            } else {
                picker.dismiss(animated: true)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
