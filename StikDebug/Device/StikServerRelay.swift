//
//  StikServerRelay.swift
//  StikDebug
//

import Foundation
import UIKit
import Combine
import idevice

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
    private var ownedController: NearbyRemoteControlModel?
    private var device: NearbyDevelopmentDevice?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var frameTimer: Timer?
    private weak var lastImage: UIImage?
    private var isSendingFrame = false
    private var generation = 0
    private var isSubscribed = false
    private var commandExecutor: StikServerRelayCommandExecutor?
    private var reconnectTask: Task<Void, Never>?
    private var serverAddress = ""
    private var accessToken = ""

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
        self.serverAddress = serverAddress
        accessToken = token
        commandExecutor = StikServerRelayCommandExecutor(device: device)
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
                self.scheduleReconnect(after: generation)
            }
        }
    }

    /// Advertises a paired nearby device without opening its screen stream.
    /// StikServer explicitly subscribes when a viewer presses View Screen.
    func connect(serverAddress: String, token: String, device: NearbyDevelopmentDevice) {
        let controller = NearbyRemoteControlModel()
        connect(serverAddress: serverAddress, token: token, device: device, controller: controller)
        ownedController = controller
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        generation += 1
        stopTransport()
        controller = nil
        ownedController = nil
        device = nil
        commandExecutor = nil
        isSubscribed = false
        state = .disconnected
    }

    private func scheduleReconnect(after failedGeneration: Int) {
        guard let device, !serverAddress.isEmpty else { return }
        let address = serverAddress
        let token = accessToken
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.generation == failedGeneration else { return }
            self.connect(serverAddress: address, token: token, device: device)
        }
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
        isSubscribed = false
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
              isSubscribed,
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
              let type = object["type"] as? String else { return }

        if type == "subscribe" {
            beginSubscription()
            return
        }
        if type == "unsubscribe" {
            endSubscription()
            return
        }
        guard type == "command", let command = object["command"] as? String else { return }
        let controlCommands: Set<String> = [
            "home", "lock", "volumeUp", "volumeDown", "mute", "siri",
            "softwareKeyboard", "rotateLeft", "rotateRight", "backspace", "text", "touch"
        ]
        if controlCommands.contains(command) { ensureControllerIsConnected() }
        guard let controller else { return }
        if controlCommands.contains(command), controller.connectedDeviceName == nil {
            Task { [weak self, weak controller] in
                for _ in 0..<100 {
                    guard let self, let controller, self.task != nil else { return }
                    if controller.connectedDeviceName != nil {
                        self.runControlCommand(command, object: object, controller: controller)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                self.sendRelayError(command: command, message: "The relayed device did not connect in time")
            }
            return
        }
        if controlCommands.contains(command) {
            runControlCommand(command, object: object, controller: controller)
            return
        }
        executeDeviceCommand(object)
    }

    private func runControlCommand(
        _ command: String,
        object: [String: Any],
        controller: NearbyRemoteControlModel
    ) {
        switch command {
        case "home": controller.press(.home)
        case "lock": controller.press(.lock)
        case "volumeUp": controller.press(.volumeUp)
        case "volumeDown": controller.press(.volumeDown)
        case "mute": controller.press(.mute)
        case "siri": controller.press(.siri)
        case "softwareKeyboard": controller.toggleSoftwareKeyboard()
        case "rotateLeft": controller.rotate(.left)
        case "rotateRight": controller.rotate(.right)
        case "backspace": controller.backspace()
        case "text":
            guard let text = object["text"] as? String, !text.isEmpty else { return }
            controller.type(String(text.prefix(2_000)))
        case "touch":
            guard let x = object["x"] as? Double,
                  let y = object["y"] as? Double,
                  let phaseName = object["phase"] as? String,
                  let phase = Self.touchPhase(named: phaseName) else { return }
            let point = Self.devicePoint(x: x, y: y, orientation: controller.orientation)
            controller.touch(phase, x: point.x, y: point.y)
        default: break
        }
        if !isSubscribed, ownedController != nil {
            Task { [weak self, weak controller] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !self.isSubscribed else { return }
                controller?.stopMirroring()
            }
        }
    }

    private func executeDeviceCommand(_ command: [String: Any]) {
        guard let commandExecutor else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if let event = try commandExecutor.execute(command) {
                    await self?.sendDeviceEvent(event)
                }
            } catch {
                let name = command["command"] as? String ?? "unknown"
                await self?.sendRelayError(command: name, message: error.localizedDescription)
            }
        }
    }

    private func sendDeviceEvent(_ event: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: ["type": "deviceEvent", "event": event]),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await task.send(.string(text)) }
    }

    private func sendRelayError(command: String, message: String) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: [
                "type": "relayError", "command": command, "message": message
              ]),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await task.send(.string(text)) }
    }

    private func beginSubscription() {
        isSubscribed = true
        ensureControllerIsConnected()
        startFrameTimer(generation: generation)
    }

    private func endSubscription() {
        isSubscribed = false
        frameTimer?.invalidate()
        frameTimer = nil
        lastImage = nil
        if ownedController != nil { controller?.stopMirroring() }
    }

    private func ensureControllerIsConnected() {
        guard let controller, let device, !controller.isMirroring else { return }
        controller.startMirroring(to: device)
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
                "kind": device.kind,
                "modelIdentifier": device.modelIdentifier ?? "",
                "serviceIdentifier": device.serviceIdentifier,
                "pairingIdentifier": device.deviceIdentifier ?? "",
                "paired": true,
                "routeHops": 1
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

private final class StikServerRelayCommandExecutor: @unchecked Sendable {
    private let context: JITEnableContext
    private let target: DeviceConnectionSnapshot
    private let lock = NSLock()
    private var locationClient: OpaquePointer?

    init(device: NearbyDevelopmentDevice) {
        target = DeviceConnectionSnapshot(
            id: device.id,
            displayName: device.name,
            addresses: device.addresses,
            pairingFileURL: device.pairingFileURL!,
            isRemote: true,
            stikServer: nil
        )
        context = JITEnableContext(target: target)
    }

    deinit {
        if let locationClient { location_simulation_free(locationClient) }
    }

    func execute(_ message: [String: Any]) throws -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let command = message["command"] as? String else { return nil }
        switch command {
        case "processes":
            let processes = try context.fetchProcessList().map { raw -> [String: Any] in
                let path = raw["path"] as? String ?? "Unknown"
                return [
                    "pid": raw["pid"] ?? 0,
                    "name": path,
                    "realAppName": URL(fileURLWithPath: path).lastPathComponent,
                    "isApplication": path.contains("/Applications/")
                ]
            }
            return ["type": "processes", "processes": processes]
        case "killProcess", "signalProcess":
            guard let pid = Self.int(message["pid"]) else { throw Self.error("Process ID is missing") }
            let signal = command == "killProcess" ? SIGKILL : Int32(Self.int(message["signal"]) ?? Int(SIGTERM))
            try context.sendSignal(signal, toProcessWithPID: Int32(pid))
            return Self.result(command, data: ["pid": pid, "signal": signal])
        case "batteryAnalytics":
            let samples = try BatteryAnalyticsService.syncFromDevice(target: target, context: context)
            return ["type": "batteryAnalytics", "history": Self.batteryHistory(samples)]
        case "deviceInfo":
            let entries = try context.deviceDiagnostics()
            return ["type": "deviceInfo", "hardware": Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })]
        case "diagnostics":
            let entries = try context.deviceDiagnostics()
            return ["type": "diagnostics", "data": Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })]
        case "performance":
            let sample = try context.performanceSnapshot()
            return [
                "type": "performance",
                "system": Dictionary(uniqueKeysWithValues: sample.systemMetrics.map { ($0.key, $0.value) }),
                "cpu": Dictionary(uniqueKeysWithValues: sample.cpuMetrics.map { ($0.key, $0.value) }),
                "processCount": sample.processCount
            ]
        case "energy":
            let pids = (message["pids"] as? [NSNumber] ?? []).map(\.uint32Value)
            let samples = try context.energySamples(for: pids).map {
                ["pid": $0.pid, "timestamp": $0.timestamp, "total": $0.total, "cpu": $0.cpu,
                 "gpu": $0.gpu, "network": $0.network, "display": $0.display] as [String: Any]
            }
            return ["type": "energy", "samples": samples]
        case "graphics":
            let sample = try context.graphicsSample()
            return ["type": "graphics", "timestamp": sample.timestamp, "fps": sample.framesPerSecond,
                    "allocatedMemory": sample.allocatedMemory, "usedMemory": sample.usedMemory,
                    "driverMemory": sample.driverMemory, "gpu": sample.gpuProcess,
                    "recoveryCount": sample.recoveryCount]
        case "configuration":
            let value = try context.currentDeviceConfiguration()
            return [
                "type": "configuration",
                "appearance": Self.json(value.appearance.map { $0 == .dark ? "dark" : "light" }),
                "colorFilter": ["enabled": value.colorFilterEnabled ?? false,
                                "type": value.colorFilterType ?? "",
                                "intensity": value.colorFilterIntensity ?? 0],
                "textSize": value.textSize ?? "",
                "reduceMotion": value.reduceMotion ?? false,
                "reduceTransparency": value.reduceTransparency ?? false,
                "showBorders": value.showBorders ?? false
            ]
        case "conditions":
            let groups = try context.availableDeviceConditions().map { group in
                ["identifier": group.identifier, "profiles": group.profiles.map {
                    ["identifier": $0.identifier, "description": $0.detail]
                }] as [String: Any]
            }
            return ["type": "conditions", "groups": groups]
        case "setAppearance":
            guard let style = message["style"] as? String else { throw Self.error("Appearance is missing") }
            try context.setDeviceAppearance(style == "dark" ? .dark : .light)
        case "setLiquidGlassOpacity":
            try context.setLiquidGlassOpacity(Self.double(message["value"]) ?? 1)
        case "setColorFilter":
            try context.setDeviceColorFilter(
                enabled: message["enabled"] as? Bool ?? false,
                type: message["filterType"] as? String ?? "Grayscale",
                intensity: Self.double(message["value"]) ?? 1
            )
        case "setTextSize":
            guard let size = message["size"] as? String else { throw Self.error("Text size is missing") }
            try context.setDeviceTextSize(size)
        case "setReduceMotion": try context.setReduceMotion(message["enabled"] as? Bool ?? false)
        case "setReduceTransparency": try context.setReduceTransparency(message["enabled"] as? Bool ?? false)
        case "setIncreaseContrast": try context.setIncreaseContrast(message["enabled"] as? Bool ?? false)
        case "setShowBorders": try context.setShowLayoutBorders(message["enabled"] as? Bool ?? false)
        case "enableCondition":
            guard let group = message["groupIdentifier"] as? String,
                  let profile = message["profileIdentifier"] as? String else { throw Self.error("Condition profile is missing") }
            try context.enableDeviceCondition(.init(groupIdentifier: group, identifier: profile, detail: profile))
        case "disableCondition": try context.disableDeviceCondition()
        case "setLocation":
            guard let latitude = Self.double(message["latitude"]),
                  let longitude = Self.double(message["longitude"]) else { throw Self.error("Location is missing") }
            try setLocation(latitude: latitude, longitude: longitude)
        case "clearLocation": try clearLocation()
        case "restart": try context.performPowerAction(.restart)
        case "shutdown": try context.performPowerAction(.shutdown)
        case "sleep": try context.performPowerAction(.sleep)
        default:
            throw Self.error("\(command) is not available through this StikDebug relay yet")
        }
        return Self.result(command, data: [:])
    }

    private func setLocation(latitude: Double, longitude: Double) throws {
        if locationClient == nil {
            let handles = try IdeviceBridge.activeTunnelHandles(for: context)
            let server = try IdeviceBridge.connectClient(
                fallback: "Unable to open Instruments for location simulation",
                missingClientMessage: "Instruments service was not created",
                connect: { remote_server_connect_rsd(handles.adapter, handles.handshake, $0) }
            )
            var client: OpaquePointer?
            if let error = location_simulation_new(server, &client) {
                remote_server_free(server)
                throw IdeviceBridge.consumeFFIError(error, fallback: "Location simulation could not start")
            }
            locationClient = client
        }
        guard let locationClient else { throw Self.error("Location simulation could not start") }
        if let error = location_simulation_set(locationClient, latitude, longitude) {
            throw IdeviceBridge.consumeFFIError(error, fallback: "Unable to set the simulated location")
        }
    }

    private func clearLocation() throws {
        guard let locationClient else { return }
        if let error = location_simulation_clear(locationClient) {
            throw IdeviceBridge.consumeFFIError(error, fallback: "Unable to clear the simulated location")
        }
        location_simulation_free(locationClient)
        self.locationClient = nil
    }

    private static func result(_ command: String, data: [String: Any]) -> [String: Any] {
        ["type": "commandResult", "command": command, "ok": true, "data": data]
    }

    private static func batteryHistory(_ samples: [BatteryHealthSample]) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return samples.map {
            ["date": formatter.string(from: $0.date), "health": Self.json($0.healthPercent),
             "cycles": Self.json($0.cycleCount), "fullCapacity": Self.json($0.availableCapacity),
             "designCapacity": Self.json($0.originalCapacity), "temperature": Self.json($0.averageTemperature),
             "sourceName": $0.sourceName]
        }
    }

    private static func json<T>(_ value: T?) -> Any {
        if let value { return value }
        return NSNull()
    }
    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    private static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func error(_ message: String) -> NSError { IdeviceBridge.makeError(message: message) }
}

/// Keeps the configured StikServer aware of every *locally discovered* paired
/// device while StikDebug is open. Server-originated devices are deliberately
/// excluded, which prevents two StikDebug clients from advertising a route back
/// to each other forever.
@MainActor
final class StikServerRelayManager {
    static let shared = StikServerRelayManager()

    private var relays: [String: StikServerRelay] = [:]
    private var devicesSubscription: AnyCancellable?
    private var serverAddress = ""
    private var token = ""
    private var isActive = false

    private init() {}

    func start(serverAddress: String, token: String) {
        let normalized = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = normalized != self.serverAddress || token != self.token
        self.serverAddress = normalized
        self.token = token
        isActive = !self.serverAddress.isEmpty
        if changed {
            relays.values.forEach { $0.disconnect() }
            relays.removeAll()
        }
        NearbyDeviceBrowser.shared.start()
        if devicesSubscription == nil {
            devicesSubscription = NearbyDeviceBrowser.shared.$devices
                .receive(on: RunLoop.main)
                .sink { [weak self] devices in self?.reconcile(devices) }
        }
        reconcile(NearbyDeviceBrowser.shared.devices)
    }

    func stop() {
        isActive = false
        relays.values.forEach { $0.disconnect() }
        relays.removeAll()
    }

    private func reconcile(_ devices: [NearbyDevelopmentDevice]) {
        guard isActive else { return }
        let paired = Dictionary(uniqueKeysWithValues: devices.filter(\.isPaired).map { ($0.id, $0) })
        for id in relays.keys where paired[id] == nil {
            relays.removeValue(forKey: id)?.disconnect()
        }
        for (id, device) in paired where relays[id] == nil {
            let relay = StikServerRelay()
            relays[id] = relay
            relay.connect(serverAddress: serverAddress, token: token, device: device)
        }
    }
}
