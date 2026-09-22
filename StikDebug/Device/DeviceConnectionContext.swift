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
}

final class DeviceTargetManager: ObservableObject, @unchecked Sendable {
    static let shared = DeviceTargetManager()

    @Published private(set) var remoteDeviceName: String?

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
            displayName: "This Device",
            addresses: [data],
            pairingFileURL: PairingFileStore.prepareURL(),
            isRemote: false
        )
    }

    func selectRemoteDevice(_ device: NearbyDevelopmentDevice, pairingFileURL: URL) {
        clearLocationBeforeTargetChange()
        let snapshot = DeviceConnectionSnapshot(
            id: device.id,
            displayName: device.name,
            addresses: device.addresses,
            pairingFileURL: pairingFileURL,
            isRemote: true
        )
        lock.lock()
        remoteSnapshot = snapshot
        lock.unlock()
        publishTargetChange(name: device.name)
    }

    func selectThisDevice() {
        clearLocationBeforeTargetChange()
        lock.lock()
        let changed = remoteSnapshot != nil
        remoteSnapshot = nil
        lock.unlock()
        guard changed else { return }
        publishTargetChange(name: nil)
    }

    private func publishTargetChange(name: String?) {
        let update = {
            self.remoteDeviceName = name
            JITEnableContext.shared.invalidateTunnel()
            markTunnelDisconnected()
            MountingProgress.shared.resetForTargetChange()
            NotificationCenter.default.post(name: .deviceTargetChanged, object: nil)
            startTunnelInBackground(showErrorUI: false)
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func clearLocationBeforeTargetChange() {
        LocationSimulationCommandQueue.shared.sync {
            _ = clear_simulated_location()
        }
    }
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
