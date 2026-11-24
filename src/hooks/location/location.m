#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "layout/layout.h"
#import "location/location.h"
#import "settings/settings.h"

@interface NSObject (UnipaLocation)
- (instancetype)initWithLatitude:(double)latitude longitude:(double)longitude;
@end

static NSString *const locationKey = @"UnipaLocation";
static const int authorizedWhenInUse = 4;
static NSMutableDictionary<NSString *, NSValue *> *originals;
static NSHashTable *updatingManagers;

static BOOL validCoordinate(double latitude, double longitude) {
    return isfinite(latitude) && isfinite(longitude) && fabs(latitude) <= 90 && fabs(longitude) <= 180;
}

BOOL unipaLocationAvailable(void) {
    return originals.count > 0;
}

BOOL unipaSimulatedCoordinate(UnipaCoordinate *coordinate) {
    id saved = unipaSettingValue(locationKey);
    if (![saved isKindOfClass:NSDictionary.class]) return NO;
    id latitude = saved[@"latitude"], longitude = saved[@"longitude"];
    if (![latitude isKindOfClass:NSNumber.class] || ![longitude isKindOfClass:NSNumber.class]) return NO;
    if (!validCoordinate([latitude doubleValue], [longitude doubleValue])) return NO;
    if (coordinate) *coordinate = (UnipaCoordinate){[latitude doubleValue], [longitude doubleValue]};
    return YES;
}

BOOL unipaParseCoordinate(NSString *text, UnipaCoordinate *coordinate) {
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@", \t\n"];
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByCharactersInSet:separators]) {
        if (!part.length) continue;
        NSScanner *scanner = [NSScanner scannerWithString:part];
        double value;
        if (![scanner scanDouble:&value] || !scanner.atEnd) return NO;
        [values addObject:@(value)];
    }
    if (values.count != 2 || !validCoordinate(values[0].doubleValue, values[1].doubleValue)) return NO;
    if (coordinate) *coordinate = (UnipaCoordinate){values[0].doubleValue, values[1].doubleValue};
    return YES;
}

static IMP original(BOOL classMethod, SEL selector) {
    NSString *key = [(classMethod ? @"+" : @"-") stringByAppendingString:NSStringFromSelector(selector)];
    return originals[key].pointerValue;
}

static id simulatedLocation(void) {
    UnipaCoordinate coordinate;
    if (!unipaSimulatedCoordinate(&coordinate)) return nil;
    return [[NSClassFromString(@"CLLocation") alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
}

static void deliverLocation(id manager) {
    id location = simulatedLocation();
    id delegate = [manager valueForKey:@"delegate"];
    SEL update = NSSelectorFromString(@"locationManager:didUpdateLocations:");
    if (!location || ![delegate respondsToSelector:update]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, NSArray *))objc_msgSend)(delegate, update, manager, @[location]);
    });
}

static void notifyAuthorization(id manager) {
    id delegate = [manager valueForKey:@"delegate"];
    SEL changed = NSSelectorFromString(@"locationManagerDidChangeAuthorization:");
    SEL legacy = NSSelectorFromString(@"locationManager:didChangeAuthorizationStatus:");
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([delegate respondsToSelector:changed]) {
            ((void (*)(id, SEL, id))objc_msgSend)(delegate, changed, manager);
        } else if ([delegate respondsToSelector:legacy]) {
            ((void (*)(id, SEL, id, int))objc_msgSend)(delegate, legacy, manager, authorizedWhenInUse);
        }
    });
}

static id currentLocation(id manager, SEL selector) {
    return simulatedLocation() ?: ((id (*)(id, SEL))original(NO, selector))(manager, selector);
}

static void startUpdates(id manager, SEL selector) {
    [updatingManagers addObject:manager];
    if (unipaSimulatedCoordinate(NULL)) deliverLocation(manager);
    else ((void (*)(id, SEL))original(NO, selector))(manager, selector);
}

static void stopUpdates(id manager, SEL selector) {
    [updatingManagers removeObject:manager];
    ((void (*)(id, SEL))original(NO, selector))(manager, selector);
}

static void requestLocation(id manager, SEL selector) {
    if (unipaSimulatedCoordinate(NULL)) deliverLocation(manager);
    else ((void (*)(id, SEL))original(NO, selector))(manager, selector);
}

static void requestAuthorization(id manager, SEL selector) {
    if (unipaSimulatedCoordinate(NULL)) notifyAuthorization(manager);
    else ((void (*)(id, SEL))original(NO, selector))(manager, selector);
}

static int managerAuthorization(id manager, SEL selector) {
    return unipaSimulatedCoordinate(NULL) ? authorizedWhenInUse : ((int (*)(id, SEL))original(NO, selector))(manager, selector);
}

static int classAuthorization(id managerClass, SEL selector) {
    return unipaSimulatedCoordinate(NULL) ? authorizedWhenInUse : ((int (*)(id, SEL))original(YES, selector))(managerClass, selector);
}

static BOOL servicesEnabled(id managerClass, SEL selector) {
    return unipaSimulatedCoordinate(NULL) || ((BOOL (*)(id, SEL))original(YES, selector))(managerClass, selector);
}

static void refreshManagers(void) {
    BOOL simulated = unipaSimulatedCoordinate(NULL);
    SEL start = NSSelectorFromString(@"startUpdatingLocation");
    for (id manager in updatingManagers.allObjects) {
        if (simulated) deliverLocation(manager);
        else ((void (*)(id, SEL))original(NO, start))(manager, start);
    }
}

void unipaSimulateLocation(UnipaCoordinate coordinate) {
    if (!validCoordinate(coordinate.latitude, coordinate.longitude)) return;
    unipaSetSettingValue(locationKey, @{@"latitude": @(coordinate.latitude), @"longitude": @(coordinate.longitude)});
    refreshManagers();
}

void unipaUseRealLocation(void) {
    unipaRemoveSetting(locationKey);
    refreshManagers();
}

static void hook(Class target, BOOL classMethod, NSString *name, IMP replacement) {
    Method method = classMethod ? class_getClassMethod(target, NSSelectorFromString(name)) : class_getInstanceMethod(target, NSSelectorFromString(name));
    if (!method) return;
    NSString *key = [(classMethod ? @"+" : @"-") stringByAppendingString:name];
    originals[key] = [NSValue valueWithPointer:method_setImplementation(method, replacement)];
}

__attribute__((constructor)) static void installLocationSimulation(void) {
    @autoreleasepool {
        Class manager = NSClassFromString(@"CLLocationManager");
        if (unipaPreferredWindowSize().width <= 0 || !manager || !NSClassFromString(@"CLLocation")) return;
        originals = [NSMutableDictionary dictionary];
        updatingManagers = NSHashTable.weakObjectsHashTable;
        hook(manager, NO, @"location", (IMP)currentLocation);
        hook(manager, NO, @"startUpdatingLocation", (IMP)startUpdates);
        hook(manager, NO, @"startMonitoringSignificantLocationChanges", (IMP)startUpdates);
        hook(manager, NO, @"stopUpdatingLocation", (IMP)stopUpdates);
        hook(manager, NO, @"stopMonitoringSignificantLocationChanges", (IMP)stopUpdates);
        hook(manager, NO, @"requestLocation", (IMP)requestLocation);
        hook(manager, NO, @"requestWhenInUseAuthorization", (IMP)requestAuthorization);
        hook(manager, NO, @"requestAlwaysAuthorization", (IMP)requestAuthorization);
        hook(manager, NO, @"authorizationStatus", (IMP)managerAuthorization);
        hook(manager, YES, @"authorizationStatus", (IMP)classAuthorization);
        hook(manager, YES, @"locationServicesEnabled", (IMP)servicesEnabled);
    }
}
