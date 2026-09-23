//
//  StikServerRelay.swift
//  StikDebug
//

import Foundation
import UIKit

@MainActor
final class StikServerRelay: NSObject, ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var title: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var state: State = .disconnected

    private weak var controller: NearbyRemoteControlModel?
    private var device: NearbyDevelopmentDevice?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var frameTimer: Timer?
    private weak var lastImage: UIImage?
    private var isSendingFrame = false
    private var generation = 0

    func connect(
        serverAddress: String,
        token: String,
        device: NearbyDevelopmentDevice,
        controller: NearbyRemoteControlModel
    ) {
        disconnect()
        guard let url = Self.webSocketURL(from: serverAddress, token: token) else {
            state = .failed("Invalid server address")
            return
        }

        generation += 1
        let generation = generation
        self.controller = controller
        self.device = device
        state = .connecting

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        receiveTask = Task { [weak self, weak task] in
            guard let self, let task else { return }
            do {
                try await task.send(.string(Self.registration(for: device)))
                guard self.generation == generation else { return }
                self.state = .connected
                self.startFrameTimer(generation: generation)
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard self.generation == generation else { return }
                    self.handle(message)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation else { return }
                self.stopTransport()
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        generation += 1
        stopTransport()
        controller = nil
        device = nil
        state = .disconnected
    }

    private func stopTransport() {
        frameTimer?.invalidate()
        frameTimer = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        lastImage = nil
        isSendingFrame = false
    }

    private func startFrameTimer(generation: Int) {
        frameTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendLatestFrame(generation: generation) }
        }
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sendLatestFrame(generation: Int) {
        guard generation == self.generation,
              !isSendingFrame,
              let task,
              let controller,
              let image = controller.video.image,
              image !== lastImage else { return }
        lastImage = image
        isSendingFrame = true
        let orientation = controller.orientation

        let relay = self
        Task.detached(priority: .userInitiated) { [weak relay, weak task] in
            let data = Self.jpegData(for: image, orientation: orientation)
            do {
                if let data, let task { try await task.send(.data(data)) }
                await relay?.finishFrame(generation: generation, error: nil)
            } catch {
                await relay?.finishFrame(generation: generation, error: error)
            }
        }
    }

    private func finishFrame(generation: Int, error: Error?) {
        guard self.generation == generation else { return }
        isSendingFrame = false
        if let error {
            stopTransport()
            state = .failed(error.localizedDescription)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "command",
              let command = object["command"] as? String,
              let controller else { return }

        switch command {
        case "home": controller.press(.home)
        case "lock": controller.press(.lock)
        case "volumeUp": controller.press(.volumeUp)
        case "volumeDown": controller.press(.volumeDown)
        case "mute": controller.press(.mute)
        case "siri": controller.press(.siri)
        case "softwareKeyboard": controller.toggleSoftwareKeyboard()
        case "touch":
            guard let x = object["x"] as? Double,
                  let y = object["y"] as? Double,
                  let phaseName = object["phase"] as? String,
                  let phase = Self.touchPhase(named: phaseName) else { return }
            let point = Self.devicePoint(x: x, y: y, orientation: controller.orientation)
            controller.touch(phase, x: point.x, y: point.y)
        default: break
        }
    }

    private static func webSocketURL(from value: String, token: String) -> URL? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              var components = URLComponents(string: normalized.contains("://") ? normalized : "http://\(normalized)") else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        components.path = "/agent"
        components.queryItems = token.isEmpty ? nil : [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    private static func registration(for device: NearbyDevelopmentDevice) -> String {
        let payload: [String: Any] = [
            "type": "register",
            "device": [
                "id": device.id,
                "name": device.name,
                "kind": device.kind
            ]
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func touchPhase(named name: String) -> RemoteTouchPhase? {
        switch name {
        case "down": return .down
        case "move": return .move
        case "up": return .up
        default: return nil
        }
    }

    private static func devicePoint(
        x: Double,
        y: Double,
        orientation: RemoteScreenOrientation
    ) -> (x: UInt16, y: UInt16) {
        let displayX = min(max(x, 0), 1)
        let displayY = min(max(y, 0), 1)
        let point: (Double, Double) = switch orientation {
        case .portrait, .unknown: (displayX, displayY)
        case .portraitUpsideDown: (1 - displayX, 1 - displayY)
        case .landscapeRight: (displayY, 1 - displayX)
        case .landscapeLeft: (1 - displayY, displayX)
        }
        return (
            UInt16((point.0 * Double(UInt16.max)).rounded()),
            UInt16((point.1 * Double(UInt16.max)).rounded())
        )
    }

    nonisolated private static func jpegData(
        for image: UIImage,
        orientation: RemoteScreenOrientation
    ) -> Data? {
        guard let cgImage = image.cgImage else { return image.jpegData(compressionQuality: 0.65) }
        let imageOrientation: UIImage.Orientation = switch orientation {
        case .portrait, .unknown: .up
        case .portraitUpsideDown: .down
        case .landscapeRight: .right
        case .landscapeLeft: .left
        }
        let oriented = UIImage(cgImage: cgImage, scale: 1, orientation: imageOrientation)
        let maximumDimension: CGFloat = 1_280
        let scale = min(1, maximumDimension / max(oriented.size.width, oriented.size.height))
        let size = CGSize(width: oriented.size.width * scale, height: oriented.size.height * scale)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            oriented.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.65)
    }
}
