#pragma once
#include <stdint.h>
#include <stddef.h>
typedef enum { NATIVE_MAC_E0524=0, NATIVE_MAC_E0585=1 } NativeEngineProfile;
int native_message(uint8_t *out,size_t cap,int kind,const char *account,const char *password,const char *device,const char *service,NativeEngineProfile profile);
int native_summary(const uint8_t *data,size_t length,int *kind,int *state,int *result);
void native_pipe_header(uint8_t header[48],uint32_t sequence,uint32_t length);

int native_auth_result(const uint8_t *data,size_t length,int *connection,int *result);
