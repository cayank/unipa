#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import "device/info.h"

static id classMessage(NSString *className, NSString *selector) {
    Class target = NSClassFromString(className);
    SEL message = NSSelectorFromString(selector);
    return [target respondsToSelector:message] ? ((id (*)(id, SEL))objc_msgSend)(target, message) : nil;
}

static NSString *hardwareModel(void) {
    char model[64] = {0};
    size_t size = sizeof(model) - 1;
    return sysctlbyname("hw.model", model, &size, NULL, 0) == 0 ? [NSString stringWithUTF8String:model] : @"unknown";
}

static NSString *advertisingIdentifier(void) {
    id manager = classMessage(@"ASIdentifierManager", @"sharedManager");
    if (!manager) return @"not used by the app";
    NSString *identifier = [[manager valueForKey:@"advertisingIdentifier"] UUIDString];
    Class tracking = NSClassFromString(@"ATTrackingManager");
    SEL status = NSSelectorFromString(@"trackingAuthorizationStatus");
    if (![tracking respondsToSelector:status]) return identifier;
    NSArray *statuses = @[@"not determined", @"restricted", @"denied", @"authorized"];
    NSUInteger index = ((NSUInteger (*)(id, SEL))objc_msgSend)(tracking, status);
    return index < statuses.count ? [NSString stringWithFormat:@"%@ (tracking %@)", identifier, statuses[index]] : identifier;
}

static NSString *readableValue(NSData *data) {
    if (![data isKindOfClass:NSData.class]) return @"—";
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)data.length];
    }
    return text;
}

typedef OSStatus (*UnipaCopyMatching)(CFDictionaryRef, CFTypeRef *);

static OSStatus copyItems(id itemClass, NSArray **items) {
    UnipaCopyMatching isolated = (UnipaCopyMatching)dlsym(RTLD_SELF, "unipaKeychainCopyMatching");
    NSDictionary *query = @{
        (__bridge id)kSecClass: itemClass,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecUseDataProtectionKeychain: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = (isolated ?: SecItemCopyMatching)((__bridge CFDictionaryRef)query, &result);
    *items = CFBridgingRelease(result);
    return status;
}

static NSArray<NSString *> *keychainLines(void) {
    NSMutableArray *lines = [NSMutableArray array];
    for (id itemClass in @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword]) {
        NSArray *items = nil;
        OSStatus status = copyItems(itemClass, &items);
        if (status == errSecItemNotFound) continue;
        if (status == errSecMissingEntitlement) return @[@"  unavailable: the app has no Keychain entitlement"];
        if (status != errSecSuccess) return @[[NSString stringWithFormat:@"  unavailable (OSStatus %d)", (int)status]];
        for (NSDictionary *item in items) {
            NSString *name = item[(__bridge id)kSecAttrService] ?: item[(__bridge id)kSecAttrServer] ?: @"";
            NSString *account = item[(__bridge id)kSecAttrAccount] ?: @"";
            [lines addObject:[NSString stringWithFormat:@"  %@ / %@\n  └── %@", name, account, readableValue(item[(__bridge id)kSecValueData])]];
        }
    }
    return lines.count ? lines : @[@"  no items"];
}

static NSString *alignedFields(NSArray<NSArray<NSString *> *> *fields) {
    NSUInteger width = 0;
    for (NSArray<NSString *> *field in fields) width = MAX(width, field[0].length);
    NSMutableArray *lines = [NSMutableArray array];
    for (NSArray<NSString *> *field in fields) {
        NSString *padding = [@"" stringByPaddingToLength:width - field[0].length withString:@" " startingAtIndex:0];
        [lines addObject:[NSString stringWithFormat:@"%@%@: %@", padding, field[0], field[1]]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

NSString *unipaDeviceReport(void) {
    id device = classMessage(@"UIDevice", @"currentDevice");
    NSString *header = alignedFields(@[
        @[@"Vendor ID (IDFV)", [[device valueForKey:@"identifierForVendor"] UUIDString] ?: @"unavailable"],
        @[@"Advertising ID (IDFA)", advertisingIdentifier()],
        @[@"Device", [NSString stringWithFormat:@"%@, %@ %@", [device valueForKey:@"model"] ?: @"unknown",
            [device valueForKey:@"systemName"] ?: @"", [device valueForKey:@"systemVersion"] ?: @""]],
        @[@"Mac", hardwareModel()],
    ]);
    NSArray *lines = @[
        header,
        @"",
        @"Keychain items (service / account, value):",
        [keychainLines() componentsJoinedByString:@"\n\n"],
    ];
    return [lines componentsJoinedByString:@"\n"];
}
