//
//  StikServerClientView.swift
//  StikDebug
//

import SwiftUI
import UIKit

struct StikServerDevice: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let kind: String
    let connected: Bool?
    let controllable: Bool
    let paired: Bool?
    let mode: String?
    let serviceIdentifier: String?
    let pairingIdentifier: String?
    let backendMessage: String?

    var displayedIdentifier: String { serviceIdentifier ?? pairingIdentifier ?? id }
    var systemImage: String { kind.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone" }
}

@MainActor
final class StikServerConnection: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var title: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .failed(let message): message
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var devices: [StikServerDevice] = []

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private weak var streamConsumer: StikServerRemoteControlModel?
    private var subscribedDeviceID: String?

    func connect(serverAddress: String, token: String) {
        disconnect()
        guard let url = Self.webSocketURL(from: serverAddress, token: token) else {
            state = .failed("Invalid StikServer address")
            return
        }

        state = .connecting
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.socket = socket
        socket.resume()

        receiveTask = Task { [weak self, weak socket] in
            guard let socket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self else { return }
                    self.receive(message)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.socket === socket else { return }
                self.state = .failed(error.localizedDescription)
                self.finishTransport(clearDevices: false)
            }
        }
    }

    func disconnect() {
        finishTransport(clearDevices: true)
        state = .disconnected
    }

    deinit {
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    func subscribe(to device: StikServerDevice, consumer: StikServerRemoteControlModel) {
        guard device.controllable else {
            consumer.subscriptionFailed(device.backendMessage ?? "Pair this device with StikServer first")
            return
        }
        streamConsumer = consumer
        subscribedDeviceID = device.id
        send(["type": "subscribe", "deviceId": device.id])
    }

    func unsubscribe(_ consumer: StikServerRemoteControlModel) {
        guard streamConsumer === consumer else { return }
        send(["type": "unsubscribe"])
        streamConsumer = nil
        subscribedDeviceID = nil
    }

    func command(_ name: String, deviceID: String, fields: [String: Any] = [:]) {
        var payload = fields
        payload["type"] = "command"
        payload["deviceId"] = deviceID
        payload["command"] = name
        send(payload)
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            streamConsumer?.receiveFrame(data)
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return }
            state = .connected
            switch type {
            case "devices":
                guard let rawDevices = object["devices"],
                      let encoded = try? JSONSerialization.data(withJSONObject: rawDevices),
                      let decoded = try? JSONDecoder().decode([StikServerDevice].self, from: encoded) else { return }
                devices = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            case "subscribed":
                let deviceID = object["deviceId"] as? String
                guard deviceID == subscribedDeviceID else {
                    streamConsumer?.subscriptionFailed("StikServer could not start the device session")
                    return
                }
                streamConsumer?.subscriptionReady()
            case "deviceEvent":
                guard object["deviceId"] as? String == subscribedDeviceID,
                      let event = object["event"] as? [String: Any] else { return }
                streamConsumer?.receiveEvent(event)
            case "error":
                let message = object["message"] as? String ?? "StikServer request failed"
                if let streamConsumer { streamConsumer.subscriptionFailed(message) }
                else { state = .failed(message) }
            default:
                break
            }
        @unknown default:
            break
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { [weak self, weak socket] in
            do {
                try await socket?.send(.string(text))
            } catch {
                guard let self, self.socket === socket else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func finishTransport(clearDevices: Bool) {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        streamConsumer?.transportStopped()
        streamConsumer = nil
        subscribedDeviceID = nil
        if clearDevices { devices = [] }
    }

    private static func webSocketURL(from value: String, token explicitToken: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"),
              components.host != nil else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        let copiedToken = components.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
        let token = explicitToken.isEmpty ? copiedToken : explicitToken
        components.path = "/viewer"
        components.queryItems = token.isEmpty ? nil : [URLQueryItem(name: "token", value: token)]
        return components.url
    }
}

@MainActor
final class StikServerRemoteControlModel: RemoteControlModel {
    let video = RemoteVideoFrameStore()
    @Published private(set) var orientation: RemoteScreenOrientation = .portrait
    @Published private(set) var isSoftwareKeyboardVisible = false
    @Published private(set) var isConnecting = false
    @Published private(set) var connectedDeviceName: String?
    @Published var errorMessage: String?

    private let connection: StikServerConnection
    private let device: StikServerDevice
    private var wantsMirroring = false

    init(connection: StikServerConnection, device: StikServerDevice) {
        self.connection = connection
        self.device = device
    }

    var isMirroring: Bool { wantsMirroring || isConnecting || connectedDeviceName != nil }

    func startMirroring() {
        wantsMirroring = true
        isConnecting = true
        errorMessage = nil
        isSoftwareKeyboardVisible = false
        connection.subscribe(to: device, consumer: self)
    }

    func stopMirroring() {
        wantsMirroring = false
        connection.unsubscribe(self)
        resetStream()
    }

    func suspendMirroring() {
        guard wantsMirroring else { return }
        connection.unsubscribe(self)
        resetStream(keepRequest: true)
    }

    func resumeMirroring() {
        guard wantsMirroring, connectedDeviceName == nil, !isConnecting else { return }
        isConnecting = true
        connection.subscribe(to: device, consumer: self)
    }

    func press(_ button: RemoteHardwareButton) {
        let command: String = switch button {
        case .home: "home"
        case .lock: "lock"
        case .volumeUp: "volumeUp"
        case .volumeDown: "volumeDown"
        case .mute: "mute"
        case .siri: "siri"
        }
        send(command)
    }

    func touch(_ phase: RemoteTouchPhase, x: UInt16, y: UInt16) {
        let phaseName: String = switch phase {
        case .down: "down"
        case .move: "move"
        case .up: "up"
        }
        send("touch", fields: [
            "phase": phaseName,
            "x": Double(x) / Double(UInt16.max),
            "y": Double(y) / Double(UInt16.max),
            "coordinateSpace": "device"
        ])
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        send("text", fields: ["text": String(text.prefix(2_000))])
    }

    func backspace() { send("backspace") }

    func toggleSoftwareKeyboard() {
        isSoftwareKeyboardVisible.toggle()
        send("softwareKeyboard")
    }

    func rotate(_ direction: RemoteRotationDirection) {
        send(direction == .left ? "rotateLeft" : "rotateRight")
    }

    func subscriptionReady() {
        connectedDeviceName = device.name
        isConnecting = false
    }

    func subscriptionFailed(_ message: String) {
        isConnecting = false
        errorMessage = message
    }

    func receiveFrame(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        video.image = image
    }

    func receiveEvent(_ event: [String: Any]) {
        guard event["type"] as? String == "orientation",
              let name = event["orientation"] as? String else { return }
        orientation = switch name {
        case "portraitUpsideDown": .portraitUpsideDown
        case "landscapeLeft": .landscapeLeft
        case "landscapeRight": .landscapeRight
        case "portrait": .portrait
        default: .unknown
        }
    }

    func transportStopped() { resetStream(keepRequest: wantsMirroring) }

    private func send(_ command: String, fields: [String: Any] = [:]) {
        connection.command(command, deviceID: device.id, fields: fields)
    }

    private func resetStream(keepRequest: Bool = false) {
        video.image = nil
        connectedDeviceName = nil
        isConnecting = false
        orientation = .portrait
        isSoftwareKeyboardVisible = false
        if !keepRequest { wantsMirroring = false }
    }
}

struct StikServerClientView: View {
    let serverAddress: String
    let token: String
    @StateObject private var connection = StikServerConnection()

    var body: some View {
        List {
            Section { LabeledContent("Status", value: connection.state.title) }

            Section("Devices relayed by StikServer") {
                if connection.devices.isEmpty {
                    HStack(spacing: 12) {
                        if connection.state == .connecting { ProgressView() }
                        Text(emptyMessage).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(connection.devices) { device in
                        NavigationLink {
                            StikServerDeviceDetailView(connection: connection, device: device)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                    Text(device.controllable ? "\(device.kind) · Ready" : "\(device.kind) · Pair with StikServer")
                                        .font(.caption)
                                        .foregroundStyle(device.controllable ? .green : .secondary)
                                    Text("UUID: \(device.displayedIdentifier)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            } icon: {
                                Image(systemName: device.controllable ? "checkmark.circle.fill" : device.systemImage)
                                    .foregroundStyle(device.controllable ? .green : .secondary)
                            }
                        }
                        .disabled(!device.controllable)
                    }
                }
            }
        }
        .navigationTitle("StikServer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { connection.connect(serverAddress: serverAddress, token: token) } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { connection.connect(serverAddress: serverAddress, token: token) }
    }

    private var emptyMessage: String {
        switch connection.state {
        case .failed(let message): message
        case .connected: "StikServer is connected but has no ready devices."
        default: "Connecting to StikServer…"
        }
    }
}

private struct StikServerDeviceDetailView: View {
    let device: StikServerDevice
    @ObservedObject private var connection: StikServerConnection
    @StateObject private var controller: StikServerRemoteControlModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isFullscreen = false
    @State private var keyboardActive = false
    @State private var resultMessage: String?

    init(connection: StikServerConnection, device: StikServerDevice) {
        self.connection = connection
        self.device = device
        _controller = StateObject(wrappedValue: StikServerRemoteControlModel(connection: connection, device: device))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 3) {
                    Text(device.name).font(.headline)
                    Text("\(device.kind) via StikServer").font(.subheadline).foregroundStyle(.secondary)
                    Text("UUID: \(device.displayedIdentifier)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                mirrorPanel
                if controller.isMirroring {
                    RemoteHardwareControls(controller: controller)
                    viewerActions
                    RemoteKeyboardCapture(isActive: $keyboardActive, controller: controller)
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                }
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { if !isFullscreen { controller.stopMirroring() } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive: controller.suspendMirroring()
            case .active: controller.resumeMirroring()
            @unknown default: break
            }
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            RemoteFullscreenView(
                controller: controller,
                isPresented: $isFullscreen,
                saveScreenshot: saveScreenshot,
                stopMirroring: { controller.stopMirroring() }
            )
        }
        .alert("StikServer Control", isPresented: Binding(
            get: { controller.errorMessage != nil || resultMessage != nil },
            set: { if !$0 { controller.errorMessage = nil; resultMessage = nil } }
        )) {
            Button("OK", role: .cancel) { controller.errorMessage = nil; resultMessage = nil }
        } message: {
            Text(controller.errorMessage ?? resultMessage ?? "")
        }
    }

    @ViewBuilder
    private var mirrorPanel: some View {
        if controller.isMirroring {
            RemoteScreenSurface(video: controller.video, orientation: controller.orientation) { gesture in
                if case .touch(let phase, let point) = gesture {
                    controller.touch(phase, x: point.x, y: point.y)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 560)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.secondary.opacity(0.35), lineWidth: 1)
            }
        } else {
            ContentUnavailableView(
                "Screen Mirroring Is Off",
                systemImage: "rectangle.slash",
                description: Text("StikServer will stream this device only while this page is open.")
            )
            .frame(minHeight: 260)

            Button { controller.startMirroring() } label: {
                Label(controller.isConnecting ? "Connecting…" : "View Screen", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isConnecting)
        }
    }

    private var viewerActions: some View {
        VStack(spacing: 10) {
            HStack {
                Button { isFullscreen = true } label: {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button(action: saveScreenshot) { Label("Screenshot", systemImage: "camera") }
                Button { keyboardActive.toggle() } label: {
                    Label(keyboardActive ? "Hide Keyboard" : "Keyboard", systemImage: "keyboard")
                }
            }
            .buttonStyle(.bordered)

            Button("Stop Mirroring", role: .destructive) {
                keyboardActive = false
                controller.stopMirroring()
            }
            .buttonStyle(.bordered)
        }
    }

    private func saveScreenshot() {
        guard let image = controller.video.image else {
            resultMessage = "No remote frame is available yet."
            return
        }
        RemotePhotoSaver.save(image, orientation: controller.orientation) { result in
            switch result {
            case .success: resultMessage = "Screenshot saved to Photos."
            case .failure(let error): resultMessage = error.localizedDescription
            }
        }
    }
}
