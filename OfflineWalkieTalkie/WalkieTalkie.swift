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
                silentSamples = 0
                sendingVoice = false
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let networkFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
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
    private var playbackData = Data()
    private var connected = false
    private var microphoneReady = false
    private var tapInstalled = false
    private var queuedBuffers = 0
    private var silentSamples = 0
    private var sendingVoice = false
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
                        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
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
        playbackData.removeAll(keepingCapacity: true)
        queuedBuffers = 0
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
                    self.status = "Połączono — ramki 5 ms"
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

                        let type = packet[packet.startIndex]
                        if type == 2 {
                            continue
                        }
                        if type == 1 {
                            self.playbackData.removeAll(keepingCapacity: true)
                            self.player.stop()
                            self.queuedBuffers = 0
                            self.player.play()
                            continue
                        }

                        self.playbackData.append(packet.dropFirst(5))

                        // 20 ms at 16 kHz mono Int16 = 320 samples = 640 bytes.
                        while self.playbackData.count >= 640 {
                            let audio = self.playbackData.prefix(640)
                            self.playbackData.removeFirst(640)

                            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: self.networkFormat, frameCapacity: 320),
                                  let inputSamples = inputBuffer.int16ChannelData?[0],
                                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: self.playbackFormat, frameCapacity: 320),
                                  let outputSamples = outputBuffer.floatChannelData?[0]
                            else { continue }

                            inputBuffer.frameLength = 320
                            outputBuffer.frameLength = 320
                            audio.copyBytes(to: UnsafeMutableRawBufferPointer(
                                start: inputSamples,
                                count: 640
                            ))

                            var squareSum: Float = 0
                            for index in 0..<320 {
                                let sample = Float(inputSamples[index]) / Float(Int16.max)
                                outputSamples[index] = sample
                                squareSum += sample * sample
                            }

                            let rms = sqrt(squareSum / 320)
                            let gain = rms > 0.0001 ? min(65, max(3.5, 0.44 / rms)) : 1
                            for index in 0..<320 {
                                outputSamples[index] = tanh(outputSamples[index] * gain * 1.3)
                            }

                            // Keep at most about 100 ms. If we fall behind, discard
                            // the old queued audio and immediately continue with the newest block.
                            if self.queuedBuffers >= 5 {
                                self.player.stop()
                                self.queuedBuffers = 0
                                self.player.play()
                            } else if !self.player.isPlaying {
                                self.player.play()
                            }

                            self.queuedBuffers += 1
                            self.player.scheduleBuffer(
                                outputBuffer,
                                completionCallbackType: .dataPlayedBack
                            ) { [weak self] _ in
                                DispatchQueue.main.async {
                                    guard let self else { return }
                                    self.queuedBuffers = max(0, self.queuedBuffers - 1)
                                }
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
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: networkFormat)
        else {
            status = "Brak aktywnego wejścia mikrofonowego"
            isTalking = false
            return
        }

        converter.sampleRateConverterQuality = 16
        input.installTap(onBus: 0, bufferSize: 240, format: inputFormat) { [weak self, weak connection] buffer, _ in
            guard let self, let connection, self.connection === connection else { return }

            let capacity = AVAudioFrameCount(
                (Double(buffer.frameLength) * self.networkFormat.sampleRate / inputFormat.sampleRate).rounded(.up)
            ) + 8
            guard let converted = AVAudioPCMBuffer(pcmFormat: self.networkFormat, frameCapacity: capacity) else { return }

            var supplied = false
            var conversionError: NSError?
            let result = converter.convert(to: converted, error: &conversionError) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }

            guard result != .error,
                  conversionError == nil,
                  converted.frameLength > 0,
                  let samples = converted.int16ChannelData?[0]
            else { return }

            var squareSum: Float = 0
            for index in 0..<Int(converted.frameLength) {
                let sample = Float(samples[index]) / Float(Int16.max)
                squareSum += sample * sample
            }
            let rms = sqrt(squareSum / Float(converted.frameLength))

            if rms < 0.012 {
                self.silentSamples += Int(converted.frameLength)

                if self.sendingVoice, self.silentSamples >= 3_200 {
                    self.sendingVoice = false
                    var packetSequence = self.sequence.bigEndian
                    self.sequence &+= 1
                    var body = Data([1])
                    body.append(Data(bytes: &packetSequence, count: 4))
                    var length = UInt16(body.count).bigEndian
                    var packet = Data(bytes: &length, count: 2)
                    packet.append(body)
                    connection.send(content: packet, completion: .contentProcessed { _ in })
                }
                return
            }

            self.silentSamples = 0
            self.sendingVoice = true

            var packetSequence = self.sequence.bigEndian
            self.sequence &+= 1
            var body = Data([0])
            body.append(Data(bytes: &packetSequence, count: 4))
            body.append(Data(
                bytes: samples,
                count: Int(converted.frameLength) * MemoryLayout<Int16>.size
            ))
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
