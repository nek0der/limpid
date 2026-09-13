#ifndef LIMPID_RUST_BRIDGE_H
#define LIMPID_RUST_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t limpid_rust_abi_version(void);

enum limpid_title_resolve_result {
    LIMPID_TITLE_RESOLVE_OK = 0,
    LIMPID_TITLE_RESOLVE_EMPTY = 1,
    LIMPID_TITLE_RESOLVE_INVALID_UTF8 = 2,
    LIMPID_TITLE_RESOLVE_TOO_LONG = 3,
    LIMPID_TITLE_RESOLVE_BUFFER_TOO_SMALL = 4,
    LIMPID_TITLE_RESOLVE_NULL_POINTER = 5,
};

int32_t limpid_resolve_title_v1(
    const uint8_t *provider_session_ptr,
    size_t provider_session_len,
    const uint8_t *provider_generated_ptr,
    size_t provider_generated_len,
    const uint8_t *first_prompt_ptr,
    size_t first_prompt_len,
    uint8_t *output_ptr,
    size_t output_capacity,
    size_t *output_length
);

#ifdef __cplusplus
}
#endif

#endif
