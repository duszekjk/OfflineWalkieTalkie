import AudioToolbox
import CoreLocation
import Foundation
import Network
import UIKit

enum AppMode: String, Codable, CaseIterable, Identifiable {
    case walkieTalkie = "Walkie-talkie"
    case call = "Rozmowa"
    case chat = "Czat"

    var id: Self { self }
}

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case location
        case image
    }

    let id: UUID
    let sender: String
    let date: Date
    let kind: Kind
    let text: String
    let latitude: Double?
    let longitude: Double?
    let imageData: Data?
}

enum PreferredMapsApp: String, CaseIterable, Identifiable {
    case ask = "Pytaj za każdym razem"
    case apple = "Apple Maps"
    case google = "Google Maps"

    var id: Self { self }
}

final class ChatManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var messages: [ChatMessage] = []
    @Published var connected = false
    @Published var currentLocation: CLLocation?
    @Published var appMode: AppMode = .walkieTalkie {
        didSet {
            guard !applyingRemoteMode else { return }
            send(ChatPacket(kind: .mode, message: nil, mode: appMode, messages: nil))
        }
    }
    @Published var preferredMapsApp: PreferredMapsApp {
        didSet { UserDefaults.standard.set(preferredMapsApp.rawValue, forKey: "preferredMapsApp") }
    }

    var localName: String {
        UserDefaults.standard.string(forKey: "deviceName") ?? UIDevice.current.name
    }

    private struct ChatPacket: Codable {
        enum Kind: String, Codable {
            case message
            case mode
            case history
        }

        let kind: Kind
        let message: ChatMessage?
        let mode: AppMode?
        let messages: [ChatMessage]?
    }

    private struct SavedDevice: Decodable {
        let name: String
        let colorIndex: Int
    }

    private let locationManager = CLLocationManager()
    private let parameters: NWParameters
    private let serviceName = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receivedData = Data()
    private var reconnectTimer: Timer?
    private var applyingRemoteMode = false

    override init() {
        preferredMapsApp = PreferredMapsApp(
            rawValue: UserDefaults.standard.string(forKey: "preferredMapsApp") ?? ""
        ) ?? .ask

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true

        super.init()

        if let data = UserDefaults.standard.data(forKey: "chatMessages"),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = saved
        }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.requestWhenInUseAuthorization()

        do {
            listener = try NWListener(using: parameters)
            listener?.service = NWListener.Service(name: serviceName, type: "_offlinechat._tcp")
            listener?.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { self?.use(connection) }
            }
            listener?.start(queue: .main)
        } catch {
            connected = false
        }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.connection == nil else { return }
            if self.browser == nil { self.startBrowsing() }
        }
    }

    deinit {
        reconnectTimer?.invalidate()
    }

    func colorIndex(for sender: String) -> Int {
        if normalizedName(sender) == normalizedName(localName) {
            return UserDefaults.standard.object(forKey: "deviceColorIndex") as? Int ?? 0
        }

        guard let data = UserDefaults.standard.data(forKey: "remoteDevices"),
              let devices = try? JSONDecoder().decode([SavedDevice].self, from: data),
              let device = devices.first(where: { normalizedName($0.name) == normalizedName(sender) }) else {
            return 0
        }
        return device.colorIndex
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }

    func send(text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        let message = ChatMessage(
            id: UUID(),
            sender: localName,
            date: Date(),
            kind: .text,
            text: value,
            latitude: nil,
            longitude: nil,
            imageData: nil
        )
        append(message)
        send(ChatPacket(kind: .message, message: message, mode: nil, messages: nil))
    }

    func send(image: UIImage) {
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, 1_600 / longestSide)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.72) else { return }

        let message = ChatMessage(
            id: UUID(),
            sender: localName,
            date: Date(),
            kind: .image,
            text: "Zdjęcie",
            latitude: nil,
            longitude: nil,
            imageData: data
        )
        append(message)
        send(ChatPacket(kind: .message, message: message, mode: nil, messages: nil))
    }

    func openLocation(_ message: ChatMessage, using app: PreferredMapsApp? = nil) {
        guard let latitude = message.latitude, let longitude = message.longitude else { return }
        let selected = app ?? preferredMapsApp

        if selected == .google,
           let url = URL(string: "comgooglemaps://?q=\(latitude),\(longitude)"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return
        }

        if let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(latitude),\(longitude)") {
            UIApplication.shared.open(url)
        }
    }

    @discardableResult
    private func append(_ message: ChatMessage) -> Bool {
        guard !messages.contains(where: { $0.id == message.id }) else { return false }
        messages.append(message)
        messages.sort { $0.date < $1.date }
        if messages.count > 300 { messages.removeFirst(messages.count - 300) }
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: "chatMessages")
        }
        return true
    }

    private func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func send(_ value: ChatPacket) {
        guard let connection,
              let payload = try? JSONEncoder().encode(value) else { return }

        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.resetConnection() } }
        })
    }

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjour(type: "_offlinechat._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            DispatchQueue.main.async {
                guard let self, let browser, self.browser === browser, self.connection == nil else { return }
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint, self.serviceName < name {
                        self.use(NWConnection(to: result.endpoint, using: self.parameters))
                        break
                    }
                }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            if case .failed = state {
                DispatchQueue.main.async {
                    guard let self, let browser, self.browser === browser else { return }
                    browser.cancel()
                    self.browser = nil
                }
            }
        }
        browser.start(queue: .main)
    }

    private func use(_ newConnection: NWConnection) {
        guard connection == nil else { newConnection.cancel(); return }
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            DispatchQueue.main.async {
                guard let self, let newConnection, self.connection === newConnection else { return }
                switch state {
                case .ready:
                    self.connected = true
                    self.browser?.cancel()
                    self.browser = nil
                    self.send(ChatPacket(kind: .mode, message: nil, mode: self.appMode, messages: nil))
                    self.send(ChatPacket(kind: .history, message: nil, mode: nil, messages: Array(self.messages.suffix(50))))
                case .failed, .cancelled:
                    self.resetConnection()
                default:
                    break
                }
            }
        }
        newConnection.start(queue: .main)

        func receive() {
            newConnection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak newConnection] data, _, complete, error in
                guard let self, let newConnection, self.connection === newConnection else { return }
                if let data {
                    self.receivedData.append(data)
                    while self.receivedData.count >= 4 {
                        let length = self.receivedData.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        guard self.receivedData.count >= 4 + Int(length) else { break }
                        let payload = self.receivedData.subdata(in: 4..<(4 + Int(length)))
                        self.receivedData.removeSubrange(0..<(4 + Int(length)))

                        guard let packet = try? JSONDecoder().decode(ChatPacket.self, from: payload) else { continue }
                        DispatchQueue.main.async {
                            if let message = packet.message,
                               self.append(message),
                               self.normalizedName(message.sender) != self.normalizedName(self.localName) {
                                AudioServicesPlaySystemSound(1007)
                            }
                            if let history = packet.messages {
                                for message in history { self.append(message) }
                            }
                            if let mode = packet.mode {
                                self.applyingRemoteMode = true
                                self.appMode = mode
                                self.applyingRemoteMode = false
                            }
                        }
                    }
                }
                if complete || error != nil {
                    DispatchQueue.main.async { self.resetConnection() }
                } else {
                    receive()
                }
            }
        }
        receive()
    }

    private func resetConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        connected = false
        receivedData.removeAll(keepingCapacity: true)
        browser?.cancel()
        browser = nil
    }
}
