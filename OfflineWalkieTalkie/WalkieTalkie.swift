import AVFoundation
import Network
import UIKit

final class WalkieTalkie: ObservableObject {
    @Published var status = "Szukam drugiego urządzenia…"
    @Published var isTalking = false {
        didSet {
            if isTalking {
                startTalking()
            } else if tapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var peerEndpoint: NWEndpoint?
    private var receivedData = Data()
    private var connected = false
    private var microphoneReady = false
    private var tapInstalled = false
    private var sequence: UInt32 = 0
    private var lastReceived = Date()
    private var reconnectTimer: Timer?
    private let peerName = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    private let parameters: NWParameters

    init() {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true

        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: playbackFormat)
        player.volume = 1
        audioEngine.mainMixerNode.outputVolume = 1

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.status = "Brak dostępu do mikrofonu"
                    return
                }

                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(
                        .playAndRecord,
                        mode: .videoChat,
                        options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
                    )
                    try session.setPreferredSampleRate(48_000)
                    try session.setPreferredIOBufferDuration(0.005)
                    try session.setActive(true)

                    _ = self.audioEngine.inputNode
                    self.audioEngine.prepare()
                    try self.audioEngine.start()
                    self.player.play()
                    self.microphoneReady = true
                } catch {
                    self.status = "Błąd audio: \(error.localizedDescription)"
                }
            }
        }

        do {
            listener = try NWListener(using: parameters)
            listener?.service = NWListener.Service(name: peerName, type: "_offlinewalkie._tcp")
            listener?.newConnectionHandler = { [weak self] newConnection in
                DispatchQueue.main.async {
                    self?.use(newConnection)
                }
            }
            listener?.start(queue: .main)
        } catch {
            status = "Błąd nasłuchiwania: \(error.localizedDescription)"
        }

        browser = NWBrowser(for: .bonjour(type: "_offlinewalkie._tcp", domain: nil), using: parameters)
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }

            self.peerEndpoint = nil
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint, self.peerName < name {
                    self.peerEndpoint = result.endpoint
                    if self.connection == nil {
                        self.use(NWConnection(to: result.endpoint, using: self.parameters))
                    }
                    break
                }
            }
        }
        browser?.start(queue: .main)

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }

            if self.connected {
                if Date().timeIntervalSince(self.lastReceived) > 4 {
                    self.resetConnection()
                    return
                }

                var body = Data([2])
                var packetSequence = self.sequence.bigEndian
                self.sequence &+= 1
                body.append(Data(bytes: &packetSequence, count: 4))
                var length = UInt16(body.count).bigEndian
                var packet = Data(bytes: &length, count: 2)
                packet.append(body)
                self.connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        DispatchQueue.main.async {
                            self?.resetConnection()
                        }
                    }
                })
            } else if self.connection == nil, let peerEndpoint = self.peerEndpoint {
                self.use(NWConnection(to: peerEndpoint, using: self.parameters))
            }
        }
    }

    deinit {
        reconnectTimer?.invalidate()
    }

    private func resetConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        connected = false
        receivedData.removeAll(keepingCapacity: true)
        player.stop()
        player.play()
        status = "Szukam drugiego urządzenia…"
    }

    private func use(_ newConnection: NWConnection) {
        guard connection == nil else {
            newConnection.cancel()
            return
        }

        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            DispatchQueue.main.async {
                guard let self, let newConnection, self.connection === newConnection else { return }

                switch state {
                case .ready:
                    self.connected = true
                    self.lastReceived = Date()
                    self.status = "Połączono — 16 kHz"
                case .failed(let error):
                    self.status = "Rozłączono: \(error.localizedDescription)"
                    self.resetConnection()
                case .cancelled:
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
                    self.lastReceived = Date()
                    self.receivedData.append(data)

                    while self.receivedData.count >= 2 {
                        let length = self.receivedData.prefix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
                        guard self.receivedData.count >= 2 + Int(length) else { break }

                        let packet = self.receivedData.subdata(in: 2..<(2 + Int(length)))
                        self.receivedData.removeSubrange(0..<(2 + Int(length)))
                        guard packet.count >= 5 else { continue }
                        if packet[packet.startIndex] == 2 { continue }

                        let audio = packet.dropFirst(5)
                        let frameCount = AVAudioFrameCount(audio.count / MemoryLayout<Int16>.size)
                        guard frameCount > 0,
                              let buffer = AVAudioPCMBuffer(pcmFormat: self.playbackFormat, frameCapacity: frameCount),
                              let output = buffer.floatChannelData?[0]
                        else { continue }

                        buffer.frameLength = frameCount
                        audio.withUnsafeBytes { rawBuffer in
                            let input = rawBuffer.bindMemory(to: Int16.self)
                            var squareSum: Float = 0
                            for index in 0..<Int(frameCount) {
                                let sample = Float(Int16(littleEndian: input[index])) / Float(Int16.max)
                                output[index] = sample
                                squareSum += sample * sample
                            }

                            let rms = sqrt(squareSum / Float(frameCount))
                            let gain = rms > 0.0001 ? min(45, max(2.2, 0.45 / rms)) : 1
                            for index in 0..<Int(frameCount) {
                                output[index] = tanh(output[index] * gain * 1.3)
                            }
                        }

                        if !self.player.isPlaying {
                            self.player.play()
                        }
                        self.player.scheduleBuffer(buffer)
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

    private func startTalking() {
        guard let connection, connected else {
            status = "Brak połączenia z drugim urządzeniem"
            isTalking = false
            return
        }

        guard microphoneReady else {
            status = "Mikrofon nie jest jeszcze gotowy"
            isTalking = false
            return
        }

        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
                player.play()
            }
        } catch {
            status = "Błąd mikrofonu: \(error.localizedDescription)"
            isTalking = false
            return
        }

        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = "Brak aktywnego wejścia mikrofonowego"
            isTalking = false
            return
        }

        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(format.sampleRate * 0.02),
            format: format
        ) { [weak self, weak connection] buffer, _ in
            guard let self,
                  let connection,
                  self.connection === connection,
                  let channel = buffer.floatChannelData?[0]
            else { return }

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

            var body = Data([0])
            var packetSequence = self.sequence.bigEndian
            self.sequence &+= 1
            body.append(Data(bytes: &packetSequence, count: 4))
            samples.withUnsafeBytes { body.append(contentsOf: $0) }

            var length = UInt16(body.count).bigEndian
            var packet = Data(bytes: &length, count: 2)
            packet.append(body)
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    DispatchQueue.main.async {
                        self?.resetConnection()
                    }
                }
            })
        }
        tapInstalled = true
    }
}
