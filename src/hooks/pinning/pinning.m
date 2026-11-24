#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import "layout/layout.h"

#define IP(repl, orig) __attribute__((used, section("__DATA,__interpose"))) static struct { const void *r; const void *o; } _i_##orig = {(const void *)repl, (const void *)orig};

static OSStatus my_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
    if (result) *result = kSecTrustResultUnspecified;
    return errSecSuccess;
}
IP(my_SecTrustEvaluate, SecTrustEvaluate)

static Boolean my_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef *error) {
    if (error) *error = NULL;
    return true;
}
IP(my_SecTrustEvaluateWithError, SecTrustEvaluateWithError)

typedef void (^UnipaChallengeCompletion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *);

static void trustChallenge(NSURLAuthenticationChallenge *challenge, UnipaChallengeCompletion completion) {
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (trust && completion) {
        completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
        return;
    }
    if (completion) completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

static void sessionChallenge(id self, SEL _cmd, NSURLSession *session, NSURLAuthenticationChallenge *challenge, UnipaChallengeCompletion completion) {
    trustChallenge(challenge, completion);
}

static void taskChallenge(id self, SEL _cmd, NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, UnipaChallengeCompletion completion) {
    trustChallenge(challenge, completion);
}

static void connectionChallenge(id self, SEL _cmd, NSURLConnection *connection, NSURLAuthenticationChallenge *challenge) {
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (trust) {
        [challenge.sender useCredential:[NSURLCredential credentialForTrust:trust] forAuthenticationChallenge:challenge];
        return;
    }
    [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
}

static void connectionWillSendRequest(id self, SEL _cmd, NSURLConnection *connection, NSURLAuthenticationChallenge *challenge) {
    connectionChallenge(self, _cmd, connection, challenge);
}

static BOOL trustAlways(id self, SEL _cmd, ...) {
    return YES;
}

static void patchClassesImplementing(SEL selector, IMP replacement) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    for (unsigned int i = 0; i < count; i++) {
        Method method = class_getInstanceMethod(classes[i], selector);
        if (method) class_replaceMethod(classes[i], selector, replacement, method_getTypeEncoding(method));
    }
    free(classes);
}

static void swizzleSelector(Class cls, SEL selector, IMP replacement) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (method) method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void installPinningBypass(void) {
    if (unipaPreferredWindowSize().width <= 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            patchClassesImplementing(NSSelectorFromString(@"URLSession:didReceiveChallenge:completionHandler:"), (IMP)sessionChallenge);
            patchClassesImplementing(NSSelectorFromString(@"URLSession:task:didReceiveChallenge:completionHandler:"), (IMP)taskChallenge);
            patchClassesImplementing(NSSelectorFromString(@"connection:didReceiveAuthenticationChallenge:"), (IMP)connectionChallenge);
            patchClassesImplementing(NSSelectorFromString(@"connection:willSendRequestForAuthenticationChallenge:"), (IMP)connectionWillSendRequest);

            swizzleSelector(NSClassFromString(@"AFSecurityPolicy"), NSSelectorFromString(@"evaluateServerTrust:forDomain:"), (IMP)trustAlways);
            swizzleSelector(NSClassFromString(@"TSKPinningValidator"), NSSelectorFromString(@"evaluateTrust:forHostname:"), (IMP)trustAlways);
            swizzleSelector(NSClassFromString(@"TSKSPKIHashCache"), NSSelectorFromString(@"evaluateTrust:forHostname:"), (IMP)trustAlways);
        }
    });
}
