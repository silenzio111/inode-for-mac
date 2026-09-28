#include "Protocol.h"
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <iconv.h>
#include <CommonCrypto/CommonDigest.h>
static void scramble(uint8_t *p, size_t n, const char *key) {
    size_t k = strlen(key);
    for (size_t i=0;i<n;i++) p[i] ^= key[i%k] ^ key[(n-1-i)%k];
}
static void version(uint8_t p[20]) {
    memset(p,0,20); memcpy(p,"EN\x11V7.30-0538",13);
    uint32_t t=(uint32_t)time(NULL); char k[9]; snprintf(k,sizeof(k),"%08x",t);
    scramble(p,16,k);
    for(int i=0;i<4;i++) p[16+i]=(uint8_t)(t>>(24-i*8));
    scramble(p,20,"HuaWei3COM1X");
}
static void base64(const uint8_t *p, uint8_t out[28]) {
    const char *alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for(int j=0;j<27;j++) {
        int bit=j*6, index=bit/8, shift=bit%8;
        unsigned v=(unsigned)p[index]<<8;
        if(index+1<20) v|=p[index+1];
        out[j]=(uint8_t)alphabet[(v>>(10-shift))&63];
    }
    out[27]='=';
}
int make_response_with_service(const uint8_t *r,size_t n,const uint8_t mac[6],const uint8_t ip[4],
                  const char *user,const char *pass,const char *service,int xor_mode,int first,uint8_t *o,size_t cap) {
    size_t u=strlen(user), p=strlen(pass), d=strlen(service);
    if(n<23 || r[12]!=0x88 || r[13]!=0x8e || r[15]!=0 || r[18]!=1 || u>240 || p>240 || d>64 || cap<600) return -1;
    size_t eap=((size_t)r[20]<<8)|r[21], ol=((size_t)r[16]<<8)|r[17];
    if(eap<5 || eap>ol || ol>n-18) return -1;
    memset(o,0,cap); memcpy(o,r+6,6); memcpy(o+6,mac,6);
    o[12]=0x88;o[13]=0x8e;o[14]=1;o[18]=2;o[19]=r[19];o[22]=r[22];
    size_t i=23;
    if(r[22]==1 && eap==5) {
        /* RFC 3748 section 5.1: the response Type-Data is the identity.
           Bare requests receive the UTF-8 account without vendor prefixes. */
        memcpy(o+i,user,u);i+=u;
    } else if(r[22]==1 || r[22]==20) {
        if(r[22]==20) o[i++]=0;
        if(!first || r[22]==20) { o[i++]=0x15;o[i++]=4;memcpy(o+i,ip,4);i+=4; }
        uint8_t v[20];version(v);o[i++]=6;o[i++]=7;base64(v,o+i);i+=28;
        o[i++]=' ';o[i++]=' ';memcpy(o+i,user,u);i+=u;
    } else if(r[22]==4) {
        if(eap<6 || n<24 || r[23]!=16 || eap<22) return -1;
        o[i++]=16;
        if(xor_mode) {
            if(p>16) return -3;
            for(size_t j=0;j<16;j++) o[i+j]=(j<p?(uint8_t)pass[j]:0)^r[24+j];
        } else {
            uint8_t material[257];material[0]=r[19];memcpy(material+1,pass,p);memcpy(material+1+p,r+24,16);
            CC_MD5(material,(CC_LONG)(p+17),o+i);memset(material,0,sizeof(material));
        }
        i+=16;memcpy(o+i,user,u);i+=u;
    } else if(r[22]==7) {
        /* Verified against the school's MakePapEap implementation:
           type 7 | value length | [0xA1 | domain length | domain] | password | account.
           With no domain, the original password-only value is used. */
        size_t value_length=p+(d?d+2:0);
        if(value_length>255) return -4;
        o[i++]=(uint8_t)value_length;
        if(d) {o[i++]=0xa1;o[i++]=(uint8_t)d;memcpy(o+i,service,d);i+=d;}
        memcpy(o+i,pass,p);i+=p;memcpy(o+i,user,u);i+=u;
    } else if(r[22]==2) {
        uint8_t v[20];version(v);o[i++]=1;o[i++]=22;memcpy(o+i,v,20);i+=20;
        uint8_t os[20]={0};memcpy(os,"r70393861",9);scramble(os,20,"HuaWei3COM1X");
        o[i++]=2;o[i++]=22;memcpy(o+i,os,20);i+=20;
    } else return -2;
    size_t len=i-18;o[16]=o[20]=(uint8_t)(len>>8);o[17]=o[21]=(uint8_t)len;
    return (int)i;
}

int make_response(const uint8_t *r,size_t n,const uint8_t mac[6],const uint8_t ip[4],
                  const char *user,const char *pass,int xor_mode,int first,uint8_t *o,size_t cap) {
    return make_response_with_service(r,n,mac,ip,user,pass,"",xor_mode,first,o,cap);
}

void describe_failure(const uint8_t *r, size_t n, char *message, size_t capacity) {
    if(n<22) { snprintf(message,capacity,"认证失败：服务器报文不完整");return; }
    /* Some H3C failures append a vendor message beyond the declared EAP length.
       Scan only captured bytes and extract a fixed-format numeric code. */
    for(size_t i=22;i+5<=n;i++) {
        if(r[i]!='E') continue;
        int digits=1;for(size_t j=1;j<5;j++) if(r[i+j]<'0' || r[i+j]>'9') digits=0;
        if(!digits) continue;
        char code[6];memcpy(code,r+i,5);code[5]=0;
        const char *reason="需要核对账号或客户端兼容性";
        if(!strcmp(code,"E2531")) reason="服务器报告用户名不存在";
        else if(!strcmp(code,"E2553")) reason="服务器报告密码校验失败";
        else if(!strcmp(code,"E2542")) reason="服务器报告账号已在其他设备登录";
        else if(!strcmp(code,"E3137")) reason="服务器报告客户端版本无效";
        else if(!strcmp(code,"E2535")) reason="服务器报告账号服务已暂停";
        else if(!strcmp(code,"E2547")) reason="服务器报告接入时段受限";
        snprintf(message,capacity,"认证被拒绝（%s）：%s",code,reason);return;
    }
    unsigned eap=((unsigned)r[20]<<8)|r[21];
    int padding_only=1;for(size_t j=22;j<n;j++) if(r[j]!=0) padding_only=0;
    if(n>22 && !padding_only) snprintf(message,capacity,"服务器拒绝认证（EAP 长度 %u，报文长度 %zu，扩展类型 0x%02X）；尚无法确定原因",eap,n,r[22]);
    else snprintf(message,capacity,"服务器拒绝认证（无错误码，EAP 长度 %u）；尚无法确定原因",eap);
}

int encode_service_gbk(const char *utf8, char *output, size_t capacity) {
    if(capacity<1) return -1;
    iconv_t converter=iconv_open("GBK","UTF-8");if(converter==(iconv_t)-1) return -1;
    char *input=(char *)utf8,*dst=output;size_t remaining=strlen(utf8),space=capacity-1;
    size_t result=iconv(converter,&input,&remaining,&dst,&space);iconv_close(converter);
    if(result==(size_t)-1 || remaining) {output[0]=0;return -1;}
    *dst=0;return (int)(dst-output);
}
