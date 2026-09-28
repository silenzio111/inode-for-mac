#include "Protocol.h"
#include <pcap/pcap.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <net/if_dl.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <spawn.h>
#include <sys/wait.h>
static volatile sig_atomic_t stopped=0;
static void stop_signal(int sig) { (void)sig;stopped=1; }
static FILE *events;
static void event(const char *state,const char *message) { fprintf(events,"%s\t%s\n",state,message);fflush(events); }
static int addresses(const char *name,uint8_t mac[6],uint8_t ip[4]) {
    struct ifaddrs *all=NULL;int found=0;memset(ip,0,4);
    if(getifaddrs(&all)) return 0;
    for(struct ifaddrs *a=all;a;a=a->ifa_next) {
        if(!a->ifa_addr || strcmp(a->ifa_name,name)) continue;
        if(a->ifa_addr->sa_family==AF_LINK) {
            struct sockaddr_dl *dl=(void *)a->ifa_addr;
            if(dl->sdl_alen==6) { memcpy(mac,LLADDR(dl),6);found=1; }
        } else if(a->ifa_addr->sa_family==AF_INET) {
            memcpy(ip,&((struct sockaddr_in *)a->ifa_addr)->sin_addr,4);
            if(ip[0]==169 && ip[1]==254) memset(ip,0,4);
        }
    }
    freeifaddrs(all);return found;
}
static int control(pcap_t *h,const uint8_t mac[6],const uint8_t dest[6],int type) {
    uint8_t o[18]={0};memcpy(o,dest,6);memcpy(o+6,mac,6);
    o[12]=0x88;o[13]=0x8e;o[14]=1;o[15]=(uint8_t)type;
    return pcap_sendpacket(h,o,18);
}
static int read_line(FILE *f,char *buf,size_t n) {
    if(!fgets(buf,(int)n,f)) return 0;
    char *end=strchr(buf,'\n');if(!end) return 0;*end=0;return 1;
}
int main(int argc,char **argv) {
    if(argc!=3 || strcmp(argv[1],"--session")) { fprintf(stderr,"Usage: inode-helper --session DIR\n");return 2; }
    struct stat ds,cs;char cfg[1024],out[1024],stop[1024];
    if(strlen(argv[2])>900 || lstat(argv[2],&ds) || !S_ISDIR(ds.st_mode) || (ds.st_mode&077)!=0 || ds.st_uid==0) return 2;
    snprintf(cfg,sizeof(cfg),"%s/credentials",argv[2]);snprintf(out,sizeof(out),"%s/events",argv[2]);snprintf(stop,sizeof(stop),"%s/stop",argv[2]);
    int fd=open(cfg,O_RDONLY|O_NOFOLLOW);if(fd<0) return 2;
    if(fstat(fd,&cs) || !S_ISREG(cs.st_mode) || cs.st_uid!=ds.st_uid || (cs.st_mode&077)!=0 || cs.st_size>1500) {close(fd);return 2;}
    FILE *f=fdopen(fd,"r");char dev[32],user[256],pass[256],mode[16],parent[32],service[80]={0},encoding[16]={0};
    int valid=read_line(f,dev,sizeof(dev)) && read_line(f,user,sizeof(user)) && read_line(f,pass,sizeof(pass)) && read_line(f,mode,sizeof(mode)) && read_line(f,parent,sizeof(parent));
    if(valid && !feof(f)) {read_line(f,service,sizeof(service));read_line(f,encoding,sizeof(encoding));}
    fclose(f);unlink(cfg);
    if(!valid || strncmp(dev,"en",2) || !dev[2] || strspn(dev+2,"0123456789")!=strlen(dev+2) || !user[0] || !pass[0]) return 2;
    pid_t parent_pid=(pid_t)strtol(parent,NULL,10);if(parent_pid<=1) return 2;
    fd=open(out,O_WRONLY|O_APPEND|O_NOFOLLOW);if(fd<0) return 2;
    if(fstat(fd,&cs) || !S_ISREG(cs.st_mode) || cs.st_uid!=ds.st_uid || (cs.st_mode&077)!=0) {close(fd);return 2;}
    events=fdopen(fd,"a");signal(SIGTERM,stop_signal);signal(SIGINT,stop_signal);
    if(!strcmp(encoding,"GBK")) {
        char converted[80];
        if(encode_service_gbk(service,converted,sizeof(converted))<0) {event("error","服务域无法转换成 GBK，请检查域名称");return 1;}
        memcpy(service,converted,strlen(converted)+1);
    }
    event("notice",!strcmp(encoding,"GBK")?"服务域编码：GBK":"服务域编码：UTF-8");
    uint8_t mac[6],ip[4],server[6]={0};
    const uint8_t multi[6]={1,0x80,0xc2,0,0,3},broadcast[6]={255,255,255,255,255,255};
    if(!addresses(dev,mac,ip)) {event("error","找不到选中的有线网卡");return 1;}
    char error[PCAP_ERRBUF_SIZE];pcap_t *h=pcap_create(dev,error);
    if(!h) {event("error","无法创建认证会话");return 1;}
    pcap_set_snaplen(h,2048);pcap_set_promisc(h,0);pcap_set_timeout(h,500);pcap_set_immediate_mode(h,1);
    if(pcap_activate(h)<0 || pcap_datalink(h)!=DLT_EN10MB || pcap_setnonblock(h,1,error)<0) {event("error","无法打开有线网卡，请检查管理员授权");pcap_close(h);return 1;}
    char filter[200];snprintf(filter,sizeof(filter),"ether proto 0x888e and not ether src %02x:%02x:%02x:%02x:%02x:%02x and (ether dst %02x:%02x:%02x:%02x:%02x:%02x or ether multicast)",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5],mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    struct bpf_program bpf;
    if(pcap_compile(h,&bpf,filter,1,PCAP_NETMASK_UNKNOWN)<0) {event("error","无法建立认证过滤器");pcap_close(h);return 1;}
    int filter_result=pcap_setfilter(h,&bpf);pcap_freecode(&bpf);
    if(filter_result<0) {event("error","无法应用认证过滤器");pcap_close(h);return 1;}
    event("starting","认证组件 0.1.3：正在等待宿舍交换机响应");int first=1,authenticated=0,have_server=0,failed=0;time_t begun=time(NULL),last_start=0;
    while(!stopped && access(stop,F_OK)!=0) {
        if(kill(parent_pid,0)<0 && errno==ESRCH) break;
        time_t now=time(NULL);
        if(!have_server && now-last_start>=3) {
            if(control(h,mac,broadcast,1) || control(h,mac,multi,1)) {event("error","无法发送认证请求");failed=1;break;}
            last_start=now;
        }
        if(!authenticated && now-begun>40) {event("error","认证超时，请检查账号域、网口和学校认证要求");failed=1;break;}
        struct pcap_pkthdr *hdr;const uint8_t *r;int result=pcap_next_ex(h,&hdr,&r);
        if(result==0) {usleep(100000);continue;}
        if(result<0) {event("error","网卡会话中断，请重新插入网线");failed=1;break;}
        size_t n=hdr->caplen;if(n<22 || r[15]!=0) continue;
        size_t len=((size_t)r[20]<<8)|r[21],ol=((size_t)r[16]<<8)|r[17];
        if(len<4 || len>ol || ol>n-18 || (have_server && memcmp(server,r+6,6))) continue;
        if(!have_server) {
            if(r[18]!=1 || len<5 || (r[22]!=1 && r[22]!=2 && r[22]!=20)) continue;
            memcpy(server,r+6,6);have_server=1;
        }
        if(r[18]==3) {
            if(!authenticated) {
                authenticated=1;event("authenticated","校园网认证已通过，正在等待有线 IPv4 地址");
                pid_t child;char *args[]={"/usr/sbin/ipconfig","set",dev,"DHCP",NULL};char *env[]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin",NULL};
                if(!posix_spawn(&child,args[0],NULL,NULL,args,env)) {int status;waitpid(child,&status,0);if(status) event("warning","认证通过，但 DHCP 刷新失败");}
            }
        } else if(r[18]==4) {
            char message[300];
            describe_failure(r,n,message,sizeof(message));
            event("error",message);failed=1;break;
        } else if(r[18]==10) {
            if(n>=59 && r[25]==0x2b && r[26]==0x35) {event("error","服务器要求专用客户端完整性校验，当前测试版尚未适配此校验");failed=1;break;}
            event("notice","收到 H3C 会话通知");
        } else if(r[18]==1) {
            char stage[120];snprintf(stage,sizeof(stage),"收到认证请求：类型 %u，EAP 长度 %zu",len>=5?r[22]:0,len);event("notice",stage);
            uint8_t response[600];addresses(dev,mac,ip);
            int length=make_response_with_service(r,n,mac,ip,user,pass,service,atoi(mode),first,response,sizeof(response));
            if(length<0) {
                char message[180];snprintf(message,sizeof(message),"无法处理服务器认证请求（类型 %u，状态 %d），需要进一步适配",len>=5?r[22]:0,length);
                event("error",message);failed=1;break;
            }
            if(pcap_sendpacket(h,response,length)) {event("error","认证响应发送失败");failed=1;break;}
            if(r[22]==1 || r[22]==20) {first=0;event("identity",r[22]==1 && len==5?"已发送标准账号响应（未附加 H3C 版本字段）":"已发送 H3C 扩展账号响应");}
            else if(r[22]==7) event("challenge",service[0]?"已发送 H3C PAP 密码响应（包含独立服务域）":"已发送 H3C PAP 密码响应（未选择服务域）");
            else if(r[22]==4) event("challenge","已回应 MD5 密码认证请求");
            memset(response,0,sizeof(response));
        }
    }
    control(h,mac,have_server?server:multi,2);pcap_close(h);memset(pass,0,sizeof(pass));
    event("stopped",failed?"认证会话已结束":"已断开有线认证");fclose(events);return failed?1:0;
}
