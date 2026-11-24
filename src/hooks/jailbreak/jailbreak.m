#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <errno.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <mach-o/dyld.h>
#import "layout/layout.h"

static char appBundleName[256];

static BOOL looksLikeJailbreak(const char *path) {
    if (!path) return NO;
    static const char *const needles[] = {
        "/bin/bash", "/bin/sh", "/bin/su", "/bin/zsh", "/etc/apt", "/private/etc/apt",
        "cydia", "Cydia", "substrate", "Substrate", "frida", "/jb/", "/jb ", "jailbreak",
        "sileo", "Sileo", "electra", "undecimus", "dpkg", "/usr/sbin/sshd", "/usr/bin/ssh",
        "/usr/libexec/ssh-keysign", "/usr/libexec/sftp-server", "ssh/sshd_config", "/var/lib/apt",
        "/var/lib/cydia", "/var/cache/apt", "/var/stash", "/.cydia_no_stash", "libjailbreak",
        "MobileSubstrate", "TweakInject", "/var/jb", "/private/var/jb",
        "checkra1n.app", "blackra1n.app", "FakeCarrier.app", "Icy.app", "IntelliScreen.app",
        "MxTube.app", "RockApp.app", "SBSettings.app", "WinterBoard.app", "Palera1n.app",
        "Zebra.app", "TrollStore.app", NULL,
    };
    for (int i = 0; needles[i]; i++) {
        if (strstr(path, needles[i])) return YES;
    }
    return NO;
}

static BOOL hiddenScheme(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"cydia"] || [scheme isEqualToString:@"sileo"] ||
           [scheme isEqualToString:@"zbra"] || [scheme isEqualToString:@"filza"] ||
           [scheme isEqualToString:@"undecimus"] || [scheme isEqualToString:@"activator"];
}

#define IP(repl, orig) __attribute__((used, section("__DATA,__interpose"))) static struct { const void *r; const void *o; } _i_##orig = {(const void *)repl, (const void *)orig};

static int my_stat(const char *p, struct stat *s) { if (looksLikeJailbreak(p)) { errno = ENOENT; return -1; } return stat(p, s); }
IP(my_stat, stat)
static int my_lstat(const char *p, struct stat *s) { if (looksLikeJailbreak(p)) { errno = ENOENT; return -1; } return lstat(p, s); }
IP(my_lstat, lstat)
static int my_access(const char *p, int m) { if (looksLikeJailbreak(p)) { errno = ENOENT; return -1; } return access(p, m); }
IP(my_access, access)
static FILE *my_fopen(const char *p, const char *m) { if (looksLikeJailbreak(p)) { errno = ENOENT; return NULL; } return fopen(p, m); }
IP(my_fopen, fopen)
static int my_open(const char *p, int flags, ...) {
    if (looksLikeJailbreak(p)) { errno = ENOENT; return -1; }
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list a; va_start(a, flags); mode = (mode_t)va_arg(a, int); va_end(a); }
    return open(p, flags, mode);
}
IP(my_open, open)
static int my_statfs(const char *p, struct statfs *b) {
    int r = statfs(p, b);
    if (r == 0 && p && appBundleName[0] && strstr(p, appBundleName)) b->f_flags |= MNT_RDONLY;
    return r;
}
IP(my_statfs, statfs)
static const char *my_dyld_get_image_name(uint32_t index) {
    const char *name = _dyld_get_image_name(index);
    if (name && looksLikeJailbreak(name)) return "/usr/lib/libSystem.B.dylib";
    return name;
}
IP(my_dyld_get_image_name, _dyld_get_image_name)

static BOOL (*originalFileExists)(id, SEL, NSString *);
static BOOL fileExists(id self, SEL _cmd, NSString *path) {
    if (looksLikeJailbreak(path.fileSystemRepresentation)) return NO;
    return originalFileExists(self, _cmd, path);
}
static BOOL (*originalFileExistsIsDir)(id, SEL, NSString *, BOOL *);
static BOOL fileExistsIsDir(id self, SEL _cmd, NSString *path, BOOL *isDir) {
    if (looksLikeJailbreak(path.fileSystemRepresentation)) { if (isDir) *isDir = NO; return NO; }
    return originalFileExistsIsDir(self, _cmd, path, isDir);
}
static BOOL (*originalCanOpenURL)(id, SEL, NSURL *);
static BOOL canOpenURL(id self, SEL _cmd, NSURL *url) {
    if (hiddenScheme(url)) return NO;
    return originalCanOpenURL(self, _cmd, url);
}

static void swizzle(Class cls, SEL selector, IMP replacement, void *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method) *(IMP *)original = method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void installJailbreakBypass(void) {
    @autoreleasepool {
        if (unipaPreferredWindowSize().width <= 0) return;
        const char *name = NSBundle.mainBundle.bundlePath.lastPathComponent.fileSystemRepresentation;
        if (name) strlcpy(appBundleName, name, sizeof appBundleName);
        swizzle(NSFileManager.class, @selector(fileExistsAtPath:), (IMP)fileExists, &originalFileExists);
        swizzle(NSFileManager.class, @selector(fileExistsAtPath:isDirectory:), (IMP)fileExistsIsDir, &originalFileExistsIsDir);
        Class application = NSClassFromString(@"UIApplication");
        swizzle(application, NSSelectorFromString(@"canOpenURL:"), (IMP)canOpenURL, &originalCanOpenURL);
    }
}
