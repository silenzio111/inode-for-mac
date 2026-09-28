#include "EAPTrace.h"
#include <ifaddrs.h>
#include <net/if_dl.h>
#include <stdio.h>
#include <string.h>
static unsigned u16(const uint8_t *p) {return ((unsigned)p[0]<<8)|p[1];}
int eap_metadata(const uint8_t *p,size_t n,const uint8_t local[6],char *out,size_t cap) {
    if(!cap) return 0;out[0]=0;
    if(n<14) return 0;
    int outgoing=!memcmp(p+6,local,6);
    if(!outgoing && memcmp(p,local,6) && !(p[0]&1)) return 0;
    size_t offset=14;unsigned ether=u16(p+12);
    for(int tags=0;tags<2 && (ether==0x8100 || ether==0x88a8);tags++) {
        if(n-offset<4) return 0;ether=u16(p+offset+2);offset+=4;
    }
    if(ether!=0x888e || n-offset<4) return 0;
    unsigned type=p[offset+1],body=u16(p+offset+2);offset+=4;
    if(body>n-offset) return 0;
    const char *direction=outgoing?"发送":"收到";int written;
    if(type==1 || type==2) {
        if(body) return 0;
        written=snprintf(out,cap,"有线认证交互：%s EAPOL-%s",direction,type==1?"Start":"Logoff");
    } else if(type==0 && body>=4) {
        unsigned code=p[offset],length=u16(p+offset+2);
        if(length<4 || length>body) return 0;
        if(code==1 || code==2) {
            if(length<5) return 0;
            written=snprintf(out,cap,"有线认证交互：%s EAP-%s，方法 %u，长度 %u",direction,code==1?"Request":"Response",p[offset+4],length);
        } else if(code==3 || code==4) {
            written=snprintf(out,cap,"有线认证交互：%s EAP-%s，长度 %u",direction,code==3?"Success":"Failure",length);
        } else return 0;
    } else return 0;
    if(written<0 || (size_t)written>=cap) {out[0]=0;return 0;}return 1;
}
pcap_t *eap_trace_open(const char *device,uint8_t local[6]) {
    struct ifaddrs *all=NULL;int found=0;
    if(getifaddrs(&all)) return NULL;
    for(struct ifaddrs *a=all;a;a=a->ifa_next) {
        if(a->ifa_addr && !strcmp(a->ifa_name,device) && a->ifa_addr->sa_family==AF_LINK) {
            struct sockaddr_dl *dl=(void *)a->ifa_addr;
            if(dl->sdl_alen==6) {memcpy(local,LLADDR(dl),6);found=1;break;}
        }
    }
    freeifaddrs(all);if(!found) return NULL;
    char error[PCAP_ERRBUF_SIZE];pcap_t *capture=pcap_create(device,error);
    if(!capture) return NULL;
    pcap_set_snaplen(capture,4096);pcap_set_promisc(capture,0);pcap_set_timeout(capture,100);pcap_set_immediate_mode(capture,1);
    if(pcap_activate(capture)<0 || pcap_datalink(capture)!=DLT_EN10MB || pcap_setnonblock(capture,1,error)<0) {pcap_close(capture);return NULL;}
    struct bpf_program filter;
    if(pcap_compile(capture,&filter,"ether proto 0x888e or (vlan and ether proto 0x888e)",1,PCAP_NETMASK_UNKNOWN)<0) {pcap_close(capture);return NULL;}
    int result=pcap_setfilter(capture,&filter);pcap_freecode(&filter);
    if(result<0) {pcap_close(capture);return NULL;}return capture;
}
void eap_trace_drain(pcap_t *capture,const uint8_t local[6],void (*notice)(const char *,const char *)) {
    if(!capture) return;
    for(int i=0;i<128;i++) {
        struct pcap_pkthdr *header;const uint8_t *frame;int result=pcap_next_ex(capture,&header,&frame);
        if(result<=0) break;
        char text[200];if(eap_metadata(frame,header->caplen,local,text,sizeof(text))) notice("notice",text);
    }
}
