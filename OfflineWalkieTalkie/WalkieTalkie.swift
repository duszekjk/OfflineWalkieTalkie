import AVFoundation
import Network
import UIKit
import os

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

    private struct AudioBufferState {
        var samples = [Float](repeating: 0, count: 3_200)
        var readIndex = 0
        var writeIndex = 0
        var count = 0
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

        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: playbackFormat)
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
                return
            }

            if self.connection == nil, let peerEndpoint = self.peerEndpoint {
                self.use(NWConnection(to: peerEndpoint, using: self.parameters))
                return
            }

            guard self.browser == nil else { return }

            let browser = NWBrowser(
                for: .bonjour(type: "_offlinewalkie._tcp", domain: nil),
                using: self.parameters
            )
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                DispatchQueue.main.async {
                    guard let self, let browser, self.browser === browser else { return }

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

    deinit {
        reconnectTimer?.invalidate()
    }

    private func resetConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        connected = false
        receivedData.removeAll(keepingCapacity: true)
        peerEndpoint = nil
        browser?.cancel()
        browser = nil
        audioBuffer.withLock { state in
            state.readIndex = 0
            state.writeIndex = 0
            state.count = 0
        }
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
                    self.browser?.cancel()
                    self.browser = nil
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
                        self.audioBuffer.withLock { state in
                            audio.withUnsafeBytes { rawBuffer in
                                let input = rawBuffer.bindMemory(to: Int16.self)
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
