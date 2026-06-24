/*
 * fancurve-daemon  —  root daemon for Apple Silicon fan control
 *
 * Apple Silicon Macs require an unlock sequence before manual fan control works:
 *   1. Write Ftst=1  (suppresses thermalmonitord's LifetimeServoController)
 *   2. Poll F%dMd=1  (mode write returns 0x82/SmcBadCommand until Ftst takes
 *                     effect; typically succeeds within 3-6 s)
 *   3. Write F%dTg   (actual target RPM)
 *
 * Ftst must be re-asserted every ~2 s or thermalmonitord reclaims the fans.
 *
 * Communication with the GUI app: read target RPM from TARGET_FILE.
 * Write a float value (e.g. "4000\n") for manual mode, or delete the file /
 * write "0\n" to restore automatic control.
 *
 * Install:
 *   sudo cp fancurve-daemon /usr/local/bin/fancurve-daemon
 *   sudo chown root:wheel /usr/local/bin/fancurve-daemon
 *   sudo chmod 755 /usr/local/bin/fancurve-daemon
 *   (runs as root via LaunchDaemon — no setuid bit needed)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <IOKit/IOKitLib.h>

/* ── SMC constants ──────────────────────────────────────────────────────── */
#define KERNEL_INDEX_SMC     2
#define SMC_CMD_READ_KEYINFO 9
#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_WRITE_BYTES  6
#define SMC_ERR_BAD_CMD      0x82   /* mode write rejected (Ftst not yet active) */
#define SMC_ERR_NOT_FOUND    0x84   /* key doesn't exist (Ftst absent on M5) */

#define TARGET_FILE  "/tmp/fancurve_target"
#define LOG_FILE     "/tmp/fancurve-daemon.log"
#define POLL_MS      100            /* ms between retries during unlock */
#define UNLOCK_TIMEOUT_MS 10000    /* max time to wait for mode write */
#define LOOP_INTERVAL_US 500000    /* 0.5 s — must be shorter than thermalmonitord's reclaim window */

/* ── SMC structs  (total must be 80 bytes — verified) ───────────────────── */
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } KeyInfo;

typedef struct {
    uint32_t key;
    uint8_t  vers[6];
    uint8_t  pLimit[16];
    KeyInfo  keyInfo;       /* compiler inserts 2B padding before this */
    uint8_t  result;
    uint8_t  status;
    uint8_t  data8;
    uint8_t  _pad;
    uint32_t data32;
    uint8_t  bytes[32];
} SMCData;

static io_connect_t gConn = IO_OBJECT_NULL;
static FILE        *gLog  = NULL;

#define LOG(fmt, ...) do { \
    if (gLog) { fprintf(gLog, fmt "\n", ##__VA_ARGS__); fflush(gLog); } \
} while(0)

/* ── IOKit helpers ──────────────────────────────────────────────────────── */
static uint32_t fourcc(const char *s) {
    return (uint32_t)(uint8_t)s[0]<<24 | (uint32_t)(uint8_t)s[1]<<16
         | (uint32_t)(uint8_t)s[2]<<8  | (uint8_t)s[3];
}

static kern_return_t smcCall(int idx, SMCData *in, SMCData *out) {
    size_t sz = sizeof(SMCData);
    return IOConnectCallStructMethod(gConn, idx, in, sizeof(SMCData), out, &sz);
}

/* Returns 0 on success, SMC result byte on failure, -1 on kern error */
static int smcWriteBytes(const char *key, const uint8_t *data, uint32_t len) {
    SMCData in={0}, out={0};
    in.key   = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smcCall(KERNEL_INDEX_SMC, &in, &out);
    if (kr != KERN_SUCCESS) return -1;

    uint32_t sz = out.keyInfo.dataSize;
    memset(&in, 0, sizeof(in));
    in.key              = fourcc(key);
    in.data8            = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = sz;
    memcpy(in.bytes, data, len < sz ? len : sz);

    memset(&out, 0, sizeof(out));
    kr = smcCall(KERNEL_INDEX_SMC, &in, &out);
    if (kr != KERN_SUCCESS) return -1;
    return out.result;  /* 0 = success, 0x82 = bad cmd, 0x84 = not found */
}

static int smcWriteU8(const char *key, uint8_t val) {
    return smcWriteBytes(key, &val, 1);
}

static int smcWriteFloat(const char *key, float val) {
    return smcWriteBytes(key, (const uint8_t *)&val, 4);
}

/* Returns 1 if key exists in SMC, 0 otherwise */
static int smcKeyExists(const char *key) {
    SMCData in={0}, out={0};
    in.key   = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smcCall(KERNEL_INDEX_SMC, &in, &out) != KERN_SUCCESS) return 0;
    return out.result == 0 && out.keyInfo.dataSize > 0;
}

static float smcReadFloat(const char *key) {
    SMCData in={0}, out={0};
    in.key   = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smcCall(KERNEL_INDEX_SMC, &in, &out) != KERN_SUCCESS) return -1;
    if (out.result != 0) return -1;  /* key not found or error */

    uint32_t sz = out.keyInfo.dataSize;
    memset(&in, 0, sizeof(in));
    in.key              = fourcc(key);
    in.data8            = SMC_CMD_READ_BYTES;
    in.keyInfo.dataSize = sz;
    memset(&out, 0, sizeof(out));
    if (smcCall(KERNEL_INDEX_SMC, &in, &out) != KERN_SUCCESS) return -1;
    if (out.result != 0) return -1;

    float f; memcpy(&f, out.bytes, 4); return f;
}

/* ── Unlock sequence ────────────────────────────────────────────────────── */

/* Try writing Ftst=1. Returns 1 if key exists, 0 if absent (M5). */
static int assertFtst(void) {
    int r = smcWriteU8("Ftst", 1);
    if (r == SMC_ERR_NOT_FOUND) return 0;   /* M5: no Ftst key */
    return 1;
}

static void clearFtst(void) {
    smcWriteU8("Ftst", 0);
}

/*
 * Enter manual mode for one fan. Returns 1 on success.
 * On Apple Silicon, F%dMd write returns 0x82 until Ftst=1 has suppressed thermalmonitord.
 * We poll with 100ms intervals up to UNLOCK_TIMEOUT_MS.
 */
static int enterManualMode(int fan) {
    char mdKey[8];
    snprintf(mdKey, sizeof(mdKey), "F%dMd", fan);

    for (int elapsed = 0; elapsed < UNLOCK_TIMEOUT_MS; elapsed += POLL_MS) {
        int r = smcWriteU8(mdKey, 1);
        if (r == 0) {
            LOG("fan%d: mode=1 set after %d ms", fan, elapsed);
            return 1;
        }
        if (r == SMC_ERR_NOT_FOUND) {
            LOG("fan%d: F%dMd not found", fan, fan);
            return 0;
        }
        usleep(POLL_MS * 1000);
    }
    LOG("fan%d: unlock timeout", fan);
    return 0;
}

static void exitManualMode(int fan) {
    char mdKey[8];
    snprintf(mdKey, sizeof(mdKey), "F%dMd", fan);
    smcWriteU8(mdKey, 0);
}

/* ── Main loop ──────────────────────────────────────────────────────────── */

static double readTarget(void) {
    FILE *f = fopen(TARGET_FILE, "r");
    if (!f) return 0;
    double v = 0;
    fscanf(f, "%lf", &v);
    fclose(f);
    return v;
}

int main(void) {
    gLog = fopen(LOG_FILE, "a");
    LOG("fancurve-daemon starting (pid %d)", (int)getpid());

    /* Open SMC */
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                            IOServiceMatching("AppleSMC"));
    if (!svc) { LOG("AppleSMC not found"); return 1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &gConn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { LOG("IOServiceOpen failed: 0x%08x", kr); return 1; }

    /* Detect fan count — use key-existence check, not value (0 RPM is valid) */
    int numFans = 0;
    for (int i = 0; i < 4; i++) {
        char acKey[8]; snprintf(acKey, sizeof(acKey), "F%dAc", i);
        if (smcKeyExists(acKey)) numFans = i + 1; else break;
    }
    if (numFans == 0) numFans = 2;  /* fallback for Apple Silicon Pro/Max chips */
    LOG("detected %d fan(s)", numFans);

    int manualMode  = 0;
    int ftst_exists = 1;  /* assume present; cleared if we get SMC_ERR_NOT_FOUND */
    double lastLoggedTarget = -1;

    while (1) {
        double target = readTarget();

        if (target <= 0) {
            /* ── Auto mode: return control to thermalmonitord ── */
            if (manualMode) {
                LOG("returning to auto mode");
                for (int i = 0; i < numFans; i++) exitManualMode(i);
                manualMode = 0;
            }
            /* Always clear Ftst — even if unlock never succeeded, Ftst may still
             * be asserted, leaving thermalmonitord suppressed with nothing in control. */
            if (ftst_exists) clearFtst();
        } else {
            /* ── Manual mode ── */

            /* Keep Ftst=1 to suppress thermalmonitord reclaiming fans */
            if (ftst_exists) {
                int r = assertFtst();
                if (!r) { ftst_exists = 0; LOG("Ftst absent (M5 behaviour)"); }
            }

            /* Re-assert F%dMd=1 every iteration.
             * thermalmonitord resets the mode bit when it reclaims the fans;
             * checking `manualMode` only catches the initial entry, not reclaims.
             * Fast path: write succeeds (r==0) immediately once Ftst is active.
             * Slow path: r==SMC_ERR_BAD_CMD means Ftst hasn't suppressed
             * thermalmonitord yet — fall back to the polled enterManualMode. */
            {
                int anyOk = 0;
                for (int i = 0; i < numFans; i++) {
                    char mdKey[8];
                    snprintf(mdKey, sizeof(mdKey), "F%dMd", i);
                    int r = smcWriteU8(mdKey, 1);
                    if (r == 0) {
                        anyOk = 1;
                    } else if (r == SMC_ERR_BAD_CMD) {
                        /* Ftst not yet active — wait for it */
                        if (enterManualMode(i)) anyOk = 1;
                    }
                    /* SMC_ERR_NOT_FOUND: fan index doesn't exist, skip */
                }
                manualMode = anyOk;
            }

            /* Write target to F%dTg */
            if (manualMode) {
                float rpm = (float)target;
                for (int i = 0; i < numFans; i++) {
                    char tgKey[8];
                    snprintf(tgKey, sizeof(tgKey), "F%dTg", i);
                    smcWriteFloat(tgKey, rpm);
                }
                if (target != lastLoggedTarget) {
                    LOG("fans → %.0f RPM", rpm);
                    lastLoggedTarget = target;
                }
            }
        }

        usleep(LOOP_INTERVAL_US);
    }

    IOServiceClose(gConn);
    return 0;
}
