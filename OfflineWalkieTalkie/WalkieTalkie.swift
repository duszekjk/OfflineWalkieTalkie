import AVFoundation
import Combine
import CoreLocation
import Network
import UIKit
import os

enum CommunicationMode: String, CaseIterable, Identifiable {
    case walkieTalkie = "Walkie-talkie"
    case call = "Rozmowa"

    var id: Self { self }
}

struct LocationPoint: Codable, Identifiable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let date: Date

    init(_ location: CLLocation) {
        id = UUID()
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        date = location.timestamp
    }
}

struct ConnectedDevice: Identifiable {
    let id: String
    var name: String
    var colorIndex: Int
    var locations: [LocationPoint]
}

final class WalkieTalkie: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var status = "Szukam drugiego urządzenia…"
    @Published var remoteDevices: [ConnectedDevice] = []
    @Published var localLocations: [LocationPoint] = []
    @Published var mode: CommunicationMode = .walkieTalkie {
        didSet {
            if mode == .walkieTalkie, callActive { callActive = false }
            updateCapture()
        }
    }
    @Published var callActive = false {
        didSet {
            if callActive { mode = .call }
            updateCapture()
            if !applyingRemoteCallState {
                sendPacket(type: 6, payload: Data([callActive ? 1 : 0]))
            }
        }
    }
    @Published var microphoneMuted = false {
        didSet { updateCapture() }
    }
    @Published var isTalking = false {
        didSet { updateCapture() }
    }
    @Published var deviceName: String {
        didSet {
            UserDefaults.standard.set(deviceName, forKey: "deviceName")
            sendIdentity()
        }
    }
    @Published var deviceColorIndex: Int {
        didSet {
            UserDefaults.standard.set(deviceColorIndex, forKey: "deviceColorIndex")
            sendIdentity()
        }
    }

    var devicesForMap: [ConnectedDevice] {
        [ConnectedDevice(id: deviceID, name: deviceName, colorIndex: deviceColorIndex, locations: localLocations)] + remoteDevices
    }

    private struct AudioBufferState {
        var samples = [Float](repeating: 0, count: 3_200)
        var readIndex = 0
        var writeIndex = 0
        var count = 0
    }

    private struct Identity: Codable {
        let id: String
        let name: String
        let colorIndex: Int
    }

    private struct LocationUpdate: Codable {
        let id: String
        let points: [LocationPoint]
    }

    private let audioEngine = AVAudioEngine()
    private let audioBuffer = OSAllocatedUnfairLock(initialState: AudioBufferState())
    private lazy var sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
        guard let self else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        self.audioBuffer.withLock { state in
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<Int(frameCount) {
                    if state.count > 0 {
                        data[index] = state.samples[state.readIndex]
                        state.readIndex = (state.readIndex + 1) % state.samples.count
                        state.count -= 1
                    } else {
                        data[index] = 0
                    }
                }
            }
        }
        return noErr
    }
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let locationManager = CLLocationManager()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var peerEndpoint: NWEndpoint?
    private var receivedData = Data()
    private var connected = false
    private var remoteAudioActive = false
    private var localAudioActive = false
    private var microphoneReady = false
    private var tapInstalled = false
    private var applyingRemoteCallState = false
    private var sequence: UInt32 = 0
    private var lastReceived = Date()
    private var lastLocationSync = Date.distantPast
    private var sentLocationCount = 0
    private var reconnectTimer: Timer?
    private var silentFrameCount = 0
    private var preRoll: [[Int16]] = []
    private let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private let parameters: NWParameters

    override init() {
        deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? UIDevice.current.name
        deviceColorIndex = UserDefaults.standard.object(forKey: "deviceColorIndex") as? Int ?? 0

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        super.init()

        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: playbackFormat)
        audioEngine.mainMixerNode.outputVolume = 1

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 20
        locationManager.requestWhenInUseAuthorization()

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.status = "Brak dostępu do mikrofonu"
                    return
                }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
                    try session.setPreferredSampleRate(48_000)
                    try session.setPreferredIOBufferDuration(0.005)
                    try session.setActive(true)
                    try self.audioEngine.inputNode.setVoiceProcessingEnabled(true)
                    self.audioEngine.prepare()
                    try self.audioEngine.start()
                    self.microphoneReady = true
                } catch {
                    self.status = "Błąd audio: \(error.localizedDescription)"
                }
            }
        }

        do {
            listener = try NWListener(using: parameters)
            listener?.service = NWListener.Service(name: deviceID, type: "_offlinewalkie._tcp")
            listener?.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { self?.use(connection) }
            }
            listener?.start(queue: .main)
        } catch {
            status = "Błąd nasłuchiwania: \(error.localizedDescription)"
        }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.connected {
                if Date().timeIntervalSince(self.lastReceived) > 4 {
                    self.resetConnection()
                    return
                }
                self.sendPacket(type: 2)
                if !self.localAudioActive,
                   !self.remoteAudioActive,
                   Date().timeIntervalSince(self.lastLocationSync) >= 60,
                   self.sentLocationCount < self.localLocations.count {
                    let end = min(self.sentLocationCount + 20, self.localLocations.count)
                    let update = LocationUpdate(id: self.deviceID, points: Array(self.localLocations[self.sentLocationCount..<end]))
                    if let data = try? JSONEncoder().encode(update) {
                        self.sendPacket(type: 4, payload: data)
                        self.sentLocationCount = end
                        self.lastLocationSync = Date()
                    }
                }
                return
            }
            if self.connection == nil, let endpoint = self.peerEndpoint {
                self.use(NWConnection(to: endpoint, using: self.parameters))
                return
            }
            guard self.browser == nil else { return }
            let browser = NWBrowser(for: .bonjour(type: "_offlinewalkie._tcp", domain: nil), using: self.parameters)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                DispatchQueue.main.async {
                    guard let self, let browser, self.browser === browser else { return }
                    self.peerEndpoint = nil
                    for result in results {
                        if case let .service(name, _, _, _) = result.endpoint, self.deviceID < name {
                            self.peerEndpoint = result.endpoint
                            if self.connection == nil { self.use(NWConnection(to: result.endpoint, using: self.parameters)) }
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
    }

    deinit { reconnectTimer?.invalidate() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        if let previous = localLocations.last {
            let previousLocation = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            guard location.distance(from: previousLocation) >= 20 || location.timestamp.timeIntervalSince(previous.date) >= 60 else { return }
        }
        localLocations.append(LocationPoint(location))
        if localLocations.count > 300 {
            let removed = localLocations.count - 300
            localLocations.removeFirst(removed)
            sentLocationCount = max(0, sentLocationCount - removed)
        }
    }

    private func updateCapture() {
        let shouldCapture = connected && microphoneReady && ((mode == .walkieTalkie && isTalking) || (mode == .call && callActive && !microphoneMuted))
        if shouldCapture, !tapInstalled { startCapture() }
        if !shouldCapture, tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            preRoll.removeAll(keepingCapacity: true)
            silentFrameCount = 0
            if localAudioActive {
                localAudioActive = false
                sendPacket(type: 5, payload: Data([0]))
            }
        }
    }

    private func startCapture() {
        guard let connection, connected, microphoneReady else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }
        } catch {
            status = "Błąd mikrofonu: \(error.localizedDescription)"
            return
        }

        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = "Brak aktywnego wejścia mikrofonowego"
            return
        }

        localAudioActive = false
        silentFrameCount = 0
        preRoll.removeAll(keepingCapacity: true)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.02), format: format) { [weak self, weak connection] buffer, _ in
            guard let self, let connection, self.connection === connection, let channel = buffer.floatChannelData?[0] else { return }

            var squareSum: Float = 0
            for index in 0..<Int(buffer.frameLength) { squareSum += channel[index] * channel[index] }
            let rms = sqrt(squareSum / Float(max(1, buffer.frameLength)))

            let outputCount = max(1, Int((Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate).rounded()))
            var samples = [Int16](repeating: 0, count: outputCount)
            let scale = buffer.format.sampleRate / 16_000
            for index in 0..<outputCount {
                let position = Double(index) * scale
                let lower = min(Int(position), Int(buffer.frameLength) - 1)
                let upper = min(lower + 1, Int(buffer.frameLength) - 1)
                let fraction = Float(position - Double(lower))
                let sample = channel[lower] + (channel[upper] - channel[lower]) * fraction
                samples[index] = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            }

            self.preRoll.append(samples)
            if self.preRoll.count > 5 { self.preRoll.removeFirst() }

            if !self.localAudioActive {
                guard rms >= 0.006 else { return }
                self.localAudioActive = true
                self.silentFrameCount = 0
                self.sendPacket(type: 5, payload: Data([1]))
                for buffered in self.preRoll { self.sendAudio(buffered, through: connection) }
                self.preRoll.removeAll(keepingCapacity: true)
                return
            }

            self.sendAudio(samples, through: connection)
            if rms < 0.003 {
                self.silentFrameCount += 1
                if self.silentFrameCount >= 30 {
                    self.localAudioActive = false
                    self.silentFrameCount = 0
                    self.preRoll.removeAll(keepingCapacity: true)
                    self.sendPacket(type: 5, payload: Data([0]))
                }
            } else {
                self.silentFrameCount = 0
            }
        }
        tapInstalled = true
    }

    private func sendAudio(_ samples: [Int16], through connection: NWConnection) {
        var body = Data([0])
        var packetSequence = sequence.bigEndian
        sequence &+= 1
        body.append(Data(bytes: &packetSequence, count: 4))
        samples.withUnsafeBytes { body.append(contentsOf: $0) }
        var length = UInt16(body.count).bigEndian
        var packet = Data(bytes: &length, count: 2)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.resetConnection() } }
        })
    }

    private func sendPacket(type: UInt8, payload: Data = Data()) {
        guard let connection, connected else { return }
        if type == 4 && (localAudioActive || remoteAudioActive) { return }
        var body = Data([type])
        var packetSequence = sequence.bigEndian
        sequence &+= 1
        body.append(Data(bytes: &packetSequence, count: 4))
        body.append(payload)
        guard body.count <= Int(UInt16.max) else { return }
        var length = UInt16(body.count).bigEndian
        var packet = Data(bytes: &length, count: 2)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.resetConnection() } }
        })
    }

    private func sendIdentity() {
        guard let data = try? JSONEncoder().encode(Identity(id: deviceID, name: deviceName, colorIndex: deviceColorIndex)) else { return }
        sendPacket(type: 3, payload: data)
    }

    private func resetConnection() {
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        connected = false
        remoteAudioActive = false
        localAudioActive = false
        applyingRemoteCallState = true
        callActive = false
        applyingRemoteCallState = false
        receivedData.removeAll(keepingCapacity: true)
        peerEndpoint = nil
        browser?.cancel()
        browser = nil
        remoteDevices.removeAll()
        sentLocationCount = 0
        lastLocationSync = .distantPast
        preRoll.removeAll(keepingCapacity: true)
        silentFrameCount = 0
        audioBuffer.withLock { state in
            state.readIndex = 0
            state.writeIndex = 0
            state.count = 0
        }
        status = "Szukam drugiego urządzenia…"
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
                    self.lastReceived = Date()
                    self.browser?.cancel()
                    self.browser = nil
                    self.status = "Połączono"
                    self.sendIdentity()
                    self.updateCapture()
                case .failed(let error):
                    self.status = "Rozłączono: \(error.localizedDescription)"
                    self.resetConnection()
                case .cancelled:
                    self.resetConnection()
                default: break
                }
            }
        }
        newConnection.start(queue: .main)

        func receive() {
            newConnection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak newConnection] data, _, complete, error in
                guard let self, let newConnection, self.connection === newConnection else { return }
                if let data {
                    self.lastReceived = Date()
                    self.receivedData.append(data)
                    while self.receivedData.count >= 2 {
                        let length = self.receivedData.prefix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
                        guard self.receivedData.count >= 2 + Int(length) else { break }
                        let packet = self.receivedData.subdata(in: 2..<(2 + Int(length)))
                        self.receivedData.removeSubrange(0..<(2 + Int(length)))
                        guard packet.count >= 5 else { continue }
                        let type = packet[packet.startIndex]
                        let payload = packet.dropFirst(5)

                        if type == 0 {
                            self.audioBuffer.withLock { state in
                                payload.withUnsafeBytes { raw in
                                    let input = raw.bindMemory(to: Int16.self)
                                    var squareSum: Float = 0
                                    for sample in input {
                                        let value = Float(Int16(littleEndian: sample)) / Float(Int16.max)
                                        squareSum += value * value
                                    }
                                    let rms = sqrt(squareSum / Float(max(1, input.count)))
                                    let gain = rms > 0.0001 ? min(45, max(2.2, 0.45 / rms)) : 1
                                    for sample in input {
                                        let value = Float(Int16(littleEndian: sample)) / Float(Int16.max)
                                        let amplified = tanh(value * gain * 1.3)
                                        if state.count == state.samples.count {
                                            state.readIndex = (state.readIndex + 1) % state.samples.count
                                            state.count -= 1
                                        }
                                        state.samples[state.writeIndex] = amplified
                                        state.writeIndex = (state.writeIndex + 1) % state.samples.count
                                        state.count += 1
                                    }
                                }
                            }
                        } else if type == 3, let identity = try? JSONDecoder().decode(Identity.self, from: Data(payload)) {
                            if let index = self.remoteDevices.firstIndex(where: { $0.id == identity.id }) {
                                self.remoteDevices[index].name = identity.name
                                self.remoteDevices[index].colorIndex = identity.colorIndex
                            } else {
                                self.remoteDevices.append(ConnectedDevice(id: identity.id, name: identity.name, colorIndex: identity.colorIndex, locations: []))
                            }
                        } else if type == 4, let update = try? JSONDecoder().decode(LocationUpdate.self, from: Data(payload)) {
                            if let index = self.remoteDevices.firstIndex(where: { $0.id == update.id }) {
                                let known = Set(self.remoteDevices[index].locations.map(\.id))
                                self.remoteDevices[index].locations.append(contentsOf: update.points.filter { !known.contains($0.id) })
                                if self.remoteDevices[index].locations.count > 300 {
                                    self.remoteDevices[index].locations.removeFirst(self.remoteDevices[index].locations.count - 300)
                                }
                            }
                        } else if type == 5, let value = payload.first {
                            self.remoteAudioActive = value == 1
                        } else if type == 6, let value = payload.first {
                            DispatchQueue.main.async {
                                self.applyingRemoteCallState = true
                                self.callActive = value == 1
                                if self.callActive { self.mode = .call }
                                self.applyingRemoteCallState = false
                            }
                        }
                    }
                }
                if complete || error != nil {
                    DispatchQueue.main.async {
                        guard self.connection === newConnection else { return }
                        self.resetConnection()
                    }
                } else {
                    receive()
                }
            }
        }
        receive()
    }
}
