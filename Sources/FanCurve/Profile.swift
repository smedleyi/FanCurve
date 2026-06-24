import Foundation

enum TempSensor: String, Codable, CaseIterable, Identifiable {
    case cpuAvg    = "CPU Average"
    case gpuAvg    = "GPU Average"
    case cpuGpuAvg = "CPU + GPU"
    case cpuGpuMax = "CPU/GPU Max"
    var id: String { rawValue }
}

struct CurvePoint: Codable, Identifiable, Equatable {
    var id: UUID
    var tempC: Double  // degrees Celsius
    var rpm: Double    // fan speed in RPM
    var isLocked: Bool { tempC == 0 || tempC == 105 }

    init(tempC: Double, rpm: Double) {
        self.id = UUID()
        self.tempC = tempC
        self.rpm = rpm
    }
}

struct FanProfile: Codable, Identifiable {
    var id: UUID
    var name: String
    var points: [CurvePoint]  // must be sorted by tempC before use
    var isBuiltIn: Bool = false
    var maxFanSpeed: Double? = nil  // nil = no cap (use hardware max)

    init(name: String, points: [CurvePoint], isBuiltIn: Bool = false) {
        self.id = UUID()
        self.name = name
        self.points = points
        self.isBuiltIn = isBuiltIn
    }

    // Linear interpolation across the curve
    func targetRPM(at temp: Double) -> Double {
        let sorted = points.sorted { $0.tempC < $1.tempC }
        guard !sorted.isEmpty else { return 1200 }
        if temp <= sorted.first!.tempC { return sorted.first!.rpm }
        if temp >= sorted.last!.tempC  { return sorted.last!.rpm }
        for i in 0 ..< sorted.count - 1 {
            let lo = sorted[i], hi = sorted[i + 1]
            guard temp <= hi.tempC else { continue }
            let t = (temp - lo.tempC) / (hi.tempC - lo.tempC)
            return (lo.rpm + t * (hi.rpm - lo.rpm)).rounded()
        }
        return sorted.last!.rpm
    }

    static func defaultProfile(fanMax: Double) -> FanProfile { defaults(fanMax: fanMax)[1] }

    // Built-in default profiles — top RPM values scale to actual hardware max
    static func defaults(fanMax: Double) -> [FanProfile] { [
        FanProfile(name: "Silent", points: [
            CurvePoint(tempC: 0,   rpm: 0),
            CurvePoint(tempC: 45,  rpm: 0),
            CurvePoint(tempC: 55,  rpm: 1200),
            CurvePoint(tempC: 65,  rpm: 2000),
            CurvePoint(tempC: 75,  rpm: 3200),
            CurvePoint(tempC: 85,  rpm: 5000),
            CurvePoint(tempC: 95,  rpm: fanMax),
            CurvePoint(tempC: 105, rpm: fanMax),
        ], isBuiltIn: true),
        FanProfile(name: "Balanced", points: [
            CurvePoint(tempC: 0,   rpm: 0),
            CurvePoint(tempC: 45,  rpm: 0),
            CurvePoint(tempC: 55,  rpm: 1800),
            CurvePoint(tempC: 65,  rpm: 3000),
            CurvePoint(tempC: 75,  rpm: 4500),
            CurvePoint(tempC: 85,  rpm: 6200),
            CurvePoint(tempC: 95,  rpm: fanMax),
            CurvePoint(tempC: 105, rpm: fanMax),
        ], isBuiltIn: true),
        FanProfile(name: "macOS Default", points: [
            CurvePoint(tempC: 0,   rpm: 0),
            CurvePoint(tempC: 50,  rpm: 0),
            CurvePoint(tempC: 53,  rpm: 1200),
            CurvePoint(tempC: 68,  rpm: 2500),
            CurvePoint(tempC: 78,  rpm: 5000),
            CurvePoint(tempC: 88,  rpm: fanMax),
            CurvePoint(tempC: 105, rpm: fanMax),
        ], isBuiltIn: true),
        FanProfile(name: "Performance", points: [
            CurvePoint(tempC: 0,   rpm: 3000),
            CurvePoint(tempC: 50,  rpm: 3000),
            CurvePoint(tempC: 65,  rpm: 5000),
            CurvePoint(tempC: 75,  rpm: 6500),
            CurvePoint(tempC: 85,  rpm: fanMax),
            CurvePoint(tempC: 105, rpm: fanMax),
        ], isBuiltIn: true),
    ] }
}

// MARK: - ProfileStore

private struct Saved: Codable {
    var profiles: [FanProfile]
    var activeProfileID: UUID
    var tempSensor: TempSensor = .cpuAvg
    var safetyTemp: Double?   // optional so old saves without this key still decode
    var maxFanSpeed: Double?  // legacy global cap — migrated to per-profile on load
}

final class ProfileStore: ObservableObject {
    @Published var profiles: [FanProfile] = []
    @Published var activeProfileID: UUID
    @Published var tempSensor: TempSensor = .cpuAvg
    @Published var safetyTemp: Double = 90

    private let savePath: URL

    init(fanMax: Double) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/fancurve")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savePath = dir.appendingPathComponent("profiles.json")

        let allDefs = FanProfile.defaults(fanMax: fanMax)

        if let data = try? Data(contentsOf: savePath),
           let saved = try? JSONDecoder().decode(Saved.self, from: data),
           !saved.profiles.isEmpty {
            profiles = saved.profiles
            activeProfileID = saved.activeProfileID
            tempSensor = saved.tempSensor
            safetyTemp = saved.safetyTemp ?? 90
            // Migration: copy legacy global cap to all profiles
            if let globalCap = saved.maxFanSpeed {
                for i in profiles.indices { profiles[i].maxFanSpeed = globalCap }
            }
        } else {
            profiles = allDefs
            activeProfileID = allDefs[1].id
        }

        // Migration: stamp isBuiltIn on profiles loaded from older saves that lack the flag.
        let builtInNames = Set(allDefs.map { $0.name })
        for i in profiles.indices where !profiles[i].isBuiltIn {
            if builtInNames.contains(profiles[i].name) { profiles[i].isBuiltIn = true }
        }

        // Migration: insert any built-in profiles that don't exist in the saved list yet.
        let existingNames = Set(profiles.map { $0.name })
        for def in allDefs where !existingNames.contains(def.name) {
            profiles.append(def)
        }

        // Ensure every profile always has locked boundary nodes at 0°C and 105°C.
        for i in profiles.indices {
            let sorted = profiles[i].points.sorted { $0.tempC < $1.tempC }
            if sorted.first?.tempC != 0 {
                profiles[i].points.append(CurvePoint(tempC: 0, rpm: sorted.first?.rpm ?? 1200))
            }
            if sorted.last?.tempC != 105 {
                profiles[i].points.append(CurvePoint(tempC: 105, rpm: sorted.last?.rpm ?? fanMax))
            }
        }
        save()
    }

    var activeProfile: FanProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles[0]
    }

    func save() {
        let payload = Saved(profiles: profiles, activeProfileID: activeProfileID, tempSensor: tempSensor, safetyTemp: safetyTemp)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: savePath)
        }
    }
}
