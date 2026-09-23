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

enum DeviceTextSize: String, CaseIterable, Identifiable {
    case extraSmall = "xSmall"
    case small
    case medium
    case large
    case extraLarge = "xLarge"
    case extraExtraLarge = "xxLarge"
    case extraExtraExtraLarge = "xxxLarge"
    case accessibilityMedium
    case accessibilityLarge
    case accessibilityExtraLarge = "accessibilityXLarge"
    case accessibilityExtraExtraLarge = "accessibilityXXLarge"
    case accessibilityExtraExtraExtraLarge = "accessibilityXXXLarge"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extraSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        case .extraExtraLarge: "Extra Extra Large"
        case .extraExtraExtraLarge: "Extra Extra Extra Large"
        case .accessibilityMedium: "Accessibility Medium"
        case .accessibilityLarge: "Accessibility Large"
        case .accessibilityExtraLarge: "Accessibility Extra Large"
        case .accessibilityExtraExtraLarge: "Accessibility XXL"
        case .accessibilityExtraExtraExtraLarge: "Accessibility XXXL"
        }
    }
}

enum DeviceColorFilterType: String, CaseIterable, Identifiable {
    case grayscale = "Grayscale"
    case protanopia = "Protanopia"
    case deuteranopia = "Deuteranopia"
    case tritanopia = "Tritanopia"
    case colorTint = "ColorTint"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grayscale: "Grayscale"
        case .protanopia: "Red/Green — Protanopia"
        case .deuteranopia: "Green/Red — Deuteranopia"
        case .tritanopia: "Blue/Yellow — Tritanopia"
        case .colorTint: "Color Tint"
        }
    }
}

struct DeviceConfigurationSnapshot {
    let appearance: DeviceAppearance?
    let colorFilterEnabled: Bool?
    let colorFilterType: String?
    let colorFilterIntensity: Double?
    let textSize: String?
    let reduceMotion: Bool?
    let reduceTransparency: Bool?
    let showBorders: Bool?
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
    func currentDeviceConfiguration() throws -> DeviceConfigurationSnapshot {
        try withConfigurationClient { client in
            var rawStyle = IdeviceUserInterfaceStyleLight
            var appearance: DeviceAppearance?
            if let error = configuration_service_get_user_interface_style(client, &rawStyle) {
                _ = IdeviceBridge.consumeFFIError(error, fallback: "Failed to read device appearance")
            } else {
                appearance = rawStyle == IdeviceUserInterfaceStyleDark ? .dark : .light
            }

            var rawFilter = ColorFilterC()
            var colorFilterEnabled: Bool?
            var colorFilterType: String?
            var colorFilterIntensity: Double?
            if let error = configuration_service_get_color_filter(client, &rawFilter) {
                _ = IdeviceBridge.consumeFFIError(error, fallback: "Failed to read color filter")
            } else {
                colorFilterEnabled = rawFilter.enabled != 0
                colorFilterType = IdeviceBridge.string(from: rawFilter.filter_type)
                colorFilterIntensity = rawFilter.has_intensity != 0 ? rawFilter.intensity : nil
            }
            if let value = rawFilter.filter_type { idevice_string_free(value) }

            var rawTextSize: UnsafeMutablePointer<CChar>?
            var textSize: String?
            if let error = configuration_service_get_device_text_size(client, &rawTextSize) {
                _ = IdeviceBridge.consumeFFIError(error, fallback: "Failed to read text size")
            } else {
                textSize = IdeviceBridge.string(from: rawTextSize)
            }
            if let rawTextSize { idevice_string_free(rawTextSize) }

            func readFlag(
                _ getter: (OpaquePointer, UnsafeMutablePointer<Int32>) -> UnsafeMutablePointer<IdeviceFfiError>?
            ) -> Bool? {
                var value: Int32 = 0
                if let error = getter(client, &value) {
                    _ = IdeviceBridge.consumeFFIError(error, fallback: "Failed to read device setting")
                    return nil
                }
                return value != 0
            }

            return DeviceConfigurationSnapshot(
                appearance: appearance,
                colorFilterEnabled: colorFilterEnabled,
                colorFilterType: colorFilterType,
                colorFilterIntensity: colorFilterIntensity,
                textSize: textSize,
                reduceMotion: readFlag(configuration_service_get_reduce_motion),
                reduceTransparency: readFlag(configuration_service_get_reduce_transparency),
                showBorders: readFlag(configuration_service_get_show_borders)
            )
        }
    }

    func setDeviceAppearance(_ appearance: DeviceAppearance) throws {
        try withConfigurationClient { client in
            let style = appearance == .dark
                ? IdeviceUserInterfaceStyleDark
                : IdeviceUserInterfaceStyleLight
            if let error = configuration_service_set_user_interface_style(client, style) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to change device appearance")
            }
        }
    }

    func setLiquidGlassOpacity(_ opacity: Double) throws {
        try withConfigurationClient { client in
            if let error = configuration_service_set_liquid_glass_opacity(client, Float(opacity)) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to change Liquid Glass opacity")
            }
        }
    }

    func setDeviceColorFilter(enabled: Bool, type: String, intensity: Double) throws {
        try withConfigurationClient { client in
            if let error = configuration_service_set_color_filter(
                client,
                enabled ? 1 : 0,
                enabled ? type : nil,
                Float(intensity),
                enabled ? 1 : 0
            ) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to change the color filter")
            }
        }
    }

    func setDeviceTextSize(_ size: String) throws {
        try withConfigurationClient { client in
            if let error = configuration_service_set_device_text_size(client, size) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Failed to change text size")
            }
        }
    }

    func setReduceMotion(_ enabled: Bool) throws {
        try setConfigurationFlag(enabled, fallback: "Failed to change Reduce Motion", setter: configuration_service_set_reduce_motion)
    }

    func setReduceTransparency(_ enabled: Bool) throws {
        try setConfigurationFlag(enabled, fallback: "Failed to change Reduce Transparency", setter: configuration_service_set_reduce_transparency)
    }

    func setShowLayoutBorders(_ enabled: Bool) throws {
        try setConfigurationFlag(enabled, fallback: "Failed to change layout borders", setter: configuration_service_set_show_borders)
    }

    func setIncreaseContrast(_ enabled: Bool) throws {
        try setConfigurationFlag(enabled, fallback: "Failed to change Increase Contrast", setter: configuration_service_set_increase_contrast)
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

    private func withConfigurationClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to device configuration",
                missingClientMessage: "Device configuration service was not created",
                connect: { configuration_service_connect_rsd(adapter, handshake, $0) },
                cleanup: { configuration_service_free($0) },
                body
            )
        }
    }

    private func setConfigurationFlag(
        _ enabled: Bool,
        fallback: String,
        setter: (OpaquePointer, Int32) -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws {
        try withConfigurationClient { client in
            if let error = setter(client, enabled ? 1 : 0) {
                throw IdeviceBridge.consumeFFIError(error, fallback: fallback)
            }
        }
    }
}
