/* Mac field 29 is RSA key, NOT the Linux service realm. Send it empty.
 * IPC payload model adapted from qfzlm/inode-modern (MIT).
 * Mac framing and option IDs verified against each engine's attribute dictionary.
 */
#include "NativeIPC.h"
#include <string.h>
static void be32(uint8_t *p,uint32_t n) {for(int j=0;j<4;j++) p[j]=(uint8_t)(n>>(24-j*8));}
static void le32(uint8_t *p,uint32_t n) {for(int j=0;j<4;j++) p[j]=(uint8_t)(n>>(j*8));}
static int tlv(uint8_t *out,size_t cap,size_t *i,int type,const void *value,size_t len) {
    if(len>253 || *i+2+len>cap) return 0;
    out[(*i)++]=(uint8_t)type;out[(*i)++]=(uint8_t)(len+2);
    if(len) memcpy(out+*i,value,len);*i+=len;return 1;
}
int native_message(uint8_t *out,size_t cap,int kind,const char *account,const char *password,const char *device,const char *service,NativeEngineProfile profile) {
    if(cap<12 || (kind!=1 && kind!=3 && kind!=7) || (profile!=NATIVE_MAC_E0524 && profile!=NATIVE_MAC_E0585)) return -1;
    memset(out,0,cap);out[0]=0x1f;out[1]=0x55;out[2]=0x1f;out[3]=0x56;out[8]=(uint8_t)kind;size_t i=12;
    if(kind==1) {
        if(!account || !password || !device || !service || !*account || !*password || !*device) return -1;
        if(!tlv(out,cap,&i,1,account,strlen(account)) || !tlv(out,cap,&i,2,password,strlen(password)) || !tlv(out,cap,&i,7,device,strlen(device)) || !tlv(out,cap,&i,29,"",0)) return -1;
        /* Match inode-modern's deployed option values, including TAKE_VERSION=1.
         * The Mac engine emits its own real version extension, not a forged Linux one. */
        /* E0585 moved these integer fields to 48/49/50. Field 30 is now
         * CONNECT-NAME (string), and 31/32 are undefined, so old IDs fail parsing. */
        int quick=profile==NATIVE_MAC_E0585?48:30;
        const int options[][2]={{16,1},{15,0},{17,0},{18,0},{22,1},{11,0},{12,0},{quick,1},{quick+1,0},{quick+2,0},{23,0}};
        for(size_t j=0;j<sizeof(options)/sizeof(options[0]);j++) {uint8_t value[4];be32(value,(uint32_t)options[j][1]);if(!tlv(out,cap,&i,options[j][0],value,4)) return -1;}
    }
    size_t size=i-12;out[9]=(uint8_t)(size>>16);out[10]=(uint8_t)(size>>8);out[11]=(uint8_t)size;return (int)i;
}
int native_summary(const uint8_t *p,size_t n,int *kind,int *state,int *result) {
    if(n<12 || p[4] || p[5] || p[6] || p[7]) return 0;
    if(p[8]==12) {if(p[0] || p[1]) return 0;}
    else if(p[0]!=0x1f || p[1]!=0x55) return 0;
    if(p[8]!=11 && p[8]!=12 && p[8]!=16 && (p[2]!=0x1f || p[3]!=0x56)) return 0;
    size_t len=((size_t)p[9]<<16)|((size_t)p[10]<<8)|p[11];if(len!=n-12) return 0;
    *kind=p[8];*state=-1;*result=-1;int countstate=0,countresult=0;
    for(size_t i=12;i<n;) {
        if(n-i<2 || p[i+1]<2 || p[i+1]>n-i) return 0;
        if(p[i]==14 || p[i]==21) {
            if(p[i+1]!=6) return 0;
            uint32_t value=((uint32_t)p[i+2]<<24)|((uint32_t)p[i+3]<<16)|((uint32_t)p[i+4]<<8)|p[i+5];
            if(value>0x7fffffff) return 0;
            if(p[i]==14) {*state=(int)value;countstate++;}else {*result=(int)value;countresult++;}
        }
        i+=p[i+1];
    }
    return countstate<=1 && countresult<=1;
}
void native_pipe_header(uint8_t p[48],uint32_t sequence,uint32_t length) {
    memset(p,0,48);p[0]=1;le32(p+4,sequence);memcpy(p+8,"./ipc-node/iNodeClient",22);le32(p+40,3);le32(p+44,length);
}

/* Async auth result (kind 16) uses its subprotocol as the connection identifier, not an error code.
 * Field 13 is the actual result; fields 14/21 remain network/EAD state.
 * No strings or credential fields are returned by this function. */
int native_auth_result(const uint8_t *p,size_t n,int *connection,int *result) {
    int kind,state,aux;
    if(!native_summary(p,n,&kind,&state,&aux) || kind!=16) return 0;
    int found=0;*connection=((int)p[2]<<8)|p[3];*result=-1;
    for(size_t i=12;i<n;i+=p[i+1]) {
        if(p[i]==13) {
            if(found++ || p[i+1]!=6) return 0;
            uint32_t v=((uint32_t)p[i+2]<<24)|((uint32_t)p[i+3]<<16)|((uint32_t)p[i+4]<<8)|p[i+5];
            if(v>0x7fffffff) return 0;*result=(int)v;
        }
    }
    return found==1;
}
