//
//  DeviceConnectionContext.swift
//  StikDebug
//
//  Created by Stephen.
//

import Foundation
import Darwin

struct DeviceConnectionSnapshot: @unchecked Sendable {
    let id: String
    let displayName: String
    let addresses: [Data]
    let pairingFileURL: URL
    let isRemote: Bool
    let stikServer: StikServerDeviceTarget?

    var isStikServer: Bool { stikServer != nil }
}

struct StikServerDeviceTarget: Sendable, Equatable {
    let serverAddress: String
    let token: String
    let deviceID: String
}

final class DeviceTargetManager: ObservableObject, @unchecked Sendable {
    static let shared = DeviceTargetManager()

    @Published private(set) var remoteDeviceName: String?
    @Published private(set) var remoteDeviceSystemImage: String?
    @Published private(set) var selectedTargetID = "local"

    private let lock = NSLock()
    private var remoteSnapshot: DeviceConnectionSnapshot?

    private init() {}

    var isUsingRemoteDevice: Bool {
        lock.lock()
        defer { lock.unlock() }
        return remoteSnapshot != nil
    }

    func snapshot() -> DeviceConnectionSnapshot {
        lock.lock()
        let remote = remoteSnapshot
        lock.unlock()
        if let remote { return remote }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        let ip = DeviceConnectionContext.targetIPAddress
        _ = ip.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        let data = withUnsafeBytes(of: address) { Data($0) }
        return DeviceConnectionSnapshot(
            id: "local|\(ip)",
            displayName: "This \(DevicePresentation.localKind)",
            addresses: [data],
            pairingFileURL: PairingFileStore.prepareURL(),
            isRemote: false,
            stikServer: nil
        )
    }

    func selectRemoteDevice(_ device: NearbyDevelopmentDevice, pairingFileURL: URL) {
        clearLocationBeforeTargetChange()
        let snapshot = DeviceConnectionSnapshot(
            id: device.id,
            displayName: device.name,
            addresses: device.addresses,
            pairingFileURL: pairingFileURL,
            isRemote: true,
            stikServer: nil
        )
        lock.lock()
        remoteSnapshot = snapshot
        lock.unlock()
        publishTargetChange(id: device.id, name: device.name, systemImage: device.systemImage)
    }

    func selectStikServerDevice(_ device: StikServerDevice, serverAddress: String, token: String) {
        clearLocationBeforeTargetChange()
        let snapshot = DeviceConnectionSnapshot(
            id: "stikserver|\(device.id)",
            displayName: device.name,
            addresses: [],
            pairingFileURL: PairingFileStore.prepareURL(),
            isRemote: true,
            stikServer: StikServerDeviceTarget(
                serverAddress: serverAddress,
                token: token,
                deviceID: device.id
            )
        )
        lock.lock()
        remoteSnapshot = snapshot
        lock.unlock()
        publishTargetChange(
            id: snapshot.id,
            name: device.name,
            systemImage: device.systemImage,
            needsLocalTunnel: false
        )
    }

    func selectThisDevice() {
        clearLocationBeforeTargetChange()
        lock.lock()
        let changed = remoteSnapshot != nil
        remoteSnapshot = nil
        lock.unlock()
        guard changed else { return }
        publishTargetChange(id: "local", name: nil, systemImage: nil)
    }

    private func publishTargetChange(id: String, name: String?, systemImage: String?, needsLocalTunnel: Bool = true) {
        let update = {
            self.selectedTargetID = id
            self.remoteDeviceName = name
            self.remoteDeviceSystemImage = systemImage
            JITEnableContext.shared.invalidateTunnel()
            markTunnelDisconnected()
            MountingProgress.shared.resetForTargetChange()
            NotificationCenter.default.post(name: .deviceTargetChanged, object: nil)
            if needsLocalTunnel { startTunnelInBackground(showErrorUI: false) }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func clearLocationBeforeTargetChange() {
        let current = snapshot()
        if let relay = current.stikServer {
            Task { @MainActor in
                StikServerConnection.shared.command("clearLocation", deviceID: relay.deviceID)
            }
            return
        }
        LocationSimulationCommandQueue.shared.sync {
            _ = clear_simulated_location()
        }
    }
}

extension Notification.Name {
    static let stopRemoteMirroring = Notification.Name("StikDebug.stopRemoteMirroring")
}

enum DeviceConnectionContext {
    static let defaultTargetIPAddress = "10.7.0.1"

    static var targetIPAddress: String {
        let stored = UserDefaults.standard
            .string(forKey: UserDefaults.Keys.targetDeviceIP)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else {
            return defaultTargetIPAddress
        }
        return stored
    }

    static var current: DeviceConnectionSnapshot {
        DeviceTargetManager.shared.snapshot()
    }
}
