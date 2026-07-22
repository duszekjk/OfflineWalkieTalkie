import AVFoundation
import Network
import UIKit

final class WalkieTalkie: ObservableObject {
    @Published var status = "Szukam drugiego iPhone’a…"
    @Published var isTalking = false {
        didSet {
            if isTalking {
                startTalking()
            } else {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receivedData = Data()
    private var connected = false
    private let peerName = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

    init() {
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: nil)
        audioEngine.mainMixerNode.outputVolume = 1

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            try audioEngine.start()
            player.play()
        } catch {
            status = "Błąd audio: \(error.localizedDescription)"
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

                        let audio = self.receivedData.subdata(in: 4..<(4 + Int(length)))
                        self.receivedData.removeSubrange(0..<(4 + Int(length)))

                        let format = self.audioEngine.inputNode.inputFormat(forBus: 0)
                        let frameCount = AVAudioFrameCount(audio.count / MemoryLayout<Float>.size)
                        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
                            buffer.frameLength = frameCount
                            if let samples = buffer.floatChannelData?[0] {
                                audio.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: audio.count))
                                for index in 0..<Int(frameCount) {
                                    samples[index] = max(-1, min(1, samples[index] * 1.8))
                                }
                                self.player.scheduleBuffer(buffer)
                            }
                        }
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

        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }

            let audio = Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
            var length = UInt32(audio.count).bigEndian
            var packet = Data(bytes: &length, count: 4)
            packet.append(audio)
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }
}
