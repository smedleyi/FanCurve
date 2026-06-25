import Foundation
import AppKit

@MainActor
final class FanController: ObservableObject {
    @Published var cpuTemp: Double = 0
    @Published var gpuTemp: Double = 0
    @Published var fan0RPM: Double = 0
    @Published var fan1RPM: Double = 0
    @Published var fanCount: Int = 0
    @Published var fanMin: Double = 1200
    @Published var fanMax: Double = 7826
    @Published var isAutoMode: Bool = false
    @Published var isMaxFan:  Bool = false
    @Published var store: ProfileStore
    @Published var writePermissionOK: Bool = true  // false if smc writes fail

    // RPM we last commanded
    private(set) var commandedRPM: Double = 0

    // Hysteresis: stays true until temp drops 10°C below safetyTemp
    private var safetyActive: Bool = false

    // EMA state for temperature smoothing (α=0.25 → ~16s half-life at 4s tick)
    private var smoothedCPU: Double? = nil
    private var smoothedGPU: Double? = nil
    private let tempAlpha = 0.25

    private var timer: Timer?

    init() {
        fanCount = SMC.fanCount()
        fanMin   = SMC.fanMin(0)
        let hwMax = SMC.fanMax(0)
        fanMax   = hwMax
        store    = ProfileStore(fanMax: hwMax)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Called every 4 s

    func tick() {
        refresh()
        guard !isAutoMode else { return }
        if isMaxFan { writeAllFans(fanMax) } else { applyProfile() }
    }

    private func writeAllFans(_ rpm: Double) {
        commandedRPM = rpm
        SMC.setTargetRPM(rpm)
    }

    // Read sensors only
    func refresh() {
        let rawCPU = SMC.cpuTemp()
        smoothedCPU = smoothedCPU.map { tempAlpha * rawCPU + (1 - tempAlpha) * $0 } ?? rawCPU
        cpuTemp = smoothedCPU ?? rawCPU

        let rawGPU = SMC.gpuTemp()
        if rawGPU > 0 {
            smoothedGPU = smoothedGPU.map { tempAlpha * rawGPU + (1 - tempAlpha) * $0 } ?? rawGPU
            gpuTemp = smoothedGPU ?? rawGPU
        }

        fan0RPM = SMC.fanSpeed(0)
        if fanCount > 1 { fan1RPM = SMC.fanSpeed(1) }
    }

    var activeTemp: Double {
        switch store.tempSensor {
        case .cpuAvg:    return cpuTemp
        case .gpuAvg:    return gpuTemp > 0 ? gpuTemp : cpuTemp
        case .cpuGpuAvg: return gpuTemp > 0 ? (cpuTemp + gpuTemp) / 2 : cpuTemp
        case .cpuGpuMax: return gpuTemp > 0 ? max(cpuTemp, gpuTemp) : cpuTemp
        }
    }

    // Compute target from curve and write to SMC
    func applyProfile() {
        let temp = activeTemp
        if temp >= store.safetyTemp {
            safetyActive = true
        } else if safetyActive && temp < store.safetyTemp - 10 {
            safetyActive = false
        }
        let curveRPM = store.activeProfile.targetRPM(at: temp)
        let effectiveCap = store.activeProfile.maxFanSpeed ?? fanMax
        let raw = safetyActive ? fanMax : min(curveRPM, effectiveCap)
        // Anything below the hardware minimum has no effect, so hand back to thermalmonitord
        let target = (raw > 0 && raw < fanMin) ? 0 : raw
        let delta = target - commandedRPM
        guard safetyActive || delta > 50 || delta < -200 || commandedRPM == 0 || target == 0 else { return }
        commandedRPM = target
        if target == 0 {
            writePermissionOK = true
            SMC.resetTargetRPM()
        } else {
            writePermissionOK = SMC.setTargetRPM(target)
        }
    }

    func setAutoMode(_ auto: Bool) {
        isAutoMode = auto
        isMaxFan = false
        safetyActive = false
        if auto {
            SMC.resetTargetRPM()
            commandedRPM = fanMin
        } else {
            applyProfile()
        }
    }

    func setMaxFan(_ on: Bool) {
        isMaxFan = on
        if on {
            isAutoMode = false
            writeAllFans(fanMax)
        } else {
            smoothedCPU = nil; smoothedGPU = nil  // reset EMA so next tick re-reads fresh temp
            safetyActive = false
            applyProfile()
        }
    }
}
