//
//  AppFeature.swift
//  StikDebug
//

import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable {
    case home
    case scripts
    case tools
    case devices
    case console
    case deviceInfo = "deviceinfo"
    case profiles
    case processes
    case location
    case advancedTools = "advanced-tools"
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .home:
            return "Apps"
        case .scripts:
            return "Scripts"
        case .tools:
            return "Tools"
        case .devices:
            return "Devices"
        case .console:
            return "Console"
        case .deviceInfo:
            return "Device Info"
        case .profiles:
            return "App Expiry"
        case .processes:
            return "Processes"
        case .location:
            return "Location"
        case .advancedTools:
            return "Advanced Tools"
        case .settings:
            return "Settings"
        }
    }

    var detail: String {
        switch self {
        case .home:
            return "Manage installed apps"
        case .scripts:
            return "Manage and run JS scripts"
        case .tools:
            return "Access additional tools"
        case .devices:
            return "Pair, view, and control nearby devices"
        case .console:
            return "Live device logs"
        case .deviceInfo:
            return "View detailed device metadata"
        case .profiles:
            return "Check app expiration dates"
        case .processes:
            return "Inspect running apps"
        case .location:
            return "Simulate GPS location"
        case .advancedTools:
            return "Files, captures, crash reports, and device controls"
        case .settings:
            return "Configure StikDebug"
        }
    }

    var toolTitle: String {
        switch self {
        case .location:
            return "Location Simulation"
        case .advancedTools:
            return "Advanced Tools"
        default:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "square.grid.2x2"
        case .scripts:
            return "scroll"
        case .tools:
            return "wrench.and.screwdriver"
        case .devices:
            return "iphone.gen3.radiowaves.left.and.right"
        case .console:
            return "terminal"
        case .deviceInfo:
            return "iphone.and.arrow.forward"
        case .profiles:
            return "calendar.badge.clock"
        case .processes:
            return "rectangle.stack.person.crop"
        case .location:
            return "location"
        case .advancedTools:
            return "wrench.and.screwdriver"
        case .settings:
            return "gearshape.fill"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .home:
            HomeView()
        case .scripts:
            ScriptListView()
        case .tools:
            ToolsView()
        case .devices:
            NavigationStack { NearbyDeviceControlView() }
        case .console:
            ConsoleLogsView()
        case .deviceInfo:
            DeviceInfoView()
        case .profiles:
            ProfileView()
        case .processes:
            ProcessInspectorView()
        case .location:
            LocationSimulationView()
        case .advancedTools:
            AdvancedToolsView()
        case .settings:
            SettingsView()
        }
    }
}

extension AppFeature {
    static let mainTabs: [AppFeature] = [.home, .tools, .devices, .settings]
    static let toolList: [AppFeature] = [.scripts, .console, .deviceInfo, .profiles, .processes, .location, .advancedTools]
}
