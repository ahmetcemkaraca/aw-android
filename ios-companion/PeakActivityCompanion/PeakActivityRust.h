#ifndef PEAKACTIVITY_RUST_H
#define PEAKACTIVITY_RUST_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    void *context;
    int32_t (*load)(void *context, uint8_t *output, size_t capacity, size_t *length);
    int32_t (*save)(void *context, const uint8_t *proof, size_t length);
    int32_t (*floor)(void *context, const uint8_t *scope, size_t length, uint64_t *sequence);
    int32_t (*advance)(void *context, const uint8_t *scope, size_t length, uint64_t sequence);
    void (*release)(void *context);
} PeakActivityEntitlementCallbacks;

/* Rust owns context and releases it exactly once, including when open fails. */
uint64_t peakactivity_companion_open_with_security(const uint8_t *path, size_t path_len,
                                   const uint8_t *key, size_t key_len,
                                   const uint8_t *egress_trust, size_t egress_len,
                                   const uint8_t *entitlement_trust, size_t entitlement_len,
                                   PeakActivityEntitlementCallbacks callbacks);

uint64_t peakactivity_companion_open(const uint8_t *path, size_t path_len,
                                   const uint8_t *key, size_t key_len);
uint64_t peakactivity_companion_open_with_release_trust(const uint8_t *path, size_t path_len,
                                   const uint8_t *key, size_t key_len,
                                   const uint8_t *trust, size_t trust_len);
char *peakactivity_companion_invoke(uint64_t handle, const uint8_t *request,
                                   size_t request_len);
bool peakactivity_companion_close(uint64_t handle);
bool peakactivity_companion_pause_sync(uint64_t handle);
void peakactivity_companion_response_free(char *response);
#endif
