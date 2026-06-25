import SwiftUI

private struct GlassEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))
        } else {
            content
        }
    }
}

struct BlueToggle: View {
    @Binding var isOn: Bool
    // Local state drives the visuals so the animation is never caught
    // by a global re-render triggered by the binding update.
    @State private var visualOn: Bool = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(visualOn ? Color.blue : Color(NSColor.tertiaryLabelColor).opacity(0.35))
                .animation(.easeInOut(duration: 0.15), value: visualOn)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                .frame(width: 20, height: 20)
                .offset(x: visualOn ? 10 : -10)
                .animation(.spring(response: 0.2, dampingFraction: 0.75), value: visualOn)
        }
        .frame(width: 44, height: 24)
        .clipShape(Capsule())
        .onTapGesture {
            visualOn.toggle()
            // Push binding update to the next cycle so it doesn't join
            // the current animation transaction.
            let newValue = visualOn
            DispatchQueue.main.async { isOn = newValue }
        }
        .onAppear { visualOn = isOn }
        .onChange(of: isOn) { newValue in
            if visualOn != newValue { visualOn = newValue }
        }
    }
}

struct MenuContentView: View {
    @ObservedObject var controller: FanController
    let onEditCurves: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if controller.fanCount == 0 {
                noFanView
            } else {
                modeToggle
                Divider()
                statsHeader
                Divider()
                if !controller.isAutoMode {
                    maxFanRow
                    if !controller.isMaxFan {
                        Divider()
                        profilePicker
                    }
                }
                if !controller.writePermissionOK {
                    Divider()
                    permissionWarning
                }
                Divider()
                actionRow
            }
        }
        .frame(width: 290)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
        .modifier(GlassEffectModifier())
    }

    // MARK: - Stats

    private var statsHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                statRow(icon: "thermometer.medium", label: controller.store.tempSensor.rawValue, value: "\(Int(controller.activeTemp))°C")
                statRow(icon: "fan", label: controller.fanCount > 1 ? "Fan 0" : "Fan", value: "\(Int(controller.fan0RPM)) RPM")
                if controller.fanCount > 1 {
                    statRow(icon: "fan", label: "Fan 1", value: "\(Int(controller.fan1RPM)) RPM")
                }
                if !controller.isAutoMode {
                    statRow(icon: "target", label: "Target", value: "\(Int(controller.commandedRPM)) RPM")
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            temperatureGauge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundColor(.secondary)
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.system(size: 12))
    }

    private var temperatureGauge: some View {
        let temp = controller.activeTemp
        let frac = (temp - 30) / (95 - 30)
        let clamped = max(0, min(1, frac))
        let color: Color = clamped < 0.4 ? .green : clamped < 0.7 ? .yellow : .red

        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(temp))°")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
        .frame(width: 52, height: 52)
        .animation(.easeInOut(duration: 0.5), value: temp)
    }

    // MARK: - Mode toggle

    private var modeToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("FanCurve control")
                    .font(.system(size: 12))
                Text("Override macOS fan management")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            BlueToggle(isOn: Binding(
                get: { !controller.isAutoMode },
                set: { controller.setAutoMode(!$0) }
            ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Max Fan

    private var maxFanRow: some View {
        Button(action: { controller.setMaxFan(!controller.isMaxFan) }) {
            HStack(spacing: 6) {
                Image(systemName: "fan.fill")
                    .frame(width: 16)
                    .foregroundColor(controller.isMaxFan ? .red : .secondary)
                Text("Max Fan")
                    .font(.system(size: 12))
                    .foregroundColor(controller.isMaxFan ? .red : .primary)
                Spacer()
                if controller.isMaxFan {
                    Text("\(Int(controller.fanMax)) RPM")
                        .font(.caption)
                        .foregroundColor(.red)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(controller.isMaxFan ? Color.red.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Profile picker

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Profile")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 4)

            ForEach(controller.store.profiles) { profile in
                profileRow(profile)
            }
            .padding(.bottom, 5)
        }
    }

    private func profileRow(_ profile: FanProfile) -> some View {
        let isActive = controller.store.activeProfileID == profile.id
        return Button(action: {
            controller.store.activeProfileID = profile.id
            controller.store.save()
            controller.applyProfile()
        }) {
            HStack {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isActive ? .accentColor : .secondary)
                Text(profile.name)
                    .font(.system(size: 12))
                Spacer()
                if isActive {
                    Text("\(Int(controller.commandedRPM)) RPM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Permission warning

    private var permissionWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            VStack(alignment: .leading) {
                Text("Daemon not running")
                    .font(.caption).bold()
                Text("Run install.sh to install the daemon")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - No fan

    private var noFanView: some View {
        VStack(spacing: 8) {
            Image(systemName: "fan.slash")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No fans detected")
                .font(.system(size: 13, weight: .semibold))
            Text("This Mac appears to be fanless.")
                .font(.caption)
                .foregroundColor(.secondary)
            Divider().padding(.top, 4)
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit FanCurve", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
        .padding(16)
    }

    // MARK: - Action row

    private var actionRow: some View {
        VStack(spacing: 0) {
            Button(action: onEditCurves) {
                Label("Edit Curves…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            Divider()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit FanCurve", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
    }
}
