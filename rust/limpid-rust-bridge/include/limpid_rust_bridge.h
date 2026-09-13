#ifndef LIMPID_RUST_BRIDGE_H
#define LIMPID_RUST_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns the bridge-wide compatibility version. Adding a new symbol does not
// increment it; only an incompatible change to an existing contract does.
uint32_t limpid_rust_abi_version(void);

typedef struct limpid_approval_service_v1 limpid_approval_service_v1;
typedef struct limpid_approval_session_v1 limpid_approval_session_v1;

struct limpid_approval_bytes_v1 {
    uint8_t *data;
    size_t len;
};

enum limpid_approval_result {
    LIMPID_APPROVAL_OK = 0,
    LIMPID_APPROVAL_NULL_POINTER = 1,
    LIMPID_APPROVAL_INVALID_UUID = 2,
    LIMPID_APPROVAL_INPUT_TOO_LARGE = 3,
    LIMPID_APPROVAL_INVALID_UTF8 = 4,
    LIMPID_APPROVAL_INVALID_JSON = 5,
    LIMPID_APPROVAL_RESPONSE_TOO_LARGE = 6,
    LIMPID_APPROVAL_INTERNAL = 7,
    LIMPID_APPROVAL_PANIC = 8,
};

// A service shares state among independent host-authenticated sessions.
// The caller must free every session before freeing its service. Calls on
// separate sessions may run concurrently; each session serializes its own use.
limpid_approval_service_v1 *limpid_approval_service_create_v1(
    size_t maximum_records
);
void limpid_approval_service_free_v1(limpid_approval_service_v1 *service);

// `run_id` is exactly 16 raw UUID bytes supplied by the authenticated host.
limpid_approval_session_v1 *limpid_approval_session_create_requester_v1(
    const limpid_approval_service_v1 *service,
    const uint8_t *run_id,
    size_t run_id_len
);
limpid_approval_session_v1 *limpid_approval_session_create_controller_v1(
    const limpid_approval_service_v1 *service
);
void limpid_approval_session_free_v1(limpid_approval_session_v1 *session);

// One XPC Data request maps to one WireRequest JSON document and one response
// Data maps to one WireResponse JSON document. No stream framing is applied.
// On success, ownership of `output->data` transfers to the caller, which must
// release it with `limpid_approval_bytes_free_v1`.
int32_t limpid_approval_session_exchange_v1(
    limpid_approval_session_v1 *session,
    const uint8_t *input,
    size_t input_len,
    struct limpid_approval_bytes_v1 *output
);
void limpid_approval_bytes_free_v1(uint8_t *data, size_t len);

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
