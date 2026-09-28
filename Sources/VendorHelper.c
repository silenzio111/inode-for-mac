#include "NativeIPC.h"
#include "VendorNotice.h"
#include "EAPTrace.h"
#include "AppleEAP.h"
#include "PrivilegeBroker.h"
#include <sys/stat.h>
#include <sys/socket.h>
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
#include <poll.h>
#include <libgen.h>
#include <pwd.h>
static volatile sig_atomic_t stopped=0;
static void wipe_password(char *p,size_t size) {volatile char *v=p;while(size--) *v++=0;}
static void stop_signal(int sig) {(void)sig;stopped=1;}
static FILE *events;
static NativeEngineProfile engine_profile;
static void event(const char *state,const char *message) {fprintf(events,"%s\t%s\n",state,message);fflush(events);}
static char *clean_env[]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin",NULL};
static int command(char *const args[]) {pid_t p;if(posix_spawn(&p,args[0],NULL,NULL,args,clean_env)) return -1;int s;if(waitpid(p,&s,0)<0) return -1;return WIFEXITED(s)?WEXITSTATUS(s):-1;}
static int send_message(int fd,int kind,const char *user,const char *password,const char *device,const char *service) {
    uint8_t packet[1600],header[48];static uint32_t sequence=0;
    int n=native_message(packet+48,sizeof(packet)-48,kind,user,password,device,service,engine_profile);
    if(n<0) return 0;native_pipe_header(header,sequence++,(uint32_t)n);memcpy(packet,header,48);
    ssize_t written=write(fd,packet,(size_t)n+48);memset(packet,0,sizeof(packet));return written==n+48;
}
static uint32_t le32(const uint8_t *p) {return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static int read_line(FILE *f,char *buffer,size_t capacity) {
    if(!fgets(buffer,(int)capacity,f)) return 0;
    char *end=strchr(buffer,'\n');if(!end) return 0;*end=0;return 1;
}
static int session_main(int argc,char **argv,const char *vendor_template_override) {
    if(argc!=3 || (strcmp(argv[1],"--session") && strcmp(argv[1],"--probe-session") && strcmp(argv[1],"--peap-session"))) { fprintf(stderr,"Usage: inode-helper --session|--peap-session DIR\n");return 2; }
    int probe=!strcmp(argv[1],"--probe-session");
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
    if(!strcmp(argv[1],"--peap-session")) {
        int result=apple_eap_run(dev,user,pass,parent_pid,stop,&stopped,event);
        wipe_password(pass,sizeof(pass));fclose(events);return result;
    }
    event("starting","原厂引擎后端 0.4.1：正在准备 Mac 认证组件");
    char resources[1024],template[1200],runtime[1200],config[1300],fifo[1300];
    if(vendor_template_override && vendor_template_override[0]) {
        if(snprintf(template,sizeof(template),"%s",vendor_template_override)>=(int)sizeof(template)) {
            event("error","认证组件路径过长");event("stopped","原厂认证会话已结束");fclose(events);return 1;
        }
    } else {
        if(!realpath(argv[0],resources)) {event("error","无法定位认证组件");event("stopped","原厂认证会话已结束");fclose(events);return 1;}
        char *slash=strrchr(resources,'/');if(!slash) return 1;*slash=0;
        snprintf(template,sizeof(template),"%s/vendor-mac",resources);
    }
    snprintf(runtime,sizeof(runtime),"%s/runtime",argv[2]);
    struct stat engine_stat;
    snprintf(config,sizeof(config),"%s/AuthenMngService",template);
    if(stat(config,&engine_stat)!=0) {
        struct passwd *owner=getpwuid(ds.st_uid);
        if(!owner || snprintf(template,sizeof(template),"%s/Library/Application Support/iNode for Mac/vendor-mac",owner->pw_dir)>=(int)sizeof(template)) {
            event("error","无法定位本地 iNode 认证组件");event("stopped","原厂认证会话已结束");fclose(events);return 1;
        }
        struct stat staged;
        snprintf(config,sizeof(config),"%s/AuthenMngService",template);
        if(lstat(template,&staged)!=0 || !S_ISDIR(staged.st_mode) || staged.st_uid!=ds.st_uid || (staged.st_mode&022)!=0 || stat(config,&engine_stat)!=0 || !S_ISREG(engine_stat.st_mode)) {
            event("error","缺少 iNode 认证组件，请按发行包说明在本机安装组件");event("stopped","原厂认证会话已结束");fclose(events);return 1;
        }
        event("notice","使用本机安装的 iNode 认证组件");
    }
    snprintf(config,sizeof(config),"%s/engine-info.txt",template);FILE *info=fopen(config,"r");
    if(info) {char label[140],message[180];if(fgets(label,sizeof(label),info)) {label[strcspn(label,"\r\n")]=0;snprintf(message,sizeof(message),"使用认证引擎：%s",label);event("notice",message);}fclose(info);}
    snprintf(config,sizeof(config),"%s/ipc-profile.txt",template);info=fopen(config,"r");int profile=-1;
    if(info) {if(fscanf(info,"%d",&profile)!=1) profile=-1;fclose(info);}
    if(profile!=NATIVE_MAC_E0524 && profile!=NATIVE_MAC_E0585) {event("error","认证组件缺少匹配的控制参数表，请重新构建应用");event("stopped","原厂认证会话已结束");fclose(events);return 1;}
    engine_profile=(NativeEngineProfile)profile;
    event("notice",engine_profile==NATIVE_MAC_E0585?"已加载 E0585 控制参数表（恢复与重试字段 48/49/50）":"已加载 E0524 控制参数表（恢复与重试字段 30/31/32）");
    char *cp[]={"/bin/cp","-R",template,runtime,NULL};
    if(command(cp)!=0 || chmod(runtime,0700)!=0) {event("error","无法准备原厂运行目录");event("stopped","原厂认证会话已结束");fclose(events);return 1;}
    snprintf(config,sizeof(config),"%s/inodesys.conf",runtime);FILE *cf=fopen(config,"w");
    if(!cf) {event("error","无法准备原厂配置");event("stopped","原厂认证会话已结束");fclose(events);return 1;}fprintf(cf,"INSTALL_DIR=%s\n",runtime);fclose(cf);chmod(config,0600);
    snprintf(config,sizeof(config),"%s/conf/iNode.conf",runtime);cf=fopen(config,"w");
    if(cf) {fprintf(cf,"LOG_LEVEL=0\nFORBID_PAP=0\n");fclose(cf);chmod(config,0600);}
    snprintf(config,sizeof(config),"%s/ipc-node",runtime);mkdir(config,0700);chmod(config,0700);
    if(chdir(runtime)!=0) {event("error","无法切换原厂运行目录");event("stopped","原厂认证会话已结束");fclose(events);return 1;}
    char engine[1300];snprintf(engine,sizeof(engine),"%s/AuthenMngService",runtime);pid_t engine_pid=0;
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions,0,"/dev/null",O_RDONLY,0);
    posix_spawn_file_actions_addopen(&actions,1,"/dev/null",O_WRONLY,0);
    posix_spawn_file_actions_addopen(&actions,2,"/dev/null",O_WRONLY,0);
    char library_env[1400];snprintf(library_env,sizeof(library_env),"DYLD_LIBRARY_PATH=%s/lib",runtime);
    char *engine_env[]={clean_env[0],library_env,NULL};
    char *engine_args[]={engine,NULL};int launched=posix_spawn(&engine_pid,engine,&actions,NULL,engine_args,engine_env);posix_spawn_file_actions_destroy(&actions);
    pcap_t *trace=NULL;uint8_t local_mac[6]={0};
    int rx=-1,tx=-1,failed=0,online=0,previous_state=-2,previous_aux=-2;time_t started=time(NULL),last_status=0,last_reply=0;uint8_t buffer[32768];size_t used=0;
    if(launched) {event("error","原厂引擎无法启动，请检查 Rosetta 和组件完整性");failed=1;goto done;}
    snprintf(fifo,sizeof(fifo),"%s/ipc-node/iNodeClient",runtime);
    while(time(NULL)-started<25 && !stopped && access(stop,F_OK)!=0) {
        int status;if(waitpid(engine_pid,&status,WNOHANG)==engine_pid) {engine_pid=0;event("error","原厂引擎启动后退出");failed=1;goto done;}
        struct stat fs;if(!lstat(fifo,&fs) && S_ISFIFO(fs.st_mode)) {rx=open(fifo,O_RDWR|O_NONBLOCK|O_NOFOLLOW);break;}
        usleep(100000);
    }
    snprintf(fifo,sizeof(fifo),"%s/ipc-node/iNodeCmn",runtime);tx=open(fifo,O_WRONLY|O_NONBLOCK|O_NOFOLLOW);
    if(rx<0 || tx<0) {event("error","原厂认证控制接口未就绪");failed=1;goto done;}
    event("notice","已连接 Mac 原厂认证控制接口（命名管道）");
    if(!probe) event("notice",strchr(user,'@')?"认证账号已包含域后缀；密码原样提交":"认证账号未指定域后缀；密码原样提交");
    if(!probe) {
        trace=eap_trace_open(dev,local_mac);
        event("notice",trace?"已启用有线认证阶段观察，仅记录类型和长度":"有线认证阶段观察不可用，仍可继续认证");
        event("notice","连接选项对齐 Linux 项目：上传原厂 Mac 版本，关闭上传 IP；密码原样提交");
    }
    /* Credentials remain in the private root-owned runtime, never in a UDP packet. */
    if(!probe && !send_message(tx,1,user,pass,dev,service)) {event("error","无法向原厂引擎发送连接请求");failed=1;goto done;}
    /* Keep password only in memory to redact echoed notification text. */
    started=time(NULL);event("notice",probe?"仅查询状态，不发送认证凭据":"原厂引擎正在认证");
    if(!probe) event("phase","正在等待校园网认证结果…");
    while(!stopped && access(stop,F_OK)!=0) {
        if(kill(parent_pid,0)<0 && errno==ESRCH) break;
        int status;if(waitpid(engine_pid,&status,WNOHANG)==engine_pid) {engine_pid=0;event("error","原厂认证进程已退出");failed=1;break;}
        time_t now=time(NULL);
        eap_trace_drain(trace,local_mac,event);
        if(now-last_status>=2) {if(!send_message(tx,7,NULL,NULL,NULL,NULL)) {event("error","原厂状态查询失败");failed=1;break;}last_status=now;}
        struct pollfd wait={rx,POLLIN,0};int ready=poll(&wait,1,300);
        if(ready>0 && (wait.revents&POLLIN)) {
            ssize_t got=read(rx,buffer+used,sizeof(buffer)-used);if(got>0) used+=(size_t)got;
            while(used>=48) {
                uint32_t length=le32(buffer+44);if(length>sizeof(buffer)-48 || buffer[0]>1) {event("error","原厂返回的控制报文无效");failed=1;goto done;}
                if(used<48+length) break;
                int kind,state,result;
                if((le32(buffer+40)==3 || le32(buffer+40)==1) && native_summary(buffer+48,length,&kind,&state,&result)) {
                    last_reply=now;
                    char notice[1024];
                    if(le32(buffer+40)==1 && vendor_notice(buffer+48,length,user,pass,notice,sizeof(notice))) {
                        char message[1100];snprintf(message,sizeof(message),"原厂通知（已脱敏）：%s",notice);event("notice",message);memset(notice,0,sizeof(notice));
                    }
                    int connection,auth_result;
                    if(le32(buffer+40)==1 && native_auth_result(buffer+48,length,&connection,&auth_result)) {
                        char msg[180];snprintf(msg,sizeof(msg),"原厂认证结果：%s（值 %d）",auth_result==0?"通过":auth_result==1?"失败":"未知",auth_result);event("notice",msg);
                        if(auth_result==1) {event("error","原厂引擎报告认证失败，已停止本次连接；请查看此前的脱敏通知");failed=1;goto done;}
                    }
                    if(probe && kind==8) {event("probe-ok","原厂引擎启动、状态查询与清理路径验证通过");goto done;}
                    if(kind==8 && state==2) {
                        if(!online) {online=1;event("authenticated","Mac 原厂引擎报告校园网认证已通过");char *dhcp[]={"/usr/sbin/ipconfig","set",dev,"DHCP",NULL};if(command(dhcp)) event("warning","认证通过，但 DHCP 刷新失败");}
                    } else if(online && kind==8 && state==1) {event("error","原厂引擎报告认证已断开");failed=1;goto done;}
                    else if(kind==2) event("notice","原厂引擎已接收连接请求（此回执不含认证结果）");
                    else if(kind!=8 && kind!=11 && kind!=12 && kind!=16) {char msg[120];snprintf(msg,sizeof(msg),"原厂控制事件：类型 %d，载荷长度 %u",kind,length);event("notice",msg);}
                    if(kind==8 && state==6 && previous_state!=6) event("notice","原厂引擎进入认证失败后的等待重试状态");
                    if(kind==8 && (state!=previous_state || result!=previous_aux)) {
                        char msg[160];snprintf(msg,sizeof(msg),"原厂网络状态：%d；EAD 状态：%d（不是密码错误码）",state,result);event("notice",msg);previous_state=state;previous_aux=result;
                    }
                }
                size_t consumed=48+length;memmove(buffer,buffer+consumed,used-consumed);used-=consumed;
            }
        }
        if(!online && now-started>45) {event("error",last_reply?"原厂认证等待超时；尚未确认成功，请查看网络状态日志":"原厂引擎没有返回可识别的认证状态");failed=1;break;}
        if(online && last_reply && now-last_reply>12) {event("error","原厂引擎状态响应中断");failed=1;break;}
    }
    done:
    eap_trace_drain(trace,local_mac,event);if(trace) pcap_close(trace);
    if(tx>=0) {send_message(tx,3,NULL,NULL,NULL,NULL);usleep(300000);close(tx);}
    if(rx>=0) close(rx);
    if(engine_pid>0) {kill(engine_pid,SIGTERM);for(int j=0;j<20;j++) {if(waitpid(engine_pid,NULL,WNOHANG)==engine_pid) {engine_pid=0;break;}usleep(100000);}if(engine_pid>0) {kill(engine_pid,SIGKILL);waitpid(engine_pid,NULL,0);}}
    wipe_password(pass,sizeof(pass));chdir("/");char *remove[]={"/bin/rm","-rf",runtime,NULL};command(remove);
    event("stopped",failed?"原厂认证会话已结束":"已断开原厂认证");fclose(events);return failed?1:0;
}

static int broker_session(const char *session,const char *vendor_template) {
    char *arguments[]={"inode-helper","--session",(char *)session,NULL};
    return session_main(3,arguments,vendor_template);
}

int main(int argc,char **argv) {
    if(argc==4 && !strcmp(argv[1],"--broker"))
        return privilege_broker_run(argv[2],argv[3],argv[0],broker_session);
    return session_main(argc,argv,NULL);
}
