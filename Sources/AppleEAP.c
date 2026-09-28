#include "AppleEAP.h"
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static CFMutableDictionaryRef dictionary(void) {
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
CFDictionaryRef apple_eap_configuration(const char *user, const char *password, CFStringRef identifier) {
    if (!user || !*user || !password || !*password || !identifier) return NULL;
    CFStringRef name = CFStringCreateWithCString(NULL, user, kCFStringEncodingUTF8);
    CFStringRef secret = CFStringCreateWithCString(NULL, password, kCFStringEncodingUTF8);
    if (!name || !secret) { if(name) CFRelease(name); if(secret) CFRelease(secret); return NULL; }
    int peap = 25;
    CFNumberRef type = CFNumberCreate(NULL, kCFNumberIntType, &peap);
    const void *types[] = {type};
    CFArrayRef accepted = CFArrayCreate(NULL, types, 1, &kCFTypeArrayCallBacks);
    CFMutableDictionaryRef eap = dictionary(), config = dictionary();
    CFDictionarySetValue(eap, CFSTR("UserName"), name);
    CFDictionarySetValue(eap, CFSTR("UserPassword"), secret);
    CFDictionarySetValue(eap, CFSTR("AcceptEAPTypes"), accepted);
    /* Use Apple's automatic PEAP inner negotiation (MSCHAPv2, MD5, GTC).
     * Certificate trust is evaluated by macOS; never accept an arbitrary root.
     * The app, rather than the system supplicant, controls password storage. */
    CFDictionarySetValue(eap, CFSTR("SaveCredentialsOnSuccessfulAuthentication"), kCFBooleanFalse);
    CFDictionarySetValue(config, CFSTR("EAPClientConfiguration"), eap);
    CFDictionarySetValue(config, CFSTR("UniqueIdentifier"), identifier);
    CFDictionarySetValue(config, CFSTR("EnableUserInterface"), kCFBooleanTrue);
    CFRelease(name); CFRelease(secret); CFRelease(type); CFRelease(accepted); CFRelease(eap);
    return config;
}
int apple_eap_number(CFDictionaryRef status, CFStringRef key) {
    if (!status || CFGetTypeID(status) != CFDictionaryGetTypeID()) return -1;
    CFTypeRef value = CFDictionaryGetValue(status, key); int n = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &n);
    return n;
}
int apple_eap_owned(CFDictionaryRef status, CFStringRef identifier, uid_t uid) {
    if (!status || CFGetTypeID(status) != CFDictionaryGetTypeID()) return 0;
    CFTypeRef id = CFDictionaryGetValue(status, CFSTR("UniqueIdentifier"));
    return id && CFGetTypeID(id) == CFStringGetTypeID() && CFEqual(id, identifier) &&
           apple_eap_number(status, CFSTR("Mode")) == 1 &&
           apple_eap_number(status, CFSTR("UID")) == (int)uid;
}
/* A running process is not authentication success. Supplicant state 4 is;
 * state 5 means the authentication was rejected. Cert prompts can be pending. */
int apple_eap_classify(CFDictionaryRef status) {
    int state = apple_eap_number(status, CFSTR("SupplicantState"));
    int result = apple_eap_number(status, CFSTR("ClientStatus"));
    if (state == 4 && result == 0) return 1;
    if (state == 5 || state == 6 || result == 9) return -1;
    return 0;
}
typedef int (*StartFn)(const char *, CFDictionaryRef);
typedef int (*StatusFn)(const char *, int *, CFDictionaryRef *);
typedef int (*StopFn)(const char *);
static const char *failure(int status) {
    switch (status) {
    case 5: return "交换机未接受 PEAP；当前网口的认证方式需要进一步核对";
    case 7: return "服务器要求的 PEAP 内层认证方式不受 macOS 支持";
    case 6: case 10: case 11: case 12: case 13: case 14:
        return "PEAP 服务器证书未获信任，请查看 macOS 的证书提示";
    case 9: return "已取消 macOS 认证或证书确认";
    default: return "PEAP 认证未通过；服务器未提供可确定的失败原因";
    }
}
int apple_eap_run(const char *device, const char *user, const char *password,
                  pid_t parent, const char *stop_path, volatile sig_atomic_t *stop,
                  void (*event)(const char *, const char *)) {
    event("starting", "高级认证后端 0.4.1：使用 macOS 有线 PEAP，内层类型自动协商");
    void *framework = dlopen("/System/Library/PrivateFrameworks/EAP8021X.framework/EAP8021X", RTLD_NOW | RTLD_LOCAL);
    StartFn start = framework ? (StartFn)dlsym(framework, "EAPOLControlStart") : NULL;
    StatusFn copy = framework ? (StatusFn)dlsym(framework, "EAPOLControlCopyStateAndStatus") : NULL;
    StopFn finish = framework ? (StopFn)dlsym(framework, "EAPOLControlStop") : NULL;
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    CFStringRef id = CFUUIDCreateString(NULL, uuid); CFRelease(uuid);
    CFDictionaryRef config = NULL, status = NULL;
    int failed = 1, started = 0, online = 0, state = 0, last_state = -2, last_client = -2, last_supp = -2, last_type = -2;
    if (!start || !copy || !finish) { event("error", "此 macOS 无法加载有线 PEAP 控制接口"); goto done; }
    if (*stop || access(stop_path, F_OK) == 0 || (kill(parent, 0) < 0 && errno == ESRCH)) { failed = 0; goto done; }
    int result = copy(device, &state, &status);
    if (result != 0 && result != ENOENT) { event("error", "无法查询 macOS 有线认证状态"); goto done; }
    if (state != 0) { event("error", "此网卡已有系统 802.1X 会话，请先在系统网络设置中断开后再连接"); goto done; }
    if (status) { CFRelease(status); status = NULL; }
    config = apple_eap_configuration(user, password, id);
    if (!config) { event("error", "无法创建 PEAP 会话参数"); goto done; }
    result = start(device, config);
    CFRelease(config); config = NULL;
    if (result != 0) {
        char message[200];
        snprintf(message, sizeof(message), "macOS 未接受 PEAP 启动请求（系统代码 %d）%s", result,
                 result == EBUSY || result == EEXIST ? "；此网卡已有认证会话" : "");
        event("error", message); goto done;
    }
    started = 1;
    event("notice", "macOS 已接收 PEAP 请求；开始认证，尚未确认成功");
    event("phase", "正在等待校园网认证结果…");
    event("notice", "证书由 macOS 验证；如出现提示，请先核对服务器证书");
    time_t began = time(NULL);
    while (!*stop && access(stop_path, F_OK) != 0) {
        if (kill(parent, 0) < 0 && errno == ESRCH) break;
        state = 0;
        result = copy(device, &state, &status);
        if (result != 0) { event("error", "macOS 认证状态查询中断"); goto done; }
        if (status) {
            if (!apple_eap_owned(status, id, getuid())) {
                CFTypeRef other_id = CFDictionaryGetValue(status, CFSTR("UniqueIdentifier"));
                if ((other_id || state == 2) && state != 1) { event("error", "有线认证会话已由其他程序接管"); goto done; }
            } else {
                int supp = apple_eap_number(status, CFSTR("SupplicantState"));
                int client = apple_eap_number(status, CFSTR("ClientStatus"));
                int type = apple_eap_number(status, CFSTR("EAPType"));
                if (state != last_state || supp != last_supp || client != last_client || type != last_type) {
                    char message[180];
                    snprintf(message, sizeof(message), "macOS 认证状态：会话 %d，阶段 %d，结果 %d，EAP 方法 %d", state, supp, client, type);
                    event("notice", message); last_state = state; last_supp = supp; last_client = client; last_type = type;
                    if (client == 14 || client == 3 || client == 20) {
                        event("notice", "macOS 正在等待认证信息或服务器证书确认");
                        event("phase", "请检查 macOS 的认证信息或证书确认提示…");
                    }
                }
                int phase = apple_eap_classify(status);
                if (phase == 1 && !online) { online = 1; event("authenticated", "macOS 报告 PEAP 认证已通过，正在获取有线地址"); }
                else if (phase < 0) { event("error", failure(client)); goto done; }
                else if (online && (supp == 0 || supp == 7 || supp == 8)) { event("error", "PEAP 认证已断开"); goto done; }
            }
            CFRelease(status); status = NULL;
        }
        if (state == 0 || state == 3) { event("error", "macOS 有线认证会话已结束"); goto done; }
        if (!online && time(NULL) - began > 120) { event("error", "PEAP 认证等待超时；尚未确认成功"); goto done; }
        usleep(300000);
    }
    failed = 0;
done:
    if (config) CFRelease(config);
    if (status) { CFRelease(status); status = NULL; }
    if (started) {
        /* Never stop another application's session, nor the Wi-Fi interface. */
        int resolved = 0;
        for (int attempt = 0; attempt < 30; attempt++) {
            state = 0;
            int r = copy(device, &state, &status);
            int owned = r == 0 && apple_eap_owned(status, id, getuid());
            CFTypeRef other = status ? CFDictionaryGetValue(status, CFSTR("UniqueIdentifier")) : NULL;
            int different = other && !CFEqual(other, id);
            if (status) { CFRelease(status); status = NULL; }
            if (owned) {
                if (finish(device) == 0) resolved = 1;
                break;
            }
            if (r == ENOENT || (r == 0 && (state == 0 || (different && state != 1)))) { resolved = 1; break; }
            usleep(100000);
        }
        if (!resolved) { failed = 1; event("error", "未能确认 PEAP 会话已停止，请在系统网络设置中断开该有线网卡的 802.1X"); }
    }
    CFRelease(id);
    if (framework) dlclose(framework);
    event("stopped", failed ? "PEAP 认证会话已结束" : "已断开有线 PEAP 认证");
    return failed;
}
