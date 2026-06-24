/*
 * smc-fan: setuid-root helper that writes fan SMC keys directly via IOKit.
 *
 * Allowed keys (all 4-byte IEEE 754 float, passed as 8 hex chars):
 *   F0Mn, F1Mn  — fan minimum speed
 *   F0Tg, F1Tg  — fan target speed (forces fans to actually run)
 *
 * Usage:  smc-fan -k <key> -w <8hexchars>
 * Install: sudo install -o root -g wheel -m 4755 smc-fan /usr/local/bin/smc-fan
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC     2
#define SMC_CMD_READ_KEYINFO 9
#define SMC_CMD_WRITE_BYTES  6

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} KeyInfo;

typedef struct {
    uint32_t key;
    uint8_t  vers[6];
    uint8_t  pLimit[16];
    KeyInfo  keyInfo;
    uint8_t  result;
    uint8_t  status;
    uint8_t  data8;
    uint8_t  _pad;
    uint32_t data32;
    uint8_t  bytes[32];
} SMCData;

static kern_return_t smcCall(io_connect_t conn, int idx, SMCData *in, SMCData *out) {
    size_t sz = sizeof(SMCData);
    return IOConnectCallStructMethod(conn, idx, in, sizeof(SMCData), out, &sz);
}

static uint32_t fourcc(const char *s) {
    return (uint32_t)(uint8_t)s[0]<<24 | (uint32_t)(uint8_t)s[1]<<16
         | (uint32_t)(uint8_t)s[2]<<8  | (uint8_t)s[3];
}

static kern_return_t smcWrite(io_connect_t conn, const char *key,
                               const uint8_t *data, uint32_t dataSize) {
    /* Read key info first */
    SMCData in={0}, out={0};
    in.key   = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smcCall(conn, KERNEL_INDEX_SMC, &in, &out);
    if (kr != KERN_SUCCESS) return kr;

    /* Write */
    SMCData win={0}, wout={0};
    win.key              = fourcc(key);
    win.data8            = SMC_CMD_WRITE_BYTES;
    win.keyInfo.dataSize = out.keyInfo.dataSize;
    memcpy(win.bytes, data, dataSize < 32 ? dataSize : 32);
    return smcCall(conn, KERNEL_INDEX_SMC, &win, &wout);
}

static int allowed_key(const char *k) {
    return strcmp(k,"F0Mn")==0 || strcmp(k,"F1Mn")==0
        || strcmp(k,"F0Tg")==0 || strcmp(k,"F1Tg")==0;
}

static int parse_hex8(const char *s, uint8_t out[4]) {
    if (strlen(s) != 8) return 0;
    for (int i=0; i<8; i++) if (!isxdigit((unsigned char)s[i])) return 0;
    for (int i=0; i<4; i++) {
        char b[3]={s[i*2],s[i*2+1],'\0'};
        out[i]=(uint8_t)strtoul(b,NULL,16);
    }
    return 1;
}

int main(int argc, char *argv[]) {
    if (argc!=5 || strcmp(argv[1],"-k")!=0 || strcmp(argv[3],"-w")!=0
        || !allowed_key(argv[2])) {
        fprintf(stderr,"Usage: smc-fan -k <F0Mn|F1Mn|F0Tg|F1Tg> -w <8hexchars>\n");
        return 1;
    }
    uint8_t data[4];
    if (!parse_hex8(argv[4], data)) {
        fprintf(stderr,"bad hex: need exactly 8 hex digits\n");
        return 1;
    }

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                           IOServiceMatching("AppleSMC"));
    if (!svc) { fprintf(stderr,"AppleSMC not found\n"); return 1; }

    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr!=KERN_SUCCESS) {
        fprintf(stderr,"IOServiceOpen: 0x%08x\n", kr);
        return 1;
    }

    kr = smcWrite(conn, argv[2], data, 4);
    IOServiceClose(conn);

    if (kr!=KERN_SUCCESS) {
        fprintf(stderr,"write failed: 0x%08x\n", kr);
        return 1;
    }
    return 0;
}
