#include "../Sources/NativeIPC.h"
#include "../Sources/VendorNotice.h"
#include "../Sources/EAPTrace.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
static size_t notice_packet(uint8_t *p,int kind,int field,const void *text,size_t size) {
 memset(p,0,2000);if(kind==11) {p[0]=0x1f;p[1]=0x55;}
 p[2]=0x1f;p[3]=0x56;p[8]=(uint8_t)kind;p[11]=(uint8_t)(size+2);
 p[12]=(uint8_t)field;p[13]=(uint8_t)(size+2);memcpy(p+14,text,size);return size+14;
}
static void test_notices(void) {
 uint8_t p[2000];char out[1024];
 const char *text="认证失败 user=SyntheticUser password=DummySecret! IP=10.20.30.40 MAC=aa:bb:cc:dd:ee:ff 学号=12345678\nerror\tmessage";
 size_t n=notice_packet(p,11,3,text,strlen(text));
 assert(vendor_notice(p,n,"SyntheticUser","DummySecret!",out,sizeof(out)));
 assert(strstr(out,"认证失败") && strstr(out,"error message"));
 assert(!strstr(out,"SyntheticUser") && !strstr(out,"DummySecret!") && !strstr(out,"10.20.30.40") && !strstr(out,"aa:bb:cc:dd:ee:ff") && !strstr(out,"12345678"));
 assert(!strchr(out,'\n') && !strchr(out,'\t'));
 for(size_t i=0;i<n;i++) assert(!vendor_notice(p,i,"u","p",out,sizeof(out)));
 /* GBK encoding of 密码错误; the engine's older strings use this encoding. */
 const uint8_t gbk[]={0xc3,0xdc,0xc2,0xeb,0xb4,0xed,0xce,0xf3};
 n=notice_packet(p,12,3,gbk,sizeof(gbk));assert(vendor_notice(p,n,"user","secret",out,sizeof(out)));assert(!strcmp(out,"密码错误"));
 assert(!vendor_notice(p,n,"user","secret",out,5));
 n=notice_packet(p,11,2,text,strlen(text));assert(!vendor_notice(p,n,"u","p",out,sizeof(out))); /* Never output password fields. */
 const uint8_t bad[]={0xff};n=notice_packet(p,11,3,bad,sizeof(bad));assert(!vendor_notice(p,n,"u","p",out,sizeof(out)));
 const uint8_t hidden[]={'a',0,'b'};n=notice_packet(p,11,3,hidden,sizeof(hidden));assert(!vendor_notice(p,n,"u","p",out,sizeof(out)));
 puts("notification decoding, redaction, and boundary tests passed");
}
static void test_eap_trace(void) {
 const uint8_t local[6]={2,1,2,3,4,5},server[6]={2,6,7,8,9,10};uint8_t frame[128]={0};char out[256];
 memcpy(frame,local,6);memcpy(frame+6,server,6);frame[12]=0x88;frame[13]=0x8e;frame[14]=1;
 frame[17]=5;frame[18]=1;frame[19]=23;frame[21]=5;frame[22]=1;
 assert(eap_metadata(frame,23,local,out,sizeof(out)));assert(strstr(out,"收到 EAP-Request，方法 1，长度 5"));
 for(size_t i=0;i<23;i++) assert(!eap_metadata(frame,i,local,out,sizeof(out)));
 /* A password response is reduced to method and length, without reading its text. */
 const char *secret="synthetic-password";size_t n=strlen(secret);memcpy(frame,server,6);memcpy(frame+6,local,6);
 frame[18]=2;frame[22]=7;frame[23]=(uint8_t)n;memcpy(frame+24,secret,n);frame[17]=frame[21]=(uint8_t)(n+6);
 assert(eap_metadata(frame,24+n,local,out,sizeof(out)));assert(strstr(out,"发送 EAP-Response，方法 7"));assert(!strstr(out,secret));
 frame[17]=255;assert(!eap_metadata(frame,24+n,local,out,sizeof(out)));frame[17]=frame[21];
 assert(!eap_metadata(frame,24+n,local,out,1));
 frame[18]=4;frame[17]=frame[21]=4;memcpy(frame,local,6);memcpy(frame+6,server,6);
 assert(eap_metadata(frame,22,local,out,sizeof(out)));assert(strstr(out,"EAP-Failure"));
 frame[0]=4;assert(!eap_metadata(frame,22,local,out,sizeof(out)));frame[0]=local[0];
 /* A tagged failure should yield the same metadata as an untagged one. */
 memmove(frame+18,frame+14,8);frame[12]=0x81;frame[13]=0;frame[14]=0;frame[15]=7;frame[16]=0x88;frame[17]=0x8e;
 assert(eap_metadata(frame,26,local,out,sizeof(out)));assert(strstr(out,"EAP-Failure"));
 puts("EAP metadata privacy and packet boundary tests passed");
}
int main(void) {
 uint8_t p[2000],hdr[48];int kind,state,result;
 int n=native_message(p,sizeof(p),1,"synthetic-user","synthetic-password","en8","",NATIVE_MAC_E0524);assert(n>12);
 FILE *f=fopen(".build/native-connect-school.bin","wb");assert(f);fwrite(p,1,n,f);fclose(f);
 uint8_t other[2000];int othern=native_message(other,sizeof(other),1,"synthetic-user","synthetic-password","en8","移动",NATIVE_MAC_E0524);
 assert(othern==n && !memcmp(p,other,n)); /* Realm must never become an RSA key. */
 othern=native_message(other,sizeof(other),1,"synthetic-user","synthetic-password","en8","",NATIVE_MAC_E0585);assert(othern==n);
 f=fopen(".build/native-connect-sequoia.bin","wb");assert(f);fwrite(other,1,othern,f);fclose(f);
 for(size_t i=12;i<(size_t)n;i+=p[i+1]) {
  if(p[i]>=30 && p[i]<=32) {assert(other[i]==p[i]+18);assert(!memcmp(p+i+1,other+i+1,p[i+1]-1));}
  else assert(!memcmp(p+i,other+i,p[i+1]));
 }
 for(int profile=0;profile<=1;profile++) {
  int len=native_message(other,sizeof(other),1,"synthetic-user","synthetic-password","en999999","",(NativeEngineProfile)profile);assert(len>12);
  f=fopen(profile?".build/native-offline-sequoia.bin":".build/native-offline-school.bin","wb");assert(f);fwrite(other,1,len,f);fclose(f);
 }
 assert(native_message(other,sizeof(other),1,"u","p","en8","",(NativeEngineProfile)99)<0);
 uint8_t ack[]={0x1f,0x55,0x1f,0x56,0,0,0,0,2,0,0,0};
 assert(native_summary(ack,sizeof(ack),&kind,&state,&result));assert(kind==2 && state==-1 && result==-1);
 native_pipe_header(hdr,5,n);assert(hdr[0]==1 && hdr[4]==5 && hdr[40]==3);assert(!memcmp(hdr+8,"./ipc-node/iNodeClient",21));
 n=native_message(p,sizeof(p),7,NULL,NULL,NULL,NULL,NATIVE_MAC_E0585);assert(n==12 && p[8]==7);
 uint8_t response[]={0x1f,0x55,0x1f,0x56,0,0,0,0,8,0,0,12,14,6,0,0,0,1,21,6,0,0,0,1};
 assert(native_summary(response,sizeof(response),&kind,&state,&result));assert(kind==8 && state==1 && result==1);
 response[17]=2;response[23]=0;assert(native_summary(response,sizeof(response),&kind,&state,&result));assert(state==2 && result==0);
 for(size_t i=0;i<sizeof(response);i++) assert(!native_summary(response,i,&kind,&state,&result));
 response[13]=255;assert(!native_summary(response,sizeof(response),&kind,&state,&result));
 response[13]=6;response[18]=14;assert(!native_summary(response,sizeof(response),&kind,&state,&result));
 char longvalue[255];memset(longvalue,'a',254);longvalue[254]=0;assert(native_message(p,sizeof(p),1,longvalue,"p","en8","",NATIVE_MAC_E0585)<0);
 uint8_t async[]={0x1f,0x55,0,42,0,0,0,0,16,0,0,18,13,6,0,0,0,1,14,6,0,0,0,6,21,6,0,0,0,1};
 int reason,actual;assert(native_auth_result(async,sizeof(async),&reason,&actual));assert(reason==42 && actual==1);
 async[17]=0;async[23]=2;assert(native_auth_result(async,sizeof(async),&reason,&actual));assert(actual==0);
 async[8]=8;assert(!native_summary(async,sizeof(async),&kind,&state,&result));
 async[8]=16;async[13]=3;assert(!native_auth_result(async,sizeof(async),&reason,&actual));
 test_notices();test_eap_trace();puts("native IPC tests passed");
}
