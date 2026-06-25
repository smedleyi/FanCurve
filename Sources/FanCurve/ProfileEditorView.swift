import SwiftUI
import AppKit

struct ProfileEditorView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var controller: FanController
    let onDismiss: () -> Void

    @State private var selectedID: UUID
    @State private var editingName: Bool = false
    @State private var draftName: String = ""
    @FocusState private var isNameFieldFocused: Bool
    @State private var chartSaveTask: Task<Void, Never>? = nil
    @State private var maxSpeedText: String = ""
    @FocusState private var maxSpeedFocused: Bool

    init(store: ProfileStore, controller: FanController, onDismiss: @escaping () -> Void) {
        self.store = store
        self.controller = controller
        self.onDismiss = onDismiss
        _selectedID = State(initialValue: store.activeProfileID)
    }

    private var selectedIndex: Int {
        store.profiles.firstIndex { $0.id == selectedID } ?? 0
    }

    private var profile: FanProfile { store.profiles[selectedIndex] }

    var body: some View {
        HStack(spacing: 0) {
            profileList
                .frame(width: 140)
            Divider()
            VStack(spacing: 0) {
                editorHeader
                Divider()
                chartSection
                Divider()
                pointsTable
                Divider()
                footer
            }
        }
        .frame(width: 640, height: 490)
        .modifier(PanelBackground())
        .onExitCommand { onDismiss() }
    }

    // MARK: - Left: profile list

    private var profileList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.profiles) { p in
                        let isSelected = selectedID == p.id
                        Button(action: {
                            selectedID = p.id
                            store.activeProfileID = p.id
                            store.save()
                            if !controller.isAutoMode { controller.applyProfile() }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .accentColor : .secondary)
                                Text(p.name)
                                    .font(.system(size: 12))
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.primary)
                    }
                }
                .padding(.top, 20)
            }

            Divider()

            HStack(spacing: 0) {
                Button(action: addProfile) {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(6)

                Divider().frame(height: 24)

                Button(action: deleteProfile) {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(6)
                .disabled(store.profiles.count <= 1 || (store.profiles.first { $0.id == selectedID }?.isBuiltIn == true))
                .help(store.profiles.first { $0.id == selectedID }?.isBuiltIn == true ? "Built-in profiles can't be deleted" : "")
            }

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("Control Sensor")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 4)
                ForEach(TempSensor.allCases) { sensor in
                    let temp = sensorTemp(sensor)
                    Button(action: {
                        store.tempSensor = sensor
                        store.save()
                        if !controller.isAutoMode { controller.applyProfile() }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: store.tempSensor == sensor ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(store.tempSensor == sensor ? .accentColor : .secondary)
                                .font(.system(size: 10))
                            Text(sensor.rawValue)
                                .font(.system(size: 10))
                            Spacer()
                            if temp > 0 {
                                Text("\(Int(temp))°")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 0) {
                Text("Max Speed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 6)
                HStack(spacing: 0) {
                    Button("−") {
                        let current = profile.maxFanSpeed ?? controller.fanMax
                        store.profiles[selectedIndex].maxFanSpeed = max(controller.fanMin, (current - 200).rounded(.toNearestOrAwayFromZero))
                        store.save()
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                    TextField("Max", text: $maxSpeedText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 11).monospacedDigit())
                        .focused($maxSpeedFocused)
                        .onAppear { maxSpeedText = profile.maxFanSpeed.map { "\(Int($0))" } ?? "" }
                        .onChange(of: profile.maxFanSpeed) { _, v in
                            guard !maxSpeedFocused else { return }
                            maxSpeedText = v.map { "\(Int($0))" } ?? ""
                        }
                        .onSubmit { commitMaxSpeed() }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                        .frame(maxWidth: .infinity)
                    Button("+") {
                        guard let current = profile.maxFanSpeed else { return }
                        let next = current + 200
                        store.profiles[selectedIndex].maxFanSpeed = next >= controller.fanMax ? nil : next
                        store.save()
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                    .disabled(profile.maxFanSpeed == nil)
                }
            }
            .id(selectedID)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 0) {
                Text("Safety")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 6)
                HStack(spacing: 0) {
                    Button("−") {
                        store.safetyTemp = max(70, store.safetyTemp - 5)
                        store.save()
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                    Text("\(Int(store.safetyTemp))°C")
                        .font(.system(size: 11).monospacedDigit())
                        .frame(maxWidth: .infinity)
                    Button("+") {
                        store.safetyTemp = min(105, store.safetyTemp + 5)
                        store.save()
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

        }
    }

    // MARK: - Header (profile name)

    private var editorHeader: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                TextField("Profile name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($isNameFieldFocused)
                    .onSubmit { commitName() }
                    .onExitCommand { editingName = false }
                    .opacity(editingName ? 1 : 0)
                    .allowsHitTesting(editingName)

                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(editingName ? 0 : 1)
                    .onTapGesture(count: 2) {
                        draftName = profile.name
                        editingName = true
                        isNameFieldFocused = true
                    }
            }

            Spacer()

            let temp = sensorTemp(store.tempSensor)
            let avgRPM = controller.fanCount > 1
                ? (controller.fan0RPM + controller.fan1RPM) / 2
                : controller.fan0RPM
            if temp > 0 {
                Text("\(store.tempSensor.rawValue)  \(Int(temp))°C  ·  \(Int(avgRPM)) RPM")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .onChange(of: isNameFieldFocused) { _, focused in
            if !focused && editingName { commitName() }
        }
    }

    // MARK: - Points table

    private var pointsTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Temperature").bold()
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text("Fan Speed").bold()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)

                    Divider()

                    ForEach(store.profiles[selectedIndex].points.sorted(by: { $0.tempC < $1.tempC })) { pt in
                        let locked = pt.isLocked
                        PointRow(
                            point: binding(for: pt.id),
                            fanMax: controller.fanMax,
                            isLocked: locked
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .contextMenu {
                            if !locked {
                                Button(role: .destructive) {
                                    store.profiles[selectedIndex].points.removeAll { $0.id == pt.id }
                                    store.save()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 142)

            HStack {
                Button("+ Add Point") {
                    let last = store.profiles[selectedIndex].points.max(by: { $0.tempC < $1.tempC })
                    let newTemp = min((last?.tempC ?? 50) + 10, 104)
                    let newRPM  = last?.rpm ?? 3000
                    store.profiles[selectedIndex].points.append(CurvePoint(tempC: newTemp, rpm: newRPM))
                    store.save()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
                .font(.caption)
                Spacer()
                Text("Drag points on chart to adjust")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 5)
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        CurveChart(
            points: Binding(
                get: { store.profiles[selectedIndex].points },
                set: {
                    store.profiles[selectedIndex].points = $0
                    chartSaveTask?.cancel()
                    chartSaveTask = Task {
                        do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                        store.save()
                    }
                }
            ),
            fanMin: controller.fanMin,
            fanMax: controller.fanMax,
            currentTemp: sensorTemp(store.tempSensor),
            currentRPM: controller.fan0RPM,
            maxFanSpeed: profile.maxFanSpeed
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 240)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Default") {
                let defs = FanProfile.defaults(fanMax: controller.fanMax)
                let match = defs.first { $0.name == profile.name } ?? defs[1]
                store.profiles[selectedIndex].points = match.points
                store.save()
            }

            Spacer()

            Button("Done") {
                store.save()
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func sensorTemp(_ sensor: TempSensor) -> Double {
        switch sensor {
        case .cpuAvg:    return controller.cpuTemp
        case .gpuAvg:    return controller.gpuTemp
        case .cpuGpuAvg: return controller.gpuTemp > 0 ? (controller.cpuTemp + controller.gpuTemp) / 2 : controller.cpuTemp
        case .cpuGpuMax: return controller.gpuTemp > 0 ? max(controller.cpuTemp, controller.gpuTemp) : controller.cpuTemp
        }
    }

    private func binding(for id: UUID) -> Binding<CurvePoint> {
        Binding(
            get: {
                store.profiles[selectedIndex].points.first { $0.id == id } ?? CurvePoint(tempC: 0, rpm: 0)
            },
            set: { newVal in
                if let i = store.profiles[selectedIndex].points.firstIndex(where: { $0.id == id }) {
                    store.profiles[selectedIndex].points[i] = newVal
                    store.save()
                }
            }
        )
    }

    private func addProfile() {
        let base = FanProfile.defaultProfile(fanMax: controller.fanMax)
        let newProfile = FanProfile(
            name: "Custom \(store.profiles.count + 1)",
            points: base.points
        )
        store.profiles.append(newProfile)
        selectedID = newProfile.id
        store.save()
    }

    private func deleteProfile() {
        guard store.profiles.count > 1,
              let idx = store.profiles.firstIndex(where: { $0.id == selectedID }),
              !store.profiles[idx].isBuiltIn else { return }
        let deletedID = selectedID
        // Pick the adjacent profile before mutating so no render frame sees a stale selectedID
        let nextIdx = idx > 0 ? idx - 1 : 1
        let nextID = store.profiles[nextIdx].id
        selectedID = nextID
        if store.activeProfileID == deletedID { store.activeProfileID = nextID }
        store.profiles.remove(at: idx)
        store.save()
    }

    private func commitMaxSpeed() {
        let trimmed = maxSpeedText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            store.profiles[selectedIndex].maxFanSpeed = nil
        } else if let v = Double(trimmed) {
            let clamped = v.clamped(to: controller.fanMin...controller.fanMax)
            store.profiles[selectedIndex].maxFanSpeed = clamped >= controller.fanMax ? nil : clamped
        }
        let cap = profile.maxFanSpeed
        maxSpeedText = cap.map { "\(Int($0))" } ?? ""
        if cap == nil { maxSpeedFocused = false }
        store.save()
    }

    private func commitName() {
        guard !draftName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.profiles[selectedIndex].name = draftName.trimmingCharacters(in: .whitespaces)
        store.save()
        editingName = false
    }
}

// MARK: - Individual point row

private struct PointRow: View {
    @Binding var point: CurvePoint
    let fanMax: Double
    let isLocked: Bool

    @State private var tempText = ""
    @State private var rpmText  = ""

    private enum Field: Hashable { case temp, rpm }
    @FocusState private var focused: Field?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if isLocked {
                    Text("\(Int(point.tempC))")
                        .frame(width: 32, alignment: .leading)
                        .foregroundColor(.secondary)
                } else {
                    TextField("", text: $tempText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .focused($focused, equals: .temp)
                        .onAppear { tempText = "\(Int(point.tempC))" }
                        .onChange(of: point.tempC) { tempText = "\(Int($0))" }
                        .onSubmit { if let v = Double(tempText) { point.tempC = min(max(v, 0), 105) } }
                        .frame(width: 24)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                }
                Text("°C")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: 4) {
                TextField("", text: $rpmText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .focused($focused, equals: .rpm)
                    .onAppear { rpmText = "\(Int(point.rpm))" }
                    .onChange(of: point.rpm) { rpmText = "\(Int($0))" }
                    .onSubmit { if let v = Double(rpmText) { point.rpm = min(max(v, 0), fanMax) } }
                    .frame(width: 36)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                Text("RPM")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(.system(size: 11))
        .animation(nil, value: focused)
        .contentShape(Rectangle())
        .onTapGesture { focused = isLocked ? .rpm : .temp }
    }
}

