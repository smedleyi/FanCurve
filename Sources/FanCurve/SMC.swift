import Foundation
import IOKit

// SMC reads: direct IOKit (no root needed).
// SMC writes: written to TARGET_FILE; fancurve-daemon (running as root) picks
// them up and handles the M4 unlock sequence (Ftst + F%dMd + F%dTg).
enum SMC {
    static let targetFile = "/tmp/fancurve_target"

    // MARK: - Public API

    static func cpuTemp() -> Double {
        // Tp01-Tp0b are thermally distributed package sensors — far more stable
        // than raw P-core die temps (TCMb), which spike on every short burst.
        // Average them to get a smooth, representative SoC temperature.
        let packageKeys = ["Tp01","Tp05","Tp0D","Tp0H","Tp0L","Tp0P","Tp0X","Tp0b"]
        let pkgTemps = packageKeys.compactMap { readFloat($0) }.filter { $0 > 0 && $0 < 120 }
        if !pkgTemps.isEmpty {
            return pkgTemps.reduce(0, +) / Double(pkgTemps.count)
        }
        // Fallback: individual cluster max
        return ["TCMb","Tex1","Te05"].compactMap { readFloat($0) }.max() ?? 0
    }

    static func gpuTemp() -> Double {
        // Use the max of all GPU cluster sensors rather than the average.
        // Clusters idle at different temperatures; max catches whichever is hottest.
        let gpuKeys = ["Tg04","Tg05","Tg0K","Tg0L","Tg0R","Tg0S","Tg0X","Tg0Y"]
        let temps = gpuKeys.compactMap { readFloat($0) }.filter { $0 > 20 && $0 < 120 }
        return temps.max() ?? 0
    }


    static func fanSpeed(_ fan: Int) -> Double {
        readFloat("F\(fan)Ac") ?? 0
    }

    static func fanCount() -> Int {
        var n = 0
        for i in 0..<4 { if readFloat("F\(i)Ac") != nil { n = i + 1 } else { break } }
        return n > 0 ? n : 2
    }

    static func fanMin(_ fan: Int) -> Double { readFloat("F\(fan)Mn") ?? 1200 }
    static func fanMax(_ fan: Int) -> Double { readFloat("F\(fan)Mx") ?? 7826 }

    // Tell the daemon to run fans at `rpm`. Returns true if the write succeeded.
    @discardableResult
    static func setTargetRPM(_ rpm: Double) -> Bool { writeTarget(rpm) }

    // Tell the daemon to restore automatic control.
    static func resetTargetRPM() { writeTarget(-1) }

    static var daemonRunning: Bool {
        // Daemon writes its log on startup; check if process exists
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "pgrep -x fancurve-daemon > /dev/null 2>&1"]
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Target file

    @discardableResult
    private static func writeTarget(_ rpm: Double) -> Bool {
        let content = "\(Int(rpm))\n"
        do {
            try content.write(toFile: targetFile, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - IOKit read

    // Single persistent connection opened once at first use; SMC is always present.
    private static let conn: io_connect_t = {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return 0 }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(svc, mach_task_self_, 0, &c)
        IOObjectRelease(svc)
        return kr == KERN_SUCCESS ? c : 0
    }()

    private static let KERNEL_INDEX_SMC: UInt32    = 2
    private static let SMC_CMD_READ_KEYINFO: UInt8 = 9
    private static let SMC_CMD_READ_BYTES: UInt8   = 5

    private struct SMCData {
        var key:     UInt32 = 0
        var vers:    (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0)
        var pLimit:  (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                      UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                      UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        // KeyInfo fields (28-39): matches C `typedef struct { uint32_t dataSize; uint32_t dataType;
        // uint8_t dataAttributes; } KeyInfo;` which is sizeof=12 due to 3 bytes trailing padding.
        // Flattening without those 3 pad bytes would shift data8 from offset 42 → 39, breaking IOKit.
        var infoSize:    UInt32 = 0                      // offset 28
        var infoType:    UInt32 = 0                      // offset 32
        var infoAttr:    UInt8  = 0                      // offset 36
        var _keyInfoPad: (UInt8, UInt8, UInt8) = (0,0,0) // offset 37-39 (KeyInfo trailing pad)
        var result:   UInt8  = 0                         // offset 40
        var status:   UInt8  = 0                         // offset 41
        var data8:    UInt8  = 0                         // offset 42 — kernel reads command here
        var _pad:     UInt8  = 0                         // offset 43
        var data32:   UInt32 = 0                         // offset 44
        var bytes:    (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                       UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                       UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                       UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
                      (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        // Total: 48 + 32 = 80 bytes — matches kernel SMCData exactly
    }

    private static func fourcc(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        guard b.count >= 4 else { return 0 }
        return UInt32(b[0])<<24 | UInt32(b[1])<<16 | UInt32(b[2])<<8 | UInt32(b[3])
    }

    private static func readFloat(_ key: String) -> Double? {
        guard conn != 0 else { return nil }

        // Get key info
        var inp = SMCData(); var out = SMCData()
        inp.key   = fourcc(key)
        inp.data8 = SMC_CMD_READ_KEYINFO
        var sz = MemoryLayout<SMCData>.size
        var kr = withUnsafeMutableBytes(of: &inp) { i in
            withUnsafeMutableBytes(of: &out) { o in
                IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC,
                    i.baseAddress, MemoryLayout<SMCData>.size,
                    o.baseAddress, &sz)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let dataSize = out.infoSize
        inp = SMCData(); out = SMCData()
        inp.key      = fourcc(key)
        inp.data8    = SMC_CMD_READ_BYTES
        inp.infoSize = dataSize
        sz = MemoryLayout<SMCData>.size
        kr = withUnsafeMutableBytes(of: &inp) { i in
            withUnsafeMutableBytes(of: &out) { o in
                IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC,
                    i.baseAddress, MemoryLayout<SMCData>.size,
                    o.baseAddress, &sz)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var f: Float = 0
        withUnsafeMutableBytes(of: &out.bytes) { memcpy(&f, $0.baseAddress, 4) }
        return Double(f)
    }
}
