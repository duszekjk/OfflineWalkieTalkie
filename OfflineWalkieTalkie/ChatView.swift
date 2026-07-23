import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var chat: ChatManager
    let close: () -> Void

    @State private var text = ""
    @State private var locationToOpen: ChatMessage?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(chat.messages) { message in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(message.sender)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    if message.kind == .location {
                                        Button {
                                            if chat.preferredMapsApp == .ask {
                                                locationToOpen = message
                                            } else {
                                                chat.openLocation(message)
                                            }
                                        } label: {
                                            Label("Otwórz udostępnioną lokalizację", systemImage: "map.fill")
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        Text(message.text)
                                            .textSelection(.enabled)
                                    }

                                    Text(message.date, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                                .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: chat.messages.count) {
                        if let id = chat.messages.last?.id {
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        chat.sendCurrentLocation()
                    } label: {
                        Image(systemName: "location.fill")
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                    .disabled(chat.currentLocation == nil)

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
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Czat")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Audio", action: close)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
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
}
