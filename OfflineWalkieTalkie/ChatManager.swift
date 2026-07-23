import CoreLocation
import Foundation
import Network
import UIKit

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case location
    }

    let id: UUID
    let sender: String
    let date: Date
    let kind: Kind
    let text: String
    let latitude: Double?
    let longitude: Double?
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
    @Published var preferredMapsApp: PreferredMapsApp {
        didSet { UserDefaults.standard.set(preferredMapsApp.rawValue, forKey: "preferredMapsApp") }
    }

    private let locationManager = CLLocationManager()
    private let parameters: NWParameters
    private let serviceName = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receivedData = Data()
    private var reconnectTimer: Timer?

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
            // Czat jest dodatkiem; błąd nie może zatrzymać głównej aplikacji.
        }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.connection == nil else { return }
            if self.browser == nil { self.startBrowsing() }
        }
    }

    deinit {
        reconnectTimer?.invalidate()
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
        send(ChatMessage(
            id: UUID(),
            sender: UserDefaults.standard.string(forKey: "deviceName") ?? UIDevice.current.name,
            date: Date(),
            kind: .text,
            text: value,
            latitude: nil,
            longitude: nil
        ))
    }

    func sendCurrentLocation() {
        guard let currentLocation else { return }
        send(ChatMessage(
            id: UUID(),
            sender: UserDefaults.standard.string(forKey: "deviceName") ?? UIDevice.current.name,
            date: Date(),
            kind: .location,
            text: "Udostępniona lokalizacja",
            latitude: currentLocation.coordinate.latitude,
            longitude: currentLocation.coordinate.longitude
        ))
    }

    func openLocation(_ message: ChatMessage, using app: PreferredMapsApp? = nil) {
        guard let latitude = message.latitude, let longitude = message.longitude else { return }
        let selected = app ?? preferredMapsApp

        if selected == .google,
           let url = URL(string: "comgooglemaps://?q=\(latitude),\(longitude)") {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }

        if let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(latitude),\(longitude)") {
            UIApplication.shared.open(url)
        }
    }

    private func send(_ message: ChatMessage) {
        append(message)
        guard let connection,
              let payload = try? JSONEncoder().encode(message) else { return }

        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.resetConnection() } }
        })
    }

    private func append(_ message: ChatMessage) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        messages.sort { $0.date < $1.date }
        if messages.count > 1_000 { messages.removeFirst(messages.count - 1_000) }
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: "chatMessages")
        }
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
                        if let message = try? JSONDecoder().decode(ChatMessage.self, from: payload) {
                            DispatchQueue.main.async { self.append(message) }
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
