#ifndef INODE_APPLE_EAP_H
#define INODE_APPLE_EAP_H
#include <CoreFoundation/CoreFoundation.h>
#include <signal.h>
#include <sys/types.h>

/* Apple's EAPOLControl ABI and dictionary keys are documented in its
 * apple-oss-distributions/eap8021x source. No Apple implementation is copied. */
CFDictionaryRef apple_eap_configuration(const char *user, const char *password, CFStringRef identifier);
int apple_eap_number(CFDictionaryRef status, CFStringRef key);
int apple_eap_owned(CFDictionaryRef status, CFStringRef identifier, uid_t uid);
int apple_eap_classify(CFDictionaryRef status);
int apple_eap_run(const char *device, const char *user, const char *password,
                  pid_t parent, const char *stop_path, volatile sig_atomic_t *stop,
                  void (*event)(const char *, const char *));
#endif
