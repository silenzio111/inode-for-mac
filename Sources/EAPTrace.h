#pragma once
#include <stdint.h>
#include <stddef.h>
#include <pcap/pcap.h>
/* Metadata only. This module never sends packets, records payloads, or writes pcaps. */
int eap_metadata(const uint8_t *frame,size_t length,const uint8_t local[6],char *output,size_t capacity);
pcap_t *eap_trace_open(const char *device,uint8_t local[6]);
void eap_trace_drain(pcap_t *capture,const uint8_t local[6],void (*notice)(const char *,const char *));
