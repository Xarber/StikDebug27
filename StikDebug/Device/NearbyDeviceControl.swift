//
//  NearbyDeviceControl.swift
//  StikDebug
//

import Foundation
import UIKit
import Darwin
import idevice

struct NearbyDevelopmentDevice: Identifiable, Equatable {
    let discoveryID: String
    let name: String
    let type: String
    let domain: String
    let serviceIdentifier: String
    let deviceIdentifier: String?
    let addresses: [Data]
    let pairingRecordID: UUID?
    let pairingFileURL: URL?

    var id: String { pairingRecordID?.uuidString ?? discoveryID }
    var isPaired: Bool { pairingFileURL != nil }
    var displayedIdentifier: String { deviceIdentifier ?? serviceIdentifier }
}

final class NearbyDeviceBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = NearbyDeviceBrowser()
    @Published private(set) var devices: [NearbyDevelopmentDevice] = []
    @Published private(set) var isSearching = false

    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var resolvedDevices: [String: NearbyDevelopmentDevice] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !isSearching else { return }
        isSearching = true
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        isSearching = false
    }

    func refresh() {
        stop()
        services.removeAll()
        resolvedDevices.removeAll()
        devices.removeAll()
        start()
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async { self.isSearching = true }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async { self.isSearching = false }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let id = serviceID(service)
        services[id] = service
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let id = serviceID(service)
        services[id] = nil
        DispatchQueue.main.async {
            self.resolvedDevices[id] = nil
            self.publishResolvedDevices()
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses, !addresses.isEmpty else { return }
        let discoveryID = serviceID(sender)
        let txt = Self.remotePairingTXT(from: sender.txtRecordData())
        let serviceIdentifier = txt.identifier ?? sender.name
        let pairingMatch = try? RemotePairingStore.matchingRecord(
            serviceIdentifier: serviceIdentifier,
            deviceIdentifier: pairingMatch?.record.deviceIdentifier,
            authenticationTags: txt.authenticationTags
        )
        let device = NearbyDevelopmentDevice(
            discoveryID: discoveryID,
            name: pairingMatch?.record.displayName ?? "Unpaired Device",
            type: sender.type,
            domain: sender.domain,
            serviceIdentifier: serviceIdentifier,
            addresses: addresses,
            pairingRecordID: pairingMatch?.record.id,
            pairingFileURL: pairingMatch?.pairingFileURL
        )

        DispatchQueue.main.async {
            self.resolvedDevices[discoveryID] = device
            self.publishResolvedDevices()
        }
    }

    private func serviceID(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func publishResolvedDevices() {
        devices = Dictionary(grouping: resolvedDevices.values, by: \.id).values.compactMap { matches in
            guard let first = matches.first else { return nil }
            let addresses = matches.flatMap(\.addresses).reduce(into: [Data]()) { result, address in
                if !result.contains(address) { result.append(address) }
            }
            return NearbyDevelopmentDevice(
                discoveryID: first.discoveryID,
                name: first.name,
                type: first.type,
                domain: first.domain,
                serviceIdentifier: first.serviceIdentifier,
                deviceIdentifier: first.deviceIdentifier,
                addresses: addresses,
                pairingRecordID: first.pairingRecordID,
                pairingFileURL: first.pairingFileURL
            )
        }.sorted {
            if $0.isPaired != $1.isPaired { return $0.isPaired }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func remotePairingTXT(from data: Data?) -> (identifier: String?, authenticationTags: [String]) {
        guard let data else { return (nil, []) }
        let bytes = [UInt8](data)
        var index = 0
        var identifier: String?
        var tags: [String] = []
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard length > 0, index + length <= bytes.count else { break }
            let entry = Data(bytes[index ..< index + length])
            index += length
            guard let text = String(data: entry, encoding: .utf8),
                  let separator = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<separator])
            let value = String(text[text.index(after: separator)...])
            if key == "identifier" { identifier = value }
            if key == "authTag" { tags.append(value) }
        }
        return (identifier, tags)
    }
}

enum RemoteHardwareButton: UInt8, CaseIterable, Identifiable {
    case home
    case lock
    case volumeUp
    case volumeDown
    case mute
    case siri

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .lock: return "Lock"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .siri: return "Siri"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .lock: return "lock"
        case .volumeUp: return "speaker.plus"
        case .volumeDown: return "speaker.minus"
        case .mute: return "speaker.slash"
        case .siri: return "waveform.circle"
        }
    }
}

enum RemoteRotationDirection: UInt8 {
    case left
    case right
}

enum RemoteScreenOrientation: UInt8 {
    case unknown = 0
    case portrait = 1
    case portraitUpsideDown = 2
    case landscapeRight = 3
    case landscapeLeft = 4

    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

enum RemoteTouchPhase: UInt8 {
    case down
    case move
    case up
}

final class RemoteDeviceSession: @unchecked Sendable {
    struct VideoAccessUnit: Sendable {
        let data: Data
        let timestamp: UInt32
    }

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var controller: OpaquePointer?
    private let lifetime = NSCondition()
    private var activeCalls = 0
    private var isClosing = false

    private init(adapter: OpaquePointer, handshake: OpaquePointer, controller: OpaquePointer) {
        self.adapter = adapter
        self.handshake = handshake
        self.controller = controller
    }

    static func connect(to device: NearbyDevelopmentDevice) throws -> RemoteDeviceSession {
        let hostName = "StikDebug-\(UIDevice.current.name)"
        guard device.isPaired else {
            throw IdeviceBridge.makeError(message: "This nearby device is not paired with StikDebug")
        }
        let pairingURLs = try RemotePairingStore.pairingFileURLs(preferredFor: device)
        guard !pairingURLs.isEmpty else {
            throw IdeviceBridge.makeError(
                message: "Pair this device with StikDebug first. On the other device, open Settings → Privacy & Security → Developer Mode."
            )
        }

        var lastError: NSError?
        for pairingURL in pairingURLs {
            var pairingFile: OpaquePointer?
            if let pairingError = pairingURL.path.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
                lastError = IdeviceBridge.consumeFFIError(
                    pairingError,
                    fallback: "Unable to read a saved remote pairing identity"
                )
                continue
            }
            guard let pairingFile else { continue }
            defer { rp_pairing_file_free(pairingFile) }

            for address in device.addresses.sorted(by: preferredAddress) {
                var adapter: OpaquePointer?
                var handshake: OpaquePointer?
                let error = address.withUnsafeBytes { buffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                    guard let baseAddress = buffer.baseAddress else { return nil }
                    return hostName.withCString { host in
                        tunnel_create_rppairing(
                            baseAddress.assumingMemoryBound(to: sockaddr.self),
                            socklen_t(buffer.count),
                            host,
                            pairingFile,
                            nil,
                            nil,
                            &adapter,
                            &handshake
                        )
                    }
                }

                if let error {
                    lastError = IdeviceBridge.consumeFFIError(
                        error,
                        fallback: "The saved identity did not match \(device.name)"
                    )
                    continue
                }

                guard let adapter, let handshake else {
                    lastError = IdeviceBridge.makeError(message: "The remote tunnel did not return its connection handles")
                    continue
                }

                let writeError = pairingURL.path.withCString { rp_pairing_file_write(pairingFile, $0) }
                if let writeError {
                    rsd_handshake_free(handshake)
                    _ = adapter_close(adapter)
                    adapter_free(adapter)
                    throw IdeviceBridge.consumeFFIError(
                        writeError,
                        fallback: "The verified remote pairing record could not be updated"
                    )
                }

                let stableDeviceIdentifier = Self.deviceIdentifier(adapter: adapter, handshake: handshake)

                var controller: OpaquePointer?
                if let controlError = remote_control_client_connect_rsd(adapter, handshake, &controller) {
                    rsd_handshake_free(handshake)
                    _ = adapter_close(adapter)
                    adapter_free(adapter)
                    throw IdeviceBridge.consumeFFIError(
                        controlError,
                        fallback: "The target device did not expose its display and HID services"
                    )
                }

                guard let controller else {
                    rsd_handshake_free(handshake)
                    _ = adapter_close(adapter)
                    adapter_free(adapter)
                    throw IdeviceBridge.makeError(message: "The remote-control session was not created")
                }

                try? RemotePairingStore.markConnected(
                    pairingFileURL: pairingURL,
                    to: device,
                    deviceIdentifier: stableDeviceIdentifier
                )
                return RemoteDeviceSession(adapter: adapter, handshake: handshake, controller: controller)
            }
        }

        throw lastError ?? IdeviceBridge.makeError(message: "No reachable address was found for \(device.name)")
    }

    func nextVideoAccessUnit(timeoutMilliseconds: UInt64 = 500) throws -> VideoAccessUnit? {
        try withController { controller in
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            var timestamp: UInt32 = 0
            if let error = remote_control_client_next_video_access_unit(
                controller,
                timeoutMilliseconds,
                &bytes,
                &length,
                &timestamp
            ) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Unable to receive the remote video stream")
            }
            guard let bytes, length > 0 else { return nil }
            defer { idevice_data_free(bytes, UInt(length)) }
            return VideoAccessUnit(data: Data(bytes: bytes, count: length), timestamp: timestamp)
        }
    }

    func tap(x: UInt16, y: UInt16) throws {
        try withController { controller in
            if let error = remote_control_client_tap(controller, x, y) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Remote tap failed")
            }
        }
    }

    func touch(_ phase: RemoteTouchPhase, x: UInt16, y: UInt16) throws {
        try withController { controller in
            if let error = remote_control_client_touch(controller, phase.rawValue, x, y) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Remote touch input failed")
            }
        }
    }

    func drag(from start: (UInt16, UInt16), to end: (UInt16, UInt16), duration: UInt64) throws {
        try withController { controller in
            if let error = remote_control_client_drag(
                controller,
                start.0,
                start.1,
                end.0,
                end.1,
                duration
            ) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Remote drag failed")
            }
        }
    }

    func press(_ button: RemoteHardwareButton) throws {
        try withController { controller in
            if let error = remote_control_client_press_button(controller, button.rawValue) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Remote button press failed")
            }
        }
    }

    func type(_ text: String) throws {
        for character in text {
            guard let key = Self.keyboardKey(for: character) else {
                throw IdeviceBridge.makeError(message: "The character “\(character)” is not supported by remote HID input")
            }
            try keyboardTap(usage: key.usage, modifiers: key.modifiers)
        }
    }

    func backspace() throws {
        try keyboardTap(usage: 0x2A, modifiers: 0)
    }

    func rotate(_ direction: RemoteRotationDirection) throws {
        try withController { controller in
            if let error = remote_control_client_rotate(controller, direction.rawValue) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Remote rotation failed")
            }
        }
    }

    func orientation() throws -> RemoteScreenOrientation {
        try withController { controller in
            var raw: UInt8 = 0
            if let error = remote_control_client_get_orientation(controller, &raw) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Unable to read the remote screen orientation")
            }
            return RemoteScreenOrientation(rawValue: raw) ?? .unknown
        }
    }

    func close() {
        lifetime.lock()
        guard !isClosing else {
            lifetime.unlock()
            return
        }
        isClosing = true
        while activeCalls > 0 { lifetime.wait() }

        if let controller {
            remote_control_client_free(controller)
            self.controller = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            _ = adapter_close(adapter)
            adapter_free(adapter)
            self.adapter = nil
        }
        lifetime.unlock()
    }

    deinit {
        close()
    }

    private func withController<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        lifetime.lock()
        guard !isClosing, let controller else {
            lifetime.unlock()
            throw IdeviceBridge.makeError(message: "Remote-control session is closed")
        }
        activeCalls += 1
        lifetime.unlock()

        defer {
            lifetime.lock()
            activeCalls -= 1
            if activeCalls == 0 { lifetime.broadcast() }
            lifetime.unlock()
        }
        return try operation(controller)
    }

    private func keyboardTap(usage: UInt16, modifiers: UInt8) throws {
        try withController { controller in
            if let error = remote_control_client_keyboard_tap(controller, usage, modifiers) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Remote keyboard input failed")
            }
        }
    }

    private static func keyboardKey(for character: Character) -> (usage: UInt16, modifiers: UInt8)? {
        let shift: UInt8 = 0x02
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return nil }
        let value = scalar.value
        if (97 ... 122).contains(value) { return (UInt16(0x04 + value - 97), 0) }
        if (65 ... 90).contains(value) { return (UInt16(0x04 + value - 65), shift) }
        if (49 ... 57).contains(value) { return (UInt16(0x1E + value - 49), 0) }
        if value == 48 { return (0x27, 0) }

        let keys: [Character: (UInt16, UInt8)] = [
            "\n": (0x28, 0), "\r": (0x28, 0), "\t": (0x2B, 0), " ": (0x2C, 0),
            "-": (0x2D, 0), "_": (0x2D, shift), "=": (0x2E, 0), "+": (0x2E, shift),
            "[": (0x2F, 0), "{": (0x2F, shift), "]": (0x30, 0), "}": (0x30, shift),
            "\\": (0x31, 0), "|": (0x31, shift), ";": (0x33, 0), ":": (0x33, shift),
            "'": (0x34, 0), "\"": (0x34, shift), "`": (0x35, 0), "~": (0x35, shift),
            ",": (0x36, 0), "<": (0x36, shift), ".": (0x37, 0), ">": (0x37, shift),
            "/": (0x38, 0), "?": (0x38, shift), "!": (0x1E, shift), "@": (0x1F, shift),
            "#": (0x20, shift), "$": (0x21, shift), "%": (0x22, shift), "^": (0x23, shift),
            "&": (0x24, shift), "*": (0x25, shift), "(": (0x26, shift), ")": (0x27, shift)
        ]
        return keys[character]
    }

    private static func preferredAddress(_ lhs: Data, _ rhs: Data) -> Bool {
        addressRank(lhs) < addressRank(rhs)
    }

    private static func deviceIdentifier(adapter: OpaquePointer, handshake: OpaquePointer) -> String? {
        try? IdeviceBridge.withConnectedClient(
            fallback: "Failed to connect to lockdownd",
            missingClientMessage: "Lockdownd client was not created",
            connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
            cleanup: { lockdownd_client_free($0) }
        ) { client in
            var value: plist_t?
            if let error = lockdownd_get_value(client, "UniqueDeviceID", nil, &value) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to read the device UUID")
            }
            defer { if let value { plist_free(value) } }
            guard let value else { throw IdeviceBridge.makeError(message: "The device UUID was empty") }
            var length: UInt64 = 0
            guard let bytes = plist_get_string_ptr(value, &length), length > 0 else {
                throw IdeviceBridge.makeError(message: "The device UUID was not a string")
            }
            return String(cString: bytes)
        }
    }

    private static func addressRank(_ address: Data) -> Int {
        address.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return 3 }
            switch Int32(baseAddress.assumingMemoryBound(to: sockaddr.self).pointee.sa_family) {
            case AF_INET6: return 0
            case AF_INET: return 1
            default: return 2
            }
        }
    }
}

final class NearbyRemoteControlModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var frame: UIImage?
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var orientation: RemoteScreenOrientation = .portrait
    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?

    private let commandQueue = DispatchQueue(label: "com.stikdebug.nearby-remote-control.commands", qos: .userInteractive)
    private let touchQueue = DispatchQueue(label: "com.stikdebug.nearby-remote-control.touch", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "com.stikdebug.nearby-remote-control.video", qos: .userInteractive)
    private let sessionLock = NSLock()
    private var session: RemoteDeviceSession?
    private var requestedDevice: NearbyDevelopmentDevice?
    private var requestGeneration = 0

    var isMirroring: Bool { connectedDeviceName != nil || isConnecting }

    func startMirroring(to device: NearbyDevelopmentDevice) {
        let generation = updateRequest(device: device)
        isConnecting = true
        errorMessage = nil

        commandQueue.async { [weak self] in
            guard let self else { return }
            do {
                let newSession = try RemoteDeviceSession.connect(to: device)
                guard self.isRequestCurrent(generation, device: device) else {
                    newSession.close()
                    return
                }
                let oldSession = self.replaceSession(with: newSession)
                self.videoQueue.async { oldSession?.close() }
                self.startVideoStream(for: newSession)
                DispatchQueue.main.async {
                    guard self.isRequestCurrent(generation, device: device) else { return }
                    self.connectedDeviceName = device.name
                    self.isConnecting = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.isRequestCurrent(generation, device: device) else { return }
                    self.isConnecting = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stopMirroring() {
        cancelRequest(keepDevice: false)
        let oldSession = replaceSession(with: nil)
        videoQueue.async { oldSession?.close() }
        DispatchQueue.main.async { [weak self] in
            self?.frame = nil
            self?.connectedDeviceName = nil
            self?.isConnecting = false
            self?.orientation = .portrait
        }
    }

    func suspendMirroring() {
        guard requestedDeviceSnapshot() != nil else { return }
        cancelRequest(keepDevice: true)
        let oldSession = replaceSession(with: nil)
        videoQueue.async { oldSession?.close() }
        frame = nil
        connectedDeviceName = nil
        isConnecting = false
        errorMessage = nil
    }

    func resumeMirroring() {
        guard let device = requestedDeviceSnapshot(), currentSession() == nil else { return }
        startMirroring(to: device)
    }

    func tap(x: UInt16, y: UInt16) {
        perform { try $0.tap(x: x, y: y) }
    }

    func drag(from start: (UInt16, UInt16), to end: (UInt16, UInt16), duration: UInt64 = 300) {
        perform { try $0.drag(from: start, to: end, duration: duration) }
    }

    func press(_ button: RemoteHardwareButton) {
        perform { try $0.press(button) }
    }

    func touch(_ phase: RemoteTouchPhase, x: UInt16, y: UInt16) {
        touchQueue.async { [weak self] in
            guard let self, let session = self.currentSession() else { return }
            do {
                try session.touch(phase, x: x, y: y)
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        perform { try $0.type(text) }
    }

    func backspace() {
        perform { try $0.backspace() }
    }

    func rotate(_ direction: RemoteRotationDirection) {
        perform { session in
            try session.rotate(direction)
            let orientation = try session.orientation()
            DispatchQueue.main.async { [weak self] in self?.orientation = orientation }
        }
    }

    private func perform(_ action: @escaping (RemoteDeviceSession) throws -> Void) {
        commandQueue.async { [weak self] in
            guard let self, let session = self.currentSession() else { return }
            do {
                try action(session)
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func startVideoStream(for session: RemoteDeviceSession) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            let decoder = RemoteHEVCDecoder()
            var nextOrientationUpdate = Date.distantPast
            while self.isCurrent(session) {
                do {
                    guard let unit = try session.nextVideoAccessUnit() else { continue }
                    if Date() >= nextOrientationUpdate {
                        nextOrientationUpdate = Date().addingTimeInterval(0.75)
                        self.commandQueue.async { [weak self] in
                            guard let self, self.isCurrent(session) else { return }
                            if let value = try? session.orientation() {
                                DispatchQueue.main.async { self.orientation = value }
                            }
                        }
                    }
                    try decoder.decode(annexB: unit.data, timestamp: unit.timestamp) { [weak self] result in
                        guard let self, self.isCurrent(session) else { return }
                        DispatchQueue.main.async {
                            switch result {
                            case .success(let image):
                                self.frame = image
                            case .failure(let error):
                                if self.errorMessage == nil {
                                    self.errorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                } catch RemoteHEVCDecoderError.missingParameterSets {
                    continue
                } catch {
                    if self.isCurrent(session) {
                        DispatchQueue.main.async {
                            if self.errorMessage == nil {
                                self.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    break
                }
            }
            decoder.stop()
        }
    }

    deinit {
        cancelRequest(keepDevice: false)
        let oldSession = replaceSession(with: nil)
        videoQueue.async { oldSession?.close() }
    }

    private func updateRequest(device: NearbyDevelopmentDevice) -> Int {
        sessionLock.lock()
        requestGeneration += 1
        requestedDevice = device
        let generation = requestGeneration
        sessionLock.unlock()
        return generation
    }

    private func cancelRequest(keepDevice: Bool) {
        sessionLock.lock()
        requestGeneration += 1
        if !keepDevice { requestedDevice = nil }
        sessionLock.unlock()
    }

    private func isRequestCurrent(_ generation: Int, device: NearbyDevelopmentDevice) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return requestGeneration == generation && requestedDevice?.id == device.id
    }

    private func requestedDeviceSnapshot() -> NearbyDevelopmentDevice? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return requestedDevice
    }

    private func currentSession() -> RemoteDeviceSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return session
    }

    @discardableResult
    private func replaceSession(with newSession: RemoteDeviceSession?) -> RemoteDeviceSession? {
        sessionLock.lock()
        let oldSession = session
        session = newSession
        sessionLock.unlock()
        return oldSession
    }

    private func isCurrent(_ candidate: RemoteDeviceSession) -> Bool {
        currentSession() === candidate
    }
}
