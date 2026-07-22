import AVFoundation
import Network
import UIKit

final class WalkieTalkie: ObservableObject {
    @Published var status = "Szukam drugiego iPhone’a…"
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
    private var connected = false
    private var microphoneReady = false
    private var tapInstalled = false
    private var queuedBuffers = 0
    private var sequence: UInt32 = 0
    private let peerName = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

    init() {
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
                    try session.setPreferredIOBufferDuration(0.01)
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
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            listener = try NWListener(using: parameters)
            listener?.service = NWListener.Service(name: peerName, type: "_offlinewalkie._udp")
            listener?.newConnectionHandler = { [weak self] newConnection in
                DispatchQueue.main.async {
                    self?.use(newConnection)
                }
            }
            listener?.start(queue: .main)
        } catch {
            status = "Błąd nasłuchiwania: \(error.localizedDescription)"
        }

        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_offlinewalkie._udp", domain: nil), using: parameters)
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil else { return }

            for result in results {
                if case let .service(name, _, _, _) = result.endpoint, self.peerName < name {
                    self.use(NWConnection(to: result.endpoint, using: parameters))
                    break
                }
            }
        }
        browser?.start(queue: .main)
    }

    private func use(_ newConnection: NWConnection) {
        guard connection == nil else {
            newConnection.cancel()
            return
        }

        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.connected = true
                    self?.status = "Połączono — UDP, 16 kHz"
                case .failed(let error):
                    self?.connected = false
                    self?.status = "Rozłączono: \(error.localizedDescription)"
                    self?.connection = nil
                case .cancelled:
                    self?.connected = false
                    self?.status = "Szukam drugiego iPhone’a…"
                    self?.connection = nil
                default:
                    break
                }
            }
        }
        newConnection.start(queue: .main)

        func receive() {
            newConnection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }

                if let data, data.count > 4 {
                    let audio = data.dropFirst(4)
                    let frameCount = AVAudioFrameCount(audio.count / MemoryLayout<Int16>.size)

                    if frameCount > 0,
                       let inputBuffer = AVAudioPCMBuffer(pcmFormat: self.networkFormat, frameCapacity: frameCount),
                       let inputSamples = inputBuffer.int16ChannelData?[0],
                       let outputBuffer = AVAudioPCMBuffer(pcmFormat: self.playbackFormat, frameCapacity: frameCount),
                       let outputSamples = outputBuffer.floatChannelData?[0] {
                        inputBuffer.frameLength = frameCount
                        outputBuffer.frameLength = frameCount
                        audio.copyBytes(to: UnsafeMutableRawBufferPointer(
                            start: inputSamples,
                            count: Int(frameCount) * MemoryLayout<Int16>.size
                        ))

                        var squareSum: Float = 0
                        for index in 0..<Int(frameCount) {
                            let sample = Float(inputSamples[index]) / Float(Int16.max)
                            outputSamples[index] = sample
                            squareSum += sample * sample
                        }

                        let rms = sqrt(squareSum / Float(frameCount))
                        let gain = rms > 0.0001 ? min(50, max(2.5, 0.34 / rms)) : 1
                        for index in 0..<Int(frameCount) {
                            outputSamples[index] = tanh(outputSamples[index] * gain * 1.15)
                        }

                        if self.queuedBuffers >= 8 {
                            self.player.stop()
                            self.queuedBuffers = 0
                            self.player.play()
                        }
                        if !self.player.isPlaying {
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

                if error != nil {
                    DispatchQueue.main.async {
                        self.connected = false
                        self.connection = nil
                        self.status = "Szukam drugiego iPhone’a…"
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

        converter.sampleRateConverterQuality = 32
        input.installTap(onBus: 0, bufferSize: 480, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let capacity = AVAudioFrameCount(
                (Double(buffer.frameLength) * self.networkFormat.sampleRate / inputFormat.sampleRate).rounded(.up)
            ) + 8
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: self.networkFormat,
                frameCapacity: capacity
            ) else { return }

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

            var packetSequence = self.sequence.bigEndian
            self.sequence &+= 1
            var packet = Data(bytes: &packetSequence, count: 4)
            packet.append(Data(
                bytes: samples,
                count: Int(converted.frameLength) * MemoryLayout<Int16>.size
            ))

            connection.send(
                content: packet,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
        tapInstalled = true
    }
}
