//
//  DeviceEnvironmentServices.swift
//  StikDebug
//

import Foundation
import idevice

enum DeviceAppearance: Int, CaseIterable, Identifiable {
    case light = 0
    case dark = 1

    var id: Int { rawValue }
    var title: String { self == .light ? "Light" : "Dark" }
    var systemImage: String { self == .light ? "sun.max" : "moon" }
}

struct DeviceConditionProfile: Identifiable, Hashable {
    let groupIdentifier: String
    let identifier: String
    let detail: String

    var id: String { "\(groupIdentifier)|\(identifier)" }
}

struct DeviceConditionGroup: Identifiable, Hashable {
    let identifier: String
    let profiles: [DeviceConditionProfile]

    var id: String { identifier }

    var title: String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

extension JITEnableContext {
    func currentDeviceAppearance() throws -> DeviceAppearance {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to device configuration",
                missingClientMessage: "Device configuration service was not created",
                connect: { configuration_service_connect_rsd(adapter, handshake, $0) },
                cleanup: { configuration_service_free($0) }
            ) { client in
                var style = IdeviceUserInterfaceStyleLight
                if let error = configuration_service_get_user_interface_style(client, &style) {
                    throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to read device appearance")
                }
                return style == IdeviceUserInterfaceStyleDark ? .dark : .light
            }
        }
    }

    func setDeviceAppearance(_ appearance: DeviceAppearance) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to device configuration",
                missingClientMessage: "Device configuration service was not created",
                connect: { configuration_service_connect_rsd(adapter, handshake, $0) },
                cleanup: { configuration_service_free($0) }
            ) { client in
                let style = appearance == .dark
                    ? IdeviceUserInterfaceStyleDark
                    : IdeviceUserInterfaceStyleLight
                if let error = configuration_service_set_user_interface_style(client, style) {
                    throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to change device appearance")
                }
            }
        }
    }

    func availableDeviceConditions() throws -> [DeviceConditionGroup] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withRemoteServer(adapter: adapter, handshake: handshake) { server in
                try IdeviceBridge.withConnectedClient(
                    fallback: "Failed to connect to device conditions",
                    missingClientMessage: "Device conditions service was not created",
                    connect: { condition_inducer_new(server, $0) },
                    cleanup: { condition_inducer_free($0) }
                ) { client in
                    var rawGroups: UnsafeMutablePointer<UnsafeMutablePointer<IdeviceConditionGroup>?>?
                    var count: UInt = 0
                    if let error = condition_inducer_available_conditions(client, &rawGroups, &count) {
                        throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to load device conditions")
                    }
                    defer {
                        if let rawGroups { condition_inducer_groups_free(rawGroups, count) }
                    }
                    guard let rawGroups else { return [] }

                    return (0 ..< Int(count)).compactMap { groupIndex in
                        guard let groupPointer = rawGroups[groupIndex],
                              let groupID = IdeviceBridge.string(from: groupPointer.pointee.identifier),
                              !groupID.isEmpty else { return nil }
                        let group = groupPointer.pointee
                        guard let rawProfiles = group.profiles else {
                            return DeviceConditionGroup(identifier: groupID, profiles: [])
                        }
                        let profiles = (0 ..< Int(group.profiles_count)).compactMap { profileIndex -> DeviceConditionProfile? in
                            let profile = rawProfiles[profileIndex]
                            guard let profileID = IdeviceBridge.string(from: profile.identifier),
                                  !profileID.isEmpty else { return nil }
                            return DeviceConditionProfile(
                                groupIdentifier: groupID,
                                identifier: profileID,
                                detail: IdeviceBridge.string(from: profile.description) ?? profileID
                            )
                        }
                        return DeviceConditionGroup(identifier: groupID, profiles: profiles)
                    }
                    .filter { !$0.profiles.isEmpty }
                }
            }
        }
    }

    func enableDeviceCondition(_ profile: DeviceConditionProfile) throws {
        try withDeviceConditionClient { client in
            if let error = condition_inducer_enable(client, profile.groupIdentifier, profile.identifier) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to enable \(profile.detail)")
            }
        }
    }

    func disableDeviceCondition() throws {
        try withDeviceConditionClient { client in
            if let error = condition_inducer_disable(client) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to disable device conditions")
            }
        }
    }

    private func withDeviceConditionClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withRemoteServer(adapter: adapter, handshake: handshake) { server in
                try IdeviceBridge.withConnectedClient(
                    fallback: "Failed to connect to device conditions",
                    missingClientMessage: "Device conditions service was not created",
                    connect: { condition_inducer_new(server, $0) },
                    cleanup: { condition_inducer_free($0) },
                    body
                )
            }
        }
    }
}
