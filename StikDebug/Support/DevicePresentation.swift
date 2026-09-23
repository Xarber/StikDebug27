//
//  DevicePresentation.swift
//  StikDebug
//

import UIKit

enum DevicePresentation {
    static var localKind: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    static var localControllerName: String {
        "StikDebug on \(localKind)"
    }

    static var localSystemImage: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    static func kind(forModelIdentifier modelIdentifier: String?) -> String {
        guard let modelIdentifier else { return "Device" }
        if modelIdentifier.hasPrefix("iPad") { return "iPad" }
        if modelIdentifier.hasPrefix("iPhone") { return "iPhone" }
        if modelIdentifier.hasPrefix("iPod") { return "iPod touch" }
        if modelIdentifier.hasPrefix("AppleTV") { return "Apple TV" }
        return "Device"
    }

    static func systemImage(forModelIdentifier modelIdentifier: String?, connected: Bool = false) -> String {
        let kind = kind(forModelIdentifier: modelIdentifier)
        switch kind {
        case "iPad": return "ipad"
        case "Apple TV": return "appletv"
        case "iPhone": return connected ? "iphone.gen3.radiowaves.left.and.right" : "iphone"
        default: return "ipad.and.iphone"
        }
    }
}
