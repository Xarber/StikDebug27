//
//  NearbyDeviceControl.swift
//  StikDebug
//

import Foundation
import UIKit
import Darwin
import idevice

struct NearbyDevelopmentDevice: Identifiable, Equatable {
    let name: String
    let type: String
    let domain: String
    let addresses: [Data]

    var id: String { "\(name)|\(type)|\(domain)" }
}

final class NearbyDeviceBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var devices: [NearbyDevelopmentDevice] = []
    @Published private(set) var isSearching = false

    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]

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
            self.devices.removeAll { $0.id == id }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses, !addresses.isEmpty else { return }
        let device = NearbyDevelopmentDevice(
            name: sender.name,
            type: sender.type,
            domain: sender.domain,
            addresses: addresses
        )

        DispatchQueue.main.async {
            self.devices.removeAll { $0.id == device.id }
            self.devices.append(device)
            self.devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func serviceID(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
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

final class RemoteDeviceSession: @unchecked Sendable {
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var controller: OpaquePointer?
    private var isClosed = false

    private init(adapter: OpaquePointer, handshake: OpaquePointer, controller: OpaquePointer) {
        self.adapter = adapter
        self.handshake = handshake
        self.controller = controller
    }

    static func connect(to device: NearbyDevelopmentDevice) throws -> RemoteDeviceSession {
        let hostName = "StikDebug-\(UIDevice.current.name)"
        let pairingURL = try pairingFileURL(for: device)

        var pairingFile: OpaquePointer?
        let pairingError: UnsafeMutablePointer<IdeviceFfiError>? = pairingURL.path.withCString { path in
            if FileManager.default.fileExists(atPath: pairingURL.path) {
                return rp_pairing_file_read(path, &pairingFile)
            }
            return hostName.withCString { rp_pairing_file_generate($0, &pairingFile) }
        }
        if let pairingError {
            throw IdeviceBridge.consumeFFIError(
                pairingError,
                fallback: "Unable to prepare the remote pairing identity"
            )
        }
        guard let pairingFile else {
            throw IdeviceBridge.makeError(message: "Remote pairing identity was not created")
        }
        defer { rp_pairing_file_free(pairingFile) }

        var lastError: NSError?
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
                    fallback: "Unable to pair with \(device.name)"
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
                    fallback: "The remote pairing record could not be saved"
                )
            }

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

            DeviceTargetManager.shared.selectRemoteDevice(device, pairingFileURL: pairingURL)
            return RemoteDeviceSession(adapter: adapter, handshake: handshake, controller: controller)
        }

        throw lastError ?? IdeviceBridge.makeError(message: "No reachable address was found for \(device.name)")
    }

    func takeFrame() throws -> UIImage {
        guard let controller, !isClosed else {
            throw IdeviceBridge.makeError(message: "Remote-control session is closed")
        }

        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        if let error = remote_control_client_take_frame(controller, &bytes, &length) {
            throw IdeviceBridge.consumeFFIError(error, fallback: "Unable to capture the remote display")
        }
        guard let bytes, length > 0 else {
            throw IdeviceBridge.makeError(message: "The remote device returned an empty frame")
        }
        defer { idevice_data_free(bytes, UInt(length)) }

        let data = Data(bytes: bytes, count: length)
        guard let image = UIImage(data: data) else {
            throw IdeviceBridge.makeError(message: "The remote frame was not a valid image")
        }
        return image
    }

    func tap(x: UInt16, y: UInt16) throws {
        guard let controller, !isClosed else { return }
        if let error = remote_control_client_tap(controller, x, y) {
            throw IdeviceBridge.consumeFFIError(error, fallback: "Remote tap failed")
        }
    }

    func drag(from start: (UInt16, UInt16), to end: (UInt16, UInt16), duration: UInt64) throws {
        guard let controller, !isClosed else { return }
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

    func press(_ button: RemoteHardwareButton) throws {
        guard let controller, !isClosed else { return }
        if let error = remote_control_client_press_button(controller, button.rawValue) {
            throw IdeviceBridge.consumeFFIError(error, fallback: "Remote button press failed")
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true

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
    }

    deinit {
        close()
    }

    private static func pairingFileURL(for device: NearbyDevelopmentDevice) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("RemotePairing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = device.id.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return directory.appendingPathComponent(String(safeName)).appendingPathExtension("plist")
    }

    private static func preferredAddress(_ lhs: Data, _ rhs: Data) -> Bool {
        addressRank(lhs) < addressRank(rhs)
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

final class NearbyRemoteControlModel: ObservableObject {
    @Published private(set) var frame: UIImage?
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?

    private let queue = DispatchQueue(label: "com.stikdebug.nearby-remote-control", qos: .userInteractive)
    private var session: RemoteDeviceSession?
    private var frameTimer: DispatchSourceTimer?

    func connect(to device: NearbyDevelopmentDevice) {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let session = try RemoteDeviceSession.connect(to: device)
                self.session?.close()
                self.session = session
                self.startFrameTimer()
                DispatchQueue.main.async {
                    self.connectedDeviceName = device.name
                    self.isConnecting = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isConnecting = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.frameTimer?.cancel()
            self.frameTimer = nil
            self.session?.close()
            self.session = nil
            DeviceTargetManager.shared.selectThisDevice()
            DispatchQueue.main.async {
                self.frame = nil
                self.connectedDeviceName = nil
            }
        }
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

    private func perform(_ action: @escaping (RemoteDeviceSession) throws -> Void) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            do {
                try action(session)
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func startFrameTimer() {
        frameTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(180), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self, let session = self.session else { return }
            do {
                let image = try session.takeFrame()
                DispatchQueue.main.async { self.frame = image }
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
        frameTimer = timer
        timer.resume()
    }

    deinit {
        frameTimer?.cancel()
        session?.close()
    }
}
