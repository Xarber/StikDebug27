//
//  DeviceEnvironmentView.swift
//  StikDebug
//

import SwiftUI

struct DeviceEnvironmentView: View {
    @ObservedObject private var target = DeviceTargetManager.shared
    @State private var appearance: DeviceAppearance?
    @State private var liquidGlassOpacity = 1.0
    @State private var textSize = DeviceTextSize.large.rawValue
    @State private var colorFilterEnabled = false
    @State private var colorFilterType = DeviceColorFilterType.grayscale.rawValue
    @State private var colorFilterIntensity = 1.0
    @State private var reduceMotion = false
    @State private var reduceTransparency = false
    @State private var showLayoutBorders = false
    @State private var groups: [DeviceConditionGroup] = []
    @State private var activeProfileID: String?
    @State private var isLoading = false
    @State private var pendingAction: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Target") {
                LabeledContent("Device", value: target.remoteDeviceName ?? "This \(DevicePresentation.localKind)")
                Text("Appearance and conditions are applied to the command target selected in Nearby Device Control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                if let appearance {
                    Picker("Appearance", selection: Binding(
                        get: { appearance },
                        set: { setAppearance($0) }
                    )) {
                        ForEach(DeviceAppearance.allCases) { style in
                            Label(style.title, systemImage: style.systemImage).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(pendingAction != nil)
                } else {
                    HStack {
                        ProgressView()
                        Text("Reading appearance…").foregroundStyle(.secondary)
                    }
                }

                Picker("Text Size", selection: $textSize) {
                    if !DeviceTextSize.allCases.contains(where: { $0.rawValue == textSize }) {
                        Text(textSize).tag(textSize)
                    }
                    ForEach(DeviceTextSize.allCases) { size in
                        Text(size.title).tag(size.rawValue)
                    }
                }
                .disabled(pendingAction != nil)
                .onChange(of: textSize) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    applyTextSize(newValue, previous: oldValue)
                }

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Liquid Glass Opacity", value: liquidGlassOpacity.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $liquidGlassOpacity, in: 0 ... 1, step: 0.05)
                    Button("Apply Liquid Glass Opacity") { applyLiquidGlassOpacity() }
                        .buttonStyle(.bordered)
                        .disabled(pendingAction != nil)
                    Text("The device service can set this value but cannot read its current value.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Accessibility Appearance") {
                Toggle("Reduce Motion", isOn: Binding(
                    get: { reduceMotion },
                    set: { setFlag("reduceMotion", value: $0, current: reduceMotion, setter: JITEnableContext.shared.setReduceMotion) }
                ))
                Toggle("Reduce Transparency", isOn: Binding(
                    get: { reduceTransparency },
                    set: { setFlag("reduceTransparency", value: $0, current: reduceTransparency, setter: JITEnableContext.shared.setReduceTransparency) }
                ))

                Toggle("Color Filter", isOn: Binding(
                    get: { colorFilterEnabled },
                    set: { setColorFilter(enabled: $0) }
                ))

                if colorFilterEnabled {
                    Picker("Filter", selection: $colorFilterType) {
                        if !DeviceColorFilterType.allCases.contains(where: { $0.rawValue == colorFilterType }) {
                            Text(colorFilterType).tag(colorFilterType)
                        }
                        ForEach(DeviceColorFilterType.allCases) { filter in
                            Text(filter.title).tag(filter.rawValue)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Intensity", value: colorFilterIntensity.formatted(.percent.precision(.fractionLength(0))))
                        Slider(value: $colorFilterIntensity, in: 0 ... 1, step: 0.05)
                    }
                    Button("Apply Color Filter") { setColorFilter(enabled: true) }
                        .buttonStyle(.bordered)
                }

                LabeledContent("Increase Contrast") {
                    HStack {
                        Button("Off") { setIncreaseContrast(false) }
                        Button("On") { setIncreaseContrast(true) }
                    }
                    .buttonStyle(.bordered)
                }
                Text("The device service can change Increase Contrast but cannot report its current state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(pendingAction != nil)

            Section {
                Toggle("Show Layout Borders", isOn: Binding(
                    get: { showLayoutBorders },
                    set: { setFlag("borders", value: $0, current: showLayoutBorders, setter: JITEnableContext.shared.setShowLayoutBorders) }
                ))
            } header: {
                Text("Developer Visuals")
            } footer: {
                Text("Draws debugging borders around interface layout regions on the target device.")
            }
            .disabled(pendingAction != nil)

            Section {
                if groups.isEmpty, !isLoading {
                    ContentUnavailableView(
                        "No Conditions Available",
                        systemImage: "gauge.with.dots.needle.33percent",
                        description: Text("This iOS version did not advertise any developer condition profiles.")
                    )
                }

                ForEach(groups) { group in
                    DisclosureGroup(group.title) {
                        ForEach(group.profiles) { profile in
                            Button { enable(profile) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.detail).foregroundStyle(.primary)
                                        if profile.detail != profile.identifier {
                                            Text(profile.identifier)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if activeProfileID == profile.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else if pendingAction == profile.id {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(pendingAction != nil)
                        }
                    }
                }
            } header: {
                Text("Network & Performance Conditions")
            } footer: {
                Text("These are the same developer condition profiles advertised to Xcode. Available network and performance throttles depend on the target device and iOS version.")
            }

            if activeProfileID != nil {
                Section {
                    Button("Stop Active Condition", role: .destructive) { disableCondition() }
                        .disabled(pendingAction != nil)
                }
            }
        }
        .navigationTitle("Device Environment")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading { ProgressView("Loading conditions…") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading || pendingAction != nil)
            }
        }
        .task(id: target.selectedTargetID) { load() }
        .alert("Device Environment", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        appearance = nil
        Task.detached {
            do {
                let configuration = try JITEnableContext.shared.currentDeviceConfiguration()
                let conditions = try JITEnableContext.shared.availableDeviceConditions()
                await MainActor.run {
                    appearance = configuration.appearance
                    if let value = configuration.textSize { textSize = value }
                    if let value = configuration.colorFilterEnabled { colorFilterEnabled = value }
                    if let value = configuration.colorFilterType { colorFilterType = value }
                    if let value = configuration.colorFilterIntensity { colorFilterIntensity = value }
                    if let value = configuration.reduceMotion { reduceMotion = value }
                    if let value = configuration.reduceTransparency { reduceTransparency = value }
                    if let value = configuration.showBorders { showLayoutBorders = value }
                    groups = conditions
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func setAppearance(_ style: DeviceAppearance) {
        let previous = appearance
        appearance = style
        pendingAction = "appearance"
        Task.detached {
            do {
                try JITEnableContext.shared.setDeviceAppearance(style)
                await MainActor.run { pendingAction = nil }
            } catch {
                await MainActor.run {
                    appearance = previous
                    pendingAction = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func applyLiquidGlassOpacity() {
        let value = liquidGlassOpacity
        performSetting("glass") {
            try JITEnableContext.shared.setLiquidGlassOpacity(value)
        }
    }

    private func applyTextSize(_ value: String, previous: String) {
        performSetting("textSize", onFailure: { textSize = previous }) {
            try JITEnableContext.shared.setDeviceTextSize(value)
        }
    }

    private func setColorFilter(enabled: Bool) {
        let previous = colorFilterEnabled
        colorFilterEnabled = enabled
        let type = colorFilterType
        let intensity = colorFilterIntensity
        performSetting("colorFilter", onFailure: { colorFilterEnabled = previous }) {
            try JITEnableContext.shared.setDeviceColorFilter(enabled: enabled, type: type, intensity: intensity)
        }
    }

    private func setIncreaseContrast(_ enabled: Bool) {
        performSetting("contrast") {
            try JITEnableContext.shared.setIncreaseContrast(enabled)
        }
    }

    private func setFlag(
        _ key: String,
        value: Bool,
        current: Bool,
        setter: @escaping (Bool) throws -> Void
    ) {
        switch key {
        case "reduceMotion": reduceMotion = value
        case "reduceTransparency": reduceTransparency = value
        case "borders": showLayoutBorders = value
        default: break
        }
        performSetting(key, onFailure: {
            switch key {
            case "reduceMotion": reduceMotion = current
            case "reduceTransparency": reduceTransparency = current
            case "borders": showLayoutBorders = current
            default: break
            }
        }) {
            try setter(value)
        }
    }

    private func performSetting(
        _ key: String,
        onFailure: @escaping @MainActor () -> Void = {},
        operation: @escaping () throws -> Void
    ) {
        pendingAction = key
        Task.detached {
            do {
                try operation()
                await MainActor.run { pendingAction = nil }
            } catch {
                await MainActor.run {
                    onFailure()
                    pendingAction = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func enable(_ profile: DeviceConditionProfile) {
        pendingAction = profile.id
        Task.detached {
            do {
                try JITEnableContext.shared.enableDeviceCondition(profile)
                await MainActor.run {
                    activeProfileID = profile.id
                    pendingAction = nil
                }
            } catch {
                await MainActor.run {
                    pendingAction = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func disableCondition() {
        pendingAction = "disable"
        Task.detached {
            do {
                try JITEnableContext.shared.disableDeviceCondition()
                await MainActor.run {
                    activeProfileID = nil
                    pendingAction = nil
                }
            } catch {
                await MainActor.run {
                    pendingAction = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
