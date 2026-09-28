#include "../Sources/Protocol.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
static void request(uint8_t r[600],int type,int length) {
    memset(r,0,600);r[6]=0x12;r[12]=0x88;r[13]=0x8e;r[14]=1;r[18]=1;r[19]=42;r[22]=type;
    r[16]=r[20]=length>>8;r[17]=r[21]=length;
}
int main(void) {
    uint8_t r[600],o[600],mac[6]={2,3,4,5,6,7},ip[4]={10,20,30,40};
    request(r,4,22);r[23]=16;for(int j=0;j<16;j++) r[24+j]=j;
    int n=make_response(r,40,mac,ip,"student@移动","secret",0,1,o,sizeof(o));
    assert(n==40+(int)strlen("student@移动"));assert(!memcmp(o+6,mac,6));assert(o[19]==42);
    FILE *f=fopen(".build/md5-result","wb");assert(f);fwrite(o+24,1,16,f);fclose(f);
    assert(make_response(r,39,mac,ip,"u","secret",0,1,o,sizeof(o))<0);
    r[23]=32;assert(make_response(r,40,mac,ip,"u","secret",0,1,o,sizeof(o))<0);
    request(r,4,22);r[23]=16;for(int j=0;j<16;j++) r[24+j]=j;
    n=make_response(r,40,mac,ip,"u","abc",1,1,o,sizeof(o));assert(n==41);
    for(int j=0;j<16;j++) assert(o[24+j]==((j<3?"abc"[j]:0)^j));
    assert(make_response(r,40,mac,ip,"u","abcdefghijklmnopq",1,1,o,sizeof(o))==-3);
    request(r,1,5);n=make_response(r,60,mac,ip,"student@移动","p",0,1,o,sizeof(o));
    assert(n==23+(int)strlen("student@移动"));assert(!memcmp(o+23,"student@移动",strlen("student@移动")));assert(o[21]==5+strlen("student@移动"));
    n=make_response(r,23,mac,ip,"u","p",0,0,o,sizeof(o));assert(n==24 && o[23]=='u');
    request(r,1,6);r[23]='?';n=make_response(r,24,mac,ip,"u","p",0,1,o,sizeof(o));assert(n==56);assert(o[23]==6);assert(o[52]=='=');assert(o[n-1]=='u');
    n=make_response(r,24,mac,ip,"u","p",0,0,o,sizeof(o));assert(n==62);assert(o[23]==0x15);assert(!memcmp(o+25,ip,4));
    request(r,2,5);assert(make_response(r,23,mac,ip,"u","p",0,1,o,sizeof(o))==67);
    request(r,7,5);n=make_response(r,23,mac,ip,"u","p",0,1,o,sizeof(o));assert(n==26);assert(o[23]==1 && o[24]=='p' && o[25]=='u');
    request(r,7,5);
    n=make_response_with_service(r,23,mac,ip,"student","secret","移动",0,1,o,sizeof(o));
    assert(n==24+2+strlen("移动")+6+7);
    assert(o[23]==2+strlen("移动")+6 && o[24]==0xa1 && o[25]==strlen("移动"));
    assert(!memcmp(o+26,"移动",strlen("移动")));
    assert(!memcmp(o+26+strlen("移动"),"secretstudent",13));
    assert(o[21]==n-18 && o[17]==n-18);
    char longpass[241],longservice[65];memset(longpass,'p',240);longpass[240]=0;memset(longservice,'s',64);longservice[64]=0;
    assert(make_response_with_service(r,23,mac,ip,"u",longpass,longservice,0,1,o,sizeof(o))==-4);
    request(r,99,5);assert(make_response(r,23,mac,ip,"u","p",0,1,o,sizeof(o))==-2);
    for(size_t i=0;i<600;i++) assert(make_response(r,i,mac,ip,"u","p",0,1,o,sizeof(o))<0);
    // Exercise truncated and arbitrary frames under sanitizers.
    unsigned seed=123;
    for(int t=0;t<20000;t++) {
        for(int j=0;j<600;j++) { seed=seed*1664525+1013904223;r[j]=seed>>24; }
        make_response(r,(size_t)(t%600),mac,ip,"user","password",0,1,o,sizeof(o));
    }
    char message[300];
    request(r,1,4);r[18]=4;memcpy(r+24,"E3137",5);
    describe_failure(r,29,message,sizeof(message));assert(strstr(message,"E3137"));
    describe_failure(r,22,message,sizeof(message));assert(strstr(message,"无错误码"));
    for(size_t j=0;j<22;j++) describe_failure(r,j,message,sizeof(message));
    char gbk[80];assert(encode_service_gbk("移动",gbk,sizeof(gbk))==4);
    const unsigned char expected_gbk[]={0xd2,0xc6,0xb6,0xaf,0};assert(!memcmp(gbk,expected_gbk,5));
    assert(encode_service_gbk("移动",gbk,3)<0);
    assert(encode_service_gbk("移动",gbk,sizeof(gbk))==4);
    request(r,7,5);n=make_response_with_service(r,23,mac,ip,"student","secret",gbk,0,1,o,sizeof(o));
    assert(o[23]==12 && o[24]==0xa1 && o[25]==4);assert(!memcmp(o+26,expected_gbk,4));
    assert(!memcmp(o+30,"secretstudent",13));assert(n==43);
    puts("packet tests passed");
}
