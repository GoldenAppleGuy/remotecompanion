// On-device test kit, phase 1 - see RCTestKit.h.
//
// Everything is plain JSON over /api/testkit/ (and "testkit ..." on the UNIX socket), with
// results returned synchronously, so a test runner or an agent can drive the device and
// check outcomes without scraping the text log:
//
//   GET  /api/testkit/info              what this build supports
//   GET  /api/testkit/probe             snapshot of the device state that tests check
//   GET  /api/testkit/journal?since=N   events after seq N (&type=prefix, &limit=)
//   POST /api/testkit/journal/clear
//   POST /api/testkit/mark?label=...    a labelled marker, e.g. the start of a test step
//   POST /api/testkit/run               body (or ?cmd=): a command; returns its output
//   POST /api/testkit/capture?on=1|0    dry-run: triggers are recorded, actions don't run
//   POST /api/testkit/snapshot          save device state and config
//   POST /api/testkit/restore           put them back

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>
#import <unistd.h>
#import <sys/utsname.h>
#import "RCTestKit.h"

extern void SRLog(NSString *format, ...);

static const NSUInteger kRCTKJournalCapacity = 4000;
static NSString *const kRCTKSnapshotPath = @"/var/mobile/Documents/rc_testkit_snapshot.plist";

static NSMutableArray<NSDictionary *> *g_tkEvents;
static unsigned long long g_tkNextSeq = 1;
static BOOL g_tkCapture = NO;
// Changes on every respring, so a client following the journal sees it restart from seq 1
static NSString *g_tkSession;

static NSObject *RCTKLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        g_tkEvents = [NSMutableArray arrayWithCapacity:kRCTKJournalCapacity];
    });
    return lock;
}

static double RCTKNowMs(void) {
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
}

#pragma mark - Journal

// Returns the event's sequence number
static unsigned long long RCTKRecord(NSString *type, NSDictionary *info) {
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithCapacity:info.count + 3];
    if (info) [event addEntriesFromDictionary:info];
    event[@"t"] = @(RCTKNowMs());
    event[@"type"] = type;
    unsigned long long seq;
    @synchronized (RCTKLock()) {
        seq = g_tkNextSeq++;
        event[@"seq"] = @(seq);
        [g_tkEvents addObject:event];
        if (g_tkEvents.count > kRCTKJournalCapacity) {
            [g_tkEvents removeObjectsInRange:NSMakeRange(0, g_tkEvents.count - kRCTKJournalCapacity)];
        }
    }
    return seq;
}

void RCTKEvent(NSString *type, NSDictionary *info) {
    if (type) RCTKRecord(type, info);
}

static NSDictionary *RCTKJournal(unsigned long long since, NSString *typePrefix, NSUInteger limit) {
    NSMutableArray *events = [NSMutableArray array];
    unsigned long long next, oldest;
    @synchronized (RCTKLock()) {
        for (NSDictionary *event in g_tkEvents) {
            if ([event[@"seq"] unsignedLongLongValue] <= since) continue;
            if (typePrefix.length && ![event[@"type"] hasPrefix:typePrefix]) continue;
            [events addObject:event];
            if (limit && events.count >= limit) break;
        }
        next = events.count ? [[events.lastObject objectForKey:@"seq"] unsignedLongLongValue] : MAX(since, g_tkNextSeq - 1);
        oldest = g_tkEvents.count ? [g_tkEvents.firstObject[@"seq"] unsignedLongLongValue] : g_tkNextSeq;
    }
    return @{ @"events": events, @"next": @(next), @"oldest": @(oldest), @"session": g_tkSession ?: @"" };
}

#pragma mark - Capture (dry-run)

BOOL RCTKCaptureTrigger(NSString *triggerKey) {
    if (!g_tkCapture) return NO;
    RCTKEvent(@"trigger.captured", @{ @"key": triggerKey ?: @"" });
    return YES;
}

#pragma mark - Probe

static id RCTKSend(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

// For BOOL / integer getters: nil when the selector isn't there
static NSNumber *RCTKSendLong(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return @(((long (*)(id, SEL))objc_msgSend)(target, sel));
}

static NSNumber *RCTKSendBool(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return @(((BOOL (*)(id, SEL))objc_msgSend)(target, sel));
}

static id RCTKShared(NSString *className, NSString *accessor) {
    return RCTKSend(NSClassFromString(className), accessor);
}

static NSString *RCTKStatus(NSString *command) {
    NSString *output = RCHandleCommand(command);
    return [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static NSString *RCTKPackageVersion(void) {
    static NSString *version;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *path in @[@"/var/jb/var/lib/dpkg/status", @"/var/lib/dpkg/status"]) {
            NSString *status = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            NSRange pkg = [status rangeOfString:@"Package: com.saihgupr.remotecompanion\n"];
            if (pkg.location == NSNotFound) continue;
            NSString *rest = [status substringFromIndex:pkg.location];
            NSRange end = [rest rangeOfString:@"\n\n"];
            if (end.location != NSNotFound) rest = [rest substringToIndex:end.location];
            for (NSString *line in [rest componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@"Version: "]) version = [line substringFromIndex:9];
            }
            break;
        }
    });
    return version ?: @"unknown";
}

static NSDictionary *RCTKLatestPhoto(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dcim = @"/var/mobile/Media/DCIM";
    NSString *latest = nil;
    NSDate *latestDate = nil;
    NSSet *media = [NSSet setWithArray:@[@"heic", @"jpg", @"jpeg", @"png", @"gif", @"mov", @"mp4"]];
    for (NSString *folder in [fm contentsOfDirectoryAtPath:dcim error:nil]) {
        NSString *dir = [dcim stringByAppendingPathComponent:folder];
        for (NSString *file in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![media containsObject:file.pathExtension.lowercaseString]) continue;
            NSDate *date = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:file] error:nil][NSFileModificationDate];
            if (date && (!latestDate || [date compare:latestDate] == NSOrderedDescending)) {
                latestDate = date;
                latest = file;
            }
        }
    }
    if (!latest) return @{};
    return @{ @"file": latest, @"t": @([latestDate timeIntervalSince1970] * 1000.0) };
}

static NSDictionary *RCTKProbe(void) {
    NSMutableDictionary *probe = [NSMutableDictionary dictionary];
    probe[@"t"] = @(RCTKNowMs());

    struct utsname systemInfo;
    uname(&systemInfo);
    probe[@"device"] = @{
        @"model": @(systemInfo.machine),
        @"ios": [UIDevice currentDevice].systemVersion ?: @"",
        @"jailbreak": [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ? @"rootless" : @"rootful",
        @"tweakVersion": RCTKPackageVersion()
    };

    // SpringBoard UI state - read on the main thread
    __block NSMutableDictionary *ui = [NSMutableDictionary dictionary];
    void (^readUI)(void) = ^{
        id sb = [UIApplication sharedApplication];
        ui[@"screenOn"] = RCTKSendBool(RCTKShared(@"SBBacklightController", @"sharedInstance"), @"screenIsOn") ?: [NSNull null];
        ui[@"locked"] = RCTKSendBool(RCTKShared(@"SBLockScreenManager", @"sharedInstance"), @"isUILocked") ?: [NSNull null];
        id frontApp = RCTKSend(sb, @"_accessibilityFrontMostApplication");
        ui[@"frontApp"] = RCTKSend(frontApp, @"bundleIdentifier") ?: @"com.apple.springboard";
        ui[@"siriVisible"] = RCTKSendBool(NSClassFromString(@"SBAssistantController"), @"isVisible") ?: [NSNull null];
        ui[@"controlCenterVisible"] = RCTKSendBool(RCTKShared(@"SBControlCenterController", @"sharedInstanceIfExists"), @"isVisible") ?: @NO;
        id switcher = RCTKShared(@"SBMainSwitcherViewController", @"sharedInstanceIfExists");
        ui[@"switcherVisible"] = RCTKSendBool(switcher, @"isMainSwitcherVisible") ?: RCTKSendBool(RCTKShared(@"SBMainSwitcherControllerCoordinator", @"sharedInstance"), @"isAnySwitcherVisible") ?: [NSNull null];
        ui[@"rotationLocked"] = RCTKSendBool(RCTKShared(@"SBOrientationLockManager", @"sharedInstance"), @"isUserLocked") ?: [NSNull null];
        ui[@"darkMode"] = @((BOOL)([UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark));

        // Ringer: the ring/silent switch (iOS 14's SpringBoard has no ringerControl)
        id ringer = RCTKSend(sb, @"ringerControl");
        NSNumber *muted = RCTKSendBool(ringer, @"_accessibilityIsRingerMuted") ?: RCTKSendBool(ringer, @"isRingerMuted");
        if (!muted) {
            NSNumber *state = RCTKSendLong(sb, @"ringerSwitchState");
            if (state) muted = @((BOOL)(((int)state.longValue) == 0));
        }
        ui[@"ringerMuted"] = muted ?: [NSNull null];

        id wifi = RCTKShared(@"SBWiFiManager", @"sharedInstance");
        ui[@"wifiEnabled"] = RCTKSendBool(wifi, @"wiFiEnabled") ?: [NSNull null];
        ui[@"wifiNetwork"] = RCTKSend(wifi, @"currentNetworkName") ?: [NSNull null];
    };
    if ([NSThread isMainThread]) readUI(); else dispatch_sync(dispatch_get_main_queue(), readUI);
    [probe addEntriesFromDictionary:ui];

    // Audio volume (0-1)
    id av = RCTKShared(@"AVSystemController", @"sharedAVSystemController");
    SEL activeSel = NSSelectorFromString(@"getActiveCategoryVolume:andName:");
    if ([av respondsToSelector:activeSel]) {
        float volume = -1;
        NSString *name = nil;
        if (((BOOL (*)(id, SEL, float *, NSString **))objc_msgSend)(av, activeSel, &volume, &name)) probe[@"volume"] = @(volume);
    }

    dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_NOW);
    probe[@"bluetoothPowered"] = RCTKSendBool(RCTKShared(@"BluetoothManager", @"sharedInstance"), @"powered") ?: [NSNull null];
    probe[@"lowPowerMode"] = @([NSProcessInfo processInfo].isLowPowerModeEnabled);

    id torch = ((id (*)(id, SEL, NSString *))objc_msgSend)(NSClassFromString(@"AVCaptureDevice"), NSSelectorFromString(@"defaultDeviceWithMediaType:"), @"vide");
    NSNumber *torchMode = RCTKSendLong(torch, @"torchMode");
    probe[@"flashlightOn"] = torchMode ? @((BOOL)(torchMode.longValue == 1)) : [NSNull null];

    id mc = RCTKShared(@"MCProfileConnection", @"sharedConnection");
    id maxInactivity = [mc respondsToSelector:NSSelectorFromString(@"userValueForSetting:")]
        ? ((id (*)(id, SEL, NSString *))objc_msgSend)(mc, NSSelectorFromString(@"userValueForSetting:"), @"maxInactivity") : nil;
    if (maxInactivity) probe[@"autoLockSeconds"] = @([maxInactivity intValue]);

    UIDevice *device = [UIDevice currentDevice];
    device.batteryMonitoringEnabled = YES;
    probe[@"battery"] = @{
        @"level": @(device.batteryLevel),
        @"charging": @((BOOL)(device.batteryState == UIDeviceBatteryStateCharging || device.batteryState == UIDeviceBatteryStateFull))
    };

    // States only the status commands know how to read
    probe[@"status"] = @{
        @"dnd": RCTKStatus(@"dnd status"),
        @"airplane": RCTKStatus(@"airplane status"),
        @"cellular": RCTKStatus(@"cell status"),
        @"location": RCTKStatus(@"location status")
    };

    probe[@"latestPhoto"] = RCTKLatestPhoto();

    NSDictionary *config = RCCopyTriggerConfig();
    probe[@"tweak"] = @{
        @"masterEnabled": @([config[@"masterEnabled"] boolValue]),
        @"triggerCount": @([config[@"triggers"] count]),
        @"capture": @(g_tkCapture)
    };
    return probe;
}

#pragma mark - Snapshot / restore

static NSDictionary *RCTKTakeSnapshot(void) {
    NSDictionary *probe = RCTKProbe();
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"t"] = probe[@"t"];
    for (NSString *key in @[@"wifiEnabled", @"bluetoothPowered", @"lowPowerMode", @"rotationLocked", @"darkMode", @"flashlightOn", @"volume", @"autoLockSeconds"]) {
        if (probe[key] && probe[key] != [NSNull null]) snapshot[key] = probe[key];
    }
    NSString *dnd = [probe[@"status"][@"dnd"] uppercaseString];
    if ([dnd containsString:@"ON"] || [dnd containsString:@"OFF"]) snapshot[@"dndOn"] = @((BOOL)([dnd containsString:@"ON"] && ![dnd containsString:@"OFF"]));
    NSDictionary *config = RCCopyTriggerConfig();
    if (config) snapshot[@"config"] = config;
    [snapshot writeToFile:kRCTKSnapshotPath atomically:YES];
    RCTKEvent(@"testkit.snapshot", nil);
    return snapshot;
}

static NSDictionary *RCTKRestore(void) {
    NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:kRCTKSnapshotPath];
    if (!snapshot) return @{ @"error": @"no snapshot" };

    NSMutableArray *commands = [NSMutableArray array];
    if (snapshot[@"config"] && ![snapshot[@"config"] isEqual:RCCopyTriggerConfig()]) {
        RCSetTriggerConfig(snapshot[@"config"]);
        [commands addObject:@"(config restored)"];
    }

    NSDictionary *now = RCTKProbe();
    void (^restore)(NSString *, NSString *, NSString *) = ^(NSString *key, NSString *onCommand, NSString *offCommand) {
        id want = snapshot[key];
        if (!want || [now[key] isEqual:want]) return;
        [commands addObject:[want boolValue] ? onCommand : offCommand];
    };
    restore(@"wifiEnabled", @"wifi on", @"wifi off");
    restore(@"bluetoothPowered", @"bluetooth on", @"bluetooth off");
    restore(@"lowPowerMode", @"lpm on", @"lpm off");
    restore(@"rotationLocked", @"rotate lock", @"rotate unlock");
    restore(@"darkMode", @"appearance dark", @"appearance light");
    restore(@"flashlightOn", @"flashlight on", @"flashlight off");
    if (snapshot[@"dndOn"]) {
        NSString *dndNow = [now[@"status"][@"dnd"] uppercaseString];
        BOOL isOn = [dndNow containsString:@"ON"] && ![dndNow containsString:@"OFF"];
        if (isOn != [snapshot[@"dndOn"] boolValue]) [commands addObject:[snapshot[@"dndOn"] boolValue] ? @"dnd on" : @"dnd off"];
    }
    if (snapshot[@"autoLockSeconds"] && ![now[@"autoLockSeconds"] isEqual:snapshot[@"autoLockSeconds"]]) {
        int seconds = [snapshot[@"autoLockSeconds"] intValue];
        [commands addObject:seconds >= INT_MAX ? @"autolock never" : [NSString stringWithFormat:@"autolock %d", seconds]];
    }
    if (snapshot[@"volume"] && fabs([now[@"volume"] doubleValue] - [snapshot[@"volume"] doubleValue]) > 0.01) {
        [commands addObject:[NSString stringWithFormat:@"set-vol %.2f", [snapshot[@"volume"] doubleValue] * 100.0]];
    }

    NSMutableArray *results = [NSMutableArray array];
    for (NSString *command in commands) {
        if ([command hasPrefix:@"("]) { [results addObject:@{ @"command": command }]; continue; }
        [results addObject:@{ @"command": command, @"output": RCTKStatus(command) }];
    }
    RCTKEvent(@"testkit.restore", @{ @"commands": commands });
    return @{ @"restored": results };
}

#pragma mark - Routing

static NSDictionary *RCTKInfo(void) {
    return @{
        @"testkit": @1,
        @"session": g_tkSession ?: @"",
        @"tweakVersion": RCTKPackageVersion(),
        @"endpoints": @[@"info", @"probe", @"journal", @"journal/clear", @"mark", @"run", @"capture", @"snapshot", @"restore"]
    };
}

static NSDictionary *RCTKRun(NSString *command) {
    if (!command.length) return @{ @"error": @"missing command" };
    RCTKEvent(@"testkit.run", @{ @"command": command });
    double start = RCTKNowMs();
    NSString *output = RCHandleCommand(command) ?: @"";
    return @{ @"command": command, @"output": output, @"ms": @(RCTKNowMs() - start) };
}

// endpoint: the part after /api/testkit/; params: query items and/or body
static NSDictionary *RCTKDispatch(NSString *endpoint, NSDictionary<NSString *, NSString *> *params, NSString *body, int *status) {
    *status = 200;
    if ([endpoint isEqualToString:@"info"]) return RCTKInfo();
    if ([endpoint isEqualToString:@"probe"]) return RCTKProbe();
    if ([endpoint isEqualToString:@"journal"]) {
        NSUInteger limit = params[@"limit"] ? (NSUInteger)[params[@"limit"] integerValue] : 1000;
        return RCTKJournal(strtoull([params[@"since"] UTF8String] ?: "0", NULL, 10), params[@"type"], limit);
    }
    if ([endpoint isEqualToString:@"journal/clear"]) {
        NSUInteger cleared;
        @synchronized (RCTKLock()) {
            cleared = g_tkEvents.count;
            [g_tkEvents removeAllObjects];
        }
        return @{ @"cleared": @(cleared) };
    }
    if ([endpoint isEqualToString:@"mark"]) {
        NSString *label = params[@"label"] ?: body ?: @"";
        return @{ @"label": label, @"seq": @(RCTKRecord(@"mark", @{ @"label": label })) };
    }
    if ([endpoint isEqualToString:@"run"]) return RCTKRun(params[@"cmd"] ?: body);
    if ([endpoint isEqualToString:@"capture"]) {
        NSString *on = params[@"on"] ?: body;
        if (on.length) {
            g_tkCapture = [on boolValue] || [on isEqualToString:@"on"] || [on isEqualToString:@"true"];
            RCTKEvent(@"testkit.capture", @{ @"on": @(g_tkCapture) });
        }
        return @{ @"capture": @(g_tkCapture) };
    }
    if ([endpoint isEqualToString:@"snapshot"]) {
        NSMutableDictionary *snapshot = [RCTKTakeSnapshot() mutableCopy];
        [snapshot removeObjectForKey:@"config"]; // large; stored on the device
        snapshot[@"configSaved"] = @YES;
        return snapshot;
    }
    if ([endpoint isEqualToString:@"restore"]) return RCTKRestore();
    *status = 404;
    return @{ @"error": [NSString stringWithFormat:@"unknown endpoint '%@'", endpoint], @"endpoints": RCTKInfo()[@"endpoints"] };
}

static NSString *RCTKJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{\"error\":\"json\"}";
}

NSString *RCTKHandleHTTP(int fd, const char *buffer, long length, NSString *method, NSString *path, NSString *cors) {
    NSURLComponents *components = [NSURLComponents componentsWithString:path];
    NSString *endpoint = [components.path substringFromIndex:MIN(components.path.length, (NSUInteger)13)]; // after "/api/testkit/"
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        if (item.value) params[item.name] = item.value;
    }

    // Body: whatever followed the headers in the first read, plus the rest per Content-Length
    NSString *body = nil;
    const char *headersEnd = strnstr(buffer, "\r\n\r\n", (size_t)length);
    if (headersEnd && [method isEqualToString:@"POST"]) {
        size_t offset = (size_t)(headersEnd - buffer) + 4;
        NSMutableData *data = [NSMutableData dataWithBytes:buffer + offset length:(size_t)length - offset];
        NSString *headers = [[NSString alloc] initWithBytes:buffer length:offset encoding:NSUTF8StringEncoding];
        NSRange cl = [headers rangeOfString:@"Content-Length: " options:NSCaseInsensitiveSearch];
        NSUInteger contentLength = cl.location != NSNotFound ? (NSUInteger)[[headers substringFromIndex:NSMaxRange(cl)] integerValue] : data.length;
        while (data.length < contentLength) {
            char chunk[4096];
            ssize_t n = read(fd, chunk, sizeof(chunk));
            if (n <= 0) break;
            [data appendBytes:chunk length:(size_t)n];
        }
        body = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!body.length) body = nil;
    }

    int status = 200;
    NSDictionary *result = RCTKDispatch(endpoint, params, body, &status);
    NSString *json = RCTKJSON(result);
    return [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\n%@Content-Type: application/json\r\nContent-Length: %lu\r\n\r\n%@",
            status, status == 200 ? @"OK" : @"Not Found", cors, (unsigned long)[json lengthOfBytesUsingEncoding:NSUTF8StringEncoding], json];
}

NSString *RCTKHandleCommand(NSString *args) {
    NSString *trimmed = [args stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange space = [trimmed rangeOfString:@" "];
    NSString *endpoint = space.location == NSNotFound ? trimmed : [trimmed substringToIndex:space.location];
    NSString *rest = space.location == NSNotFound ? nil : [trimmed substringFromIndex:space.location + 1];
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if ([endpoint isEqualToString:@"journal"] && rest) params[@"since"] = rest;
    int status = 200;
    return [RCTKJSON(RCTKDispatch(endpoint.length ? endpoint : @"info", params, rest, &status)) stringByAppendingString:@"\n"];
}

#pragma mark - Events from iOS

// iOS recognizing its screenshot gesture (the chord differs by device)
%hook SBLockHardwareButton
- (void)screenshotRecognizerDidRecognize:(id)recognizer {
    RCTKEvent(@"ios.screenshotGesture", @{ @"source": @"lock" });
    %orig;
}
%end

%hook SBHomeHardwareButton
- (void)screenshotRecognizerDidRecognize:(id)recognizer {
    RCTKEvent(@"ios.screenshotGesture", @{ @"source": @"home" });
    %orig;
}
%end

%hook SBCombinationHardwareButton
- (void)screenshotGesture:(id)gesture {
    RCTKEvent(@"ios.screenshotGesture", @{ @"source": @"combination" });
    %orig;
}
%end

%ctor {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
    %init;
    RCTKLock();
    g_tkSession = [[NSUUID UUID] UUIDString];

    // Screen on/off, as SpringBoard reports it
    int token;
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t blanked = 0;
        notify_get_state(t, &blanked);
        RCTKEvent(@"screen", @{ @"on": @((BOOL)(blanked == 0)) });
    });
    RCTKEvent(@"testkit.loaded", @{ @"tweakVersion": RCTKPackageVersion() });
}
