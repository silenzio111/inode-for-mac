#pragma once
#include <stddef.h>
#include <stdint.h>
/* Returns only decoded, redacted text from validated notification field 3. */
int vendor_notice(const uint8_t *packet, size_t length, const char *account,
                  const char *password, char *output, size_t capacity);
