//  smc.c — AppleSMC IOKit 유저클라이언트 구현
//
//  구조체 레이아웃과 셀렉터 번호는 Apple 이 공개한 적 없는 비공개 인터페이스지만,
//  10여 년간 바뀌지 않았고 Apple Silicon(M1~M4)에서도 동일하게 동작한다.
//  Swift 쪽에서 구조체 패딩을 추측하지 않도록 저수준은 전부 C 로 둔다.

#include "smc.h"
#include <string.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;

typedef struct {
    uint32_t   key;
    SMCVers    vers;
    SMCPLimit  pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t    result;
    uint8_t    status;
    uint8_t    data8;
    uint32_t   data32;
    uint8_t    bytes[32];
} SMCParamStruct;

#define KERNEL_INDEX_SMC   2
#define CMD_READ_BYTES     5
#define CMD_WRITE_BYTES    6
#define CMD_READ_INDEX     8
#define CMD_READ_KEYINFO   9

static io_connect_t g_conn = 0;

// 키 메타데이터(타입·크기)는 부팅 중에 바뀌지 않는다. 매번 물어보면
// 값 하나를 읽는 데 IOKit 왕복이 두 번씩 들어서, 센서를 한 바퀴 도는 시간이 두 배가 된다.
#define KEYINFO_CACHE_SIZE 512
typedef struct { uint32_t key; SMCKeyInfo info; int valid; } KeyInfoCacheEntry;
static KeyInfoCacheEntry g_keyinfo_cache[KEYINFO_CACHE_SIZE];

static KeyInfoCacheEntry *cache_slot(uint32_t key) {
    // 키 자체를 해시로 쓴다. 충돌하면 그 자리를 덮어쓰고 다시 조회할 뿐이라 안전하다.
    return &g_keyinfo_cache[(key ^ (key >> 16)) % KEYINFO_CACHE_SIZE];
}

static uint32_t str_to_key(const char *s) {
    uint32_t k = 0;
    for (int i = 0; i < 4; i++) k = (k << 8) | (uint8_t)(s[i] ? s[i] : ' ');
    return k;
}

static void key_to_str(uint32_t k, char out[5]) {
    out[0] = (char)(k >> 24); out[1] = (char)(k >> 16);
    out[2] = (char)(k >> 8);  out[3] = (char)k; out[4] = '\0';
}

static int smc_call(SMCParamStruct *in, SMCParamStruct *out) {
    if (!g_conn) return FD_SMC_ERR_OPEN;
    size_t out_size = sizeof(SMCParamStruct);
    kern_return_t r = IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                               in, sizeof(SMCParamStruct),
                                               out, &out_size);
    if (r != KERN_SUCCESS) {
        // 권한 없는 쓰기는 보통 kIOReturnNotPrivileged 로 떨어진다.
        return (r == kIOReturnNotPrivileged || r == kIOReturnNotPermitted)
               ? FD_SMC_ERR_PERM : FD_SMC_ERR_CALL;
    }
    if (out->result != 0) return FD_SMC_ERR_NOKEY;
    return FD_SMC_OK;
}

int fd_smc_open(void) {
    if (g_conn) return FD_SMC_OK;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"));
    if (!svc) return FD_SMC_ERR_OPEN;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (r != KERN_SUCCESS) { g_conn = 0; return FD_SMC_ERR_OPEN; }
    return FD_SMC_OK;
}

void fd_smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
    memset(g_keyinfo_cache, 0, sizeof(g_keyinfo_cache));
}

int fd_smc_key_count(uint32_t *out_count) {
    uint8_t buf[32]; uint32_t len = sizeof(buf);
    int rc = fd_smc_read_bytes("#KEY", buf, &len);
    if (rc != FD_SMC_OK || len < 4) return rc ? rc : FD_SMC_ERR_TYPE;
    *out_count = ((uint32_t)buf[0] << 24) | ((uint32_t)buf[1] << 16)
               | ((uint32_t)buf[2] << 8)  | (uint32_t)buf[3];
    return FD_SMC_OK;
}

int fd_smc_key_at(uint32_t index, char out_key[5]) {
    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.data8 = CMD_READ_INDEX; in.data32 = index;
    int rc = smc_call(&in, &out);
    if (rc != FD_SMC_OK) return rc;
    key_to_str(out.key, out_key);
    return FD_SMC_OK;
}

static int read_keyinfo(const char *key, SMCKeyInfo *out_info) {
    uint32_t k = str_to_key(key);
    KeyInfoCacheEntry *slot = cache_slot(k);
    if (slot->valid && slot->key == k) { *out_info = slot->info; return FD_SMC_OK; }

    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = k; in.data8 = CMD_READ_KEYINFO;
    int rc = smc_call(&in, &out);
    if (rc != FD_SMC_OK) return rc;
    *out_info = out.keyInfo;

    slot->key = k; slot->info = out.keyInfo; slot->valid = 1;
    return FD_SMC_OK;
}

int fd_smc_key_info(const char *key, fd_smc_keyinfo *out) {
    SMCKeyInfo info;
    int rc = read_keyinfo(key, &info);
    if (rc != FD_SMC_OK) return rc;
    memcpy(out->key, key, 4); out->key[4] = '\0';
    key_to_str(info.dataType, out->type);
    out->size = info.dataSize;
    return FD_SMC_OK;
}

int fd_smc_read_bytes(const char *key, uint8_t *out_buf, uint32_t *io_len) {
    SMCKeyInfo info;
    int rc = read_keyinfo(key, &info);
    if (rc != FD_SMC_OK) return rc;
    if (info.dataSize > 32) return FD_SMC_ERR_TYPE;

    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = str_to_key(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = CMD_READ_BYTES;
    rc = smc_call(&in, &out);
    if (rc != FD_SMC_OK) return rc;

    uint32_t n = info.dataSize < *io_len ? info.dataSize : *io_len;
    memcpy(out_buf, out.bytes, n);
    *io_len = info.dataSize;
    return FD_SMC_OK;
}

/// SMC 의 숫자 타입은 종류가 많다. float 는 리틀엔디안, 정수는 빅엔디안,
/// sp/fp 고정소수점은 지정된 소수부 비트수로 나눈다.
static int decode_number(const char *type, const uint8_t *b, uint32_t size, double *out) {
    if (strncmp(type, "flt ", 4) == 0 && size == 4) {
        float f; memcpy(&f, b, 4); *out = (double)f; return FD_SMC_OK;
    }
    if (strncmp(type, "ui8 ", 4) == 0 && size >= 1) { *out = b[0]; return FD_SMC_OK; }
    if (strncmp(type, "si8 ", 4) == 0 && size >= 1) { *out = (int8_t)b[0]; return FD_SMC_OK; }
    if (strncmp(type, "ui16", 4) == 0 && size >= 2) { *out = (b[0] << 8) | b[1]; return FD_SMC_OK; }
    if (strncmp(type, "si16", 4) == 0 && size >= 2) { *out = (int16_t)((b[0] << 8) | b[1]); return FD_SMC_OK; }
    if (strncmp(type, "ui32", 4) == 0 && size >= 4) {
        *out = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
        return FD_SMC_OK;
    }
    if (strncmp(type, "si32", 4) == 0 && size >= 4) {
        *out = (int32_t)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]);
        return FD_SMC_OK;
    }
    // spXX / fpXX: 앞 두 글자가 포맷, 뒤 두 글자가 정수부/소수부 비트수(16진).
    if ((type[0] == 's' || type[0] == 'f') && type[1] == 'p' && size >= 2) {
        int frac_bits;
        char fc = type[3];
        if (fc >= '0' && fc <= '9') frac_bits = fc - '0';
        else if (fc >= 'a' && fc <= 'f') frac_bits = fc - 'a' + 10;
        else if (fc >= 'A' && fc <= 'F') frac_bits = fc - 'A' + 10;
        else return FD_SMC_ERR_TYPE;
        int raw = (b[0] << 8) | b[1];
        if (type[0] == 's' && (raw & 0x8000)) raw -= 0x10000;
        *out = (double)raw / (double)(1 << frac_bits);
        return FD_SMC_OK;
    }
    return FD_SMC_ERR_TYPE;
}

int fd_smc_read_number(const char *key, double *out_value) {
    SMCKeyInfo info;
    int rc = read_keyinfo(key, &info);
    if (rc != FD_SMC_OK) return rc;
    if (info.dataSize > 32) return FD_SMC_ERR_TYPE;

    char type[5]; key_to_str(info.dataType, type);

    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = str_to_key(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = CMD_READ_BYTES;
    rc = smc_call(&in, &out);
    if (rc != FD_SMC_OK) return rc;

    return decode_number(type, out.bytes, info.dataSize, out_value);
}

static int write_raw(const char *key, const uint8_t *data, uint32_t size) {
    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = str_to_key(key);
    in.keyInfo.dataSize = size;
    in.data8 = CMD_WRITE_BYTES;
    memcpy(in.bytes, data, size > 32 ? 32 : size);
    return smc_call(&in, &out);
}

int fd_smc_write_float(const char *key, float value) {
    SMCKeyInfo info;
    int rc = read_keyinfo(key, &info);
    if (rc != FD_SMC_OK) return rc;

    char type[5]; key_to_str(info.dataType, type);
    uint8_t buf[4];

    if (strncmp(type, "flt ", 4) == 0 && info.dataSize == 4) {
        memcpy(buf, &value, 4);
        return write_raw(key, buf, 4);
    }
    // 구형 Intel 맥의 팬 타깃은 fpe2(소수부 2비트) 다. 호환을 위해 같이 지원한다.
    if (type[0] == 'f' && type[1] == 'p' && info.dataSize == 2) {
        int frac_bits;
        char fc = type[3];
        if (fc >= '0' && fc <= '9') frac_bits = fc - '0';
        else if (fc >= 'a' && fc <= 'f') frac_bits = fc - 'a' + 10;
        else if (fc >= 'A' && fc <= 'F') frac_bits = fc - 'A' + 10;
        else return FD_SMC_ERR_TYPE;
        int raw = (int)(value * (float)(1 << frac_bits));
        if (raw < 0) raw = 0;
        if (raw > 0xFFFF) raw = 0xFFFF;
        buf[0] = (uint8_t)(raw >> 8); buf[1] = (uint8_t)(raw & 0xFF);
        return write_raw(key, buf, 2);
    }
    return FD_SMC_ERR_TYPE;
}

int fd_smc_write_u8(const char *key, uint8_t value) {
    SMCKeyInfo info;
    int rc = read_keyinfo(key, &info);
    if (rc != FD_SMC_OK) return rc;
    if (info.dataSize != 1) return FD_SMC_ERR_TYPE;
    return write_raw(key, &value, 1);
}

bool fd_smc_key_exists(const char *key) {
    SMCKeyInfo info;
    return read_keyinfo(key, &info) == FD_SMC_OK;
}
