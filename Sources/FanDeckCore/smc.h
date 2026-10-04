//  smc.h — FanDeck 저수준 SMC 접근 레이어
//  AppleSMC IOService 와 80바이트 구조체 프로토콜로 직접 통신한다.
//  읽기는 일반 사용자 권한으로 가능하고, 쓰기는 root 가 필요하다.
#ifndef FANDECK_SMC_H
#define FANDECK_SMC_H

#include <stdint.h>
#include <stdbool.h>

#define FD_SMC_OK            0
#define FD_SMC_ERR_OPEN      -1
#define FD_SMC_ERR_CALL      -2
#define FD_SMC_ERR_NOKEY     -3
#define FD_SMC_ERR_TYPE      -4
#define FD_SMC_ERR_PERM      -5

/// SMC 키 하나의 메타데이터. dataType 은 'flt ', 'ui8 ' 같은 4문자 코드다.
typedef struct {
    char     key[5];
    char     type[5];
    uint32_t size;
} fd_smc_keyinfo;

int  fd_smc_open(void);
void fd_smc_close(void);

/// 이 SMC 가 보유한 전체 키 개수(#KEY).
int  fd_smc_key_count(uint32_t *out_count);
/// 인덱스로 키 이름을 얻는다. 전체 키를 훑을 때 사용.
int  fd_smc_key_at(uint32_t index, char out_key[5]);
int  fd_smc_key_info(const char *key, fd_smc_keyinfo *out);

/// 숫자형 키('flt ', 'ui8 ', 'ui16', 'ui32', 'si8 ', 'si16', 'sp78' 등)를 double 로 정규화해 읽는다.
int  fd_smc_read_number(const char *key, double *out_value);
/// 원시 바이트 읽기. out_buf 는 최소 32바이트.
int  fd_smc_read_bytes(const char *key, uint8_t *out_buf, uint32_t *io_len);

/// float 키 쓰기 (F0Tg 등). root 필요.
int  fd_smc_write_float(const char *key, float value);
/// uint8 키 쓰기 (F0Md 등). root 필요.
int  fd_smc_write_u8(const char *key, uint8_t value);
/// 키가 존재하는지만 확인.
bool fd_smc_key_exists(const char *key);

#endif
