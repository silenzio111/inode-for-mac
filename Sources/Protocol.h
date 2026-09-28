#pragma once
#include <stdint.h>
#include <stddef.h>
/* H3C packet layouts documented by njit8021xclient; see THIRD_PARTY.md. */
int make_response(const uint8_t *request, size_t length, const uint8_t mac[6],
                  const uint8_t ip[4], const char *username, const char *password,
                  int xor_mode, int first, uint8_t *output, size_t capacity);

void describe_failure(const uint8_t *packet, size_t length, char *message, size_t capacity);

int make_response_with_service(const uint8_t *request, size_t length, const uint8_t mac[6],
                  const uint8_t ip[4], const char *username, const char *password,
                  const char *service, int xor_mode, int first, uint8_t *output, size_t capacity);

int encode_service_gbk(const char *utf8, char *output, size_t capacity);
