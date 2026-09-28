#include "VendorNotice.h"
#include "NativeIPC.h"
#include <iconv.h>
#include <regex.h>
#include <string.h>

static int decode(const uint8_t *data,size_t size,const char *encoding,char *out,size_t cap) {
    iconv_t converter=iconv_open("UTF-8",encoding);
    if(converter==(iconv_t)-1 || cap<1) return 0;
    char *input=(char *)data,*output=out;size_t available=cap-1;
    size_t converted=iconv(converter,&input,&size,&output,&available);
    iconv_close(converter);
    if(converted==(size_t)-1 || size) {out[0]=0;return 0;}
    *output=0;return 1;
}
/* Replace in place, preserving UTF-8 byte boundaries and never expanding text. */
static void hide_literal(char *text,const char *secret) {
    if(!secret || !*secret) return;
    size_t n=strlen(secret);char *match;
    while((match=strstr(text,secret))) {
        /* Equal-length stars prevent short secrets from reappearing in replacements. */
        memset(match,'*',n);
        if(strspn(secret,"*")==n) break;
    }
}
static int redact_patterns(char *text) {
    regex_t pattern;
    const char *expression="([0-9]{1,3}\\.){3}[0-9]{1,3}|([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}|[0-9A-Fa-f]*(:[0-9A-Fa-f]*){3,}|[0-9]{4,}";
    if(regcomp(&pattern,expression,REG_EXTENDED)) return 0;
    regmatch_t match;
    while(!regexec(&pattern,text,1,&match,0)) {
        memset(text+match.rm_so,'*',(size_t)(match.rm_eo-match.rm_so));
    }
    regfree(&pattern);return 1;
}
int vendor_notice(const uint8_t *p,size_t n,const char *account,const char *password,char *out,size_t cap) {
    if(!cap) return 0;out[0]=0;
    int kind,state,aux;
    if(!native_summary(p,n,&kind,&state,&aux) || (kind!=11 && kind!=12)) return 0;
    const uint8_t *text=NULL;size_t size=0;
    for(size_t i=12;i<n;i+=p[i+1]) {
        if(p[i]==3) {
            if(text) return 0;
            text=p+i+2;size=p[i+1]-2;
        }
    }
    if(!text || !size) return 0;
    if(text[size-1]==0) size--;
    if(!size || memchr(text,0,size)) return 0;
    char decoded[1024];
    if(!decode(text,size,"UTF-8",decoded,sizeof(decoded)) &&
       !decode(text,size,"GB18030",decoded,sizeof(decoded))) return 0;
    hide_literal(decoded,password);hide_literal(decoded,account);
    for(char *c=decoded;*c;c++) if((unsigned char)*c<32 || *c==127) *c=' ';
    if(!redact_patterns(decoded) || strlen(decoded)>=cap) {memset(decoded,0,sizeof(decoded));return 0;}
    strcpy(out,decoded);memset(decoded,0,sizeof(decoded));return 1;
}
