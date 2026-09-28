#include "../Sources/AppleEAP.h"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

static void number(CFMutableDictionaryRef d, CFStringRef key, int v) {
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, key, value); CFRelease(value);
}
int main(void) {
    CFStringRef id = CFSTR("synthetic-session");
    CFDictionaryRef config = apple_eap_configuration("synthetic-user@cm", "synthetic-password", id);
    assert(config);
    CFDictionaryRef eap = CFDictionaryGetValue(config, CFSTR("EAPClientConfiguration"));
    CFArrayRef types = CFDictionaryGetValue(eap, CFSTR("AcceptEAPTypes"));
    int type = 0; assert(CFArrayGetCount(types) == 1);
    assert(CFNumberGetValue(CFArrayGetValueAtIndex(types, 0), kCFNumberIntType, &type) && type == 25);
    assert(CFEqual(CFDictionaryGetValue(eap, CFSTR("UserName")), CFSTR("synthetic-user@cm")));
    assert(CFEqual(CFDictionaryGetValue(eap, CFSTR("UserPassword")), CFSTR("synthetic-password")));
    assert(CFDictionaryGetValue(eap, CFSTR("SaveCredentialsOnSuccessfulAuthentication")) == kCFBooleanFalse);
    assert(!CFDictionaryContainsKey(eap, CFSTR("TLSAllowAnyRoot")));
    assert(!CFDictionaryContainsKey(eap, CFSTR("TLSAllowTrustExceptions")));
    assert(!CFDictionaryContainsKey(eap, CFSTR("InnerAcceptEAPTypes")));
    assert(CFDictionaryGetValue(config, CFSTR("EnableUserInterface")) == kCFBooleanTrue);
    CFRelease(config);
    assert(!apple_eap_configuration("", "p", id));
    assert(!apple_eap_configuration("u", "", id));
    assert(!apple_eap_configuration("u", "p", NULL));
    CFMutableDictionaryRef status = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    number(status, CFSTR("SupplicantState"), 3); number(status, CFSTR("ClientStatus"), 14);
    assert(apple_eap_classify(status) == 0); /* Cert confirmation is pending, not success or failure. */
    number(status, CFSTR("SupplicantState"), 4);
    assert(apple_eap_classify(status) == 0);
    number(status, CFSTR("ClientStatus"), 0);
    assert(apple_eap_classify(status) == 1);
    number(status, CFSTR("SupplicantState"), 5);
    assert(apple_eap_classify(status) == -1);
    assert(!apple_eap_owned(status, id, getuid()));
    CFDictionarySetValue(status, CFSTR("UniqueIdentifier"), id);
    number(status, CFSTR("Mode"), 1); number(status, CFSTR("UID"), (int)getuid());
    assert(apple_eap_owned(status, id, getuid()));
    assert(!apple_eap_owned(status, CFSTR("another-app-session"), getuid()));
    assert(!apple_eap_owned(status, id, getuid() + 1));
    number(status, CFSTR("Mode"), 3);
    assert(!apple_eap_owned(status, id, getuid())); /* Leave system/MDM sessions alone. */
    CFDictionarySetValue(status, CFSTR("ClientStatus"), kCFBooleanFalse);
    assert(apple_eap_number(status, CFSTR("ClientStatus")) == -1);
    assert(apple_eap_number(NULL, CFSTR("ClientStatus")) == -1);
    assert(apple_eap_classify(NULL) == 0);
    CFRelease(status);
    puts("PEAP configuration, certificate trust, actual auth result, and session ownership tests passed");
}
