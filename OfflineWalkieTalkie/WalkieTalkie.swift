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
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receivedData = Data()
    private var connected = false
    private var microphoneReady = false
    private var tapInstalled = false
    private let peerName = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

    init() {
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: playbackFormat)
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
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
                    try session.setPreferredSampleRate(48_000)
                    try session.setPreferredIOBufferDuration(0.02)
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
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
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

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_offlinewalkie._tcp", domain: nil), using: parameters)
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
                    self?.status = "Połączono"
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
            newConnection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                guard let self else { return }

                if let data {
                    self.receivedData.append(data)

                    while self.receivedData.count >= 4 {
                        let length = self.receivedData.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        guard self.receivedData.count >= 4 + Int(length) else { break }

                        let packet = self.receivedData.subdata(in: 4..<(4 + Int(length)))
                        self.receivedData.removeSubrange(0..<(4 + Int(length)))
                        guard packet.count > 4 else { continue }

                        let sampleRate = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        let audio = packet.dropFirst(4)
                        let frameCount = AVAudioFrameCount(audio.count / MemoryLayout<Float>.size)

                        guard sampleRate > 0,
                              frameCount > 0,
                              let sourceFormat = AVAudioFormat(
                                commonFormat: .pcmFormatFloat32,
                                sampleRate: Double(sampleRate),
                                channels: 1,
                                interleaved: false
                              ),
                              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
                        else { continue }

                        sourceBuffer.frameLength = frameCount
                        guard let sourceSamples = sourceBuffer.floatChannelData?[0] else { continue }
                        audio.copyBytes(to: UnsafeMutableRawBufferPointer(start: sourceSamples, count: audio.count))

                        let ratio = self.playbackFormat.sampleRate / sourceFormat.sampleRate
                        let outputCapacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up)) + 1
                        guard let outputBuffer = AVAudioPCMBuffer(
                            pcmFormat: self.playbackFormat,
                            frameCapacity: outputCapacity
                        ) else { continue }

                        if sourceFormat.sampleRate == self.playbackFormat.sampleRate {
                            outputBuffer.frameLength = frameCount
                            guard let outputSamples = outputBuffer.floatChannelData?[0] else { continue }
                            for index in 0..<Int(frameCount) {
                                outputSamples[index] = max(-1, min(1, sourceSamples[index] * 1.8))
                            }
                        } else {
                            guard let converter = AVAudioConverter(from: sourceFormat, to: self.playbackFormat) else { continue }
                            var supplied = false
                            var conversionError: NSError?
                            let result = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
                                if supplied {
                                    status.pointee = .endOfStream
                                    return nil
                                }
                                supplied = true
                                status.pointee = .haveData
                                return sourceBuffer
                            }
                            guard result != .error, conversionError == nil,
                                  let outputSamples = outputBuffer.floatChannelData?[0]
                            else { continue }
                            for index in 0..<Int(outputBuffer.frameLength) {
                                outputSamples[index] = max(-1, min(1, outputSamples[index] * 1.8))
                            }
                        }

                        if !self.player.isPlaying {
                            self.player.play()
                        }
                        self.player.scheduleBuffer(outputBuffer)
                    }
                }

                if complete || error != nil {
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
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = "Brak aktywnego wejścia mikrofonowego"
            isTalking = false
            return
        }

        input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }

            let audio = Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
            var sampleRate = UInt32(buffer.format.sampleRate.rounded()).bigEndian
            var body = Data(bytes: &sampleRate, count: 4)
            body.append(audio)

            var length = UInt32(body.count).bigEndian
            var packet = Data(bytes: &length, count: 4)
            packet.append(body)
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
        tapInstalled = true
    }
}
