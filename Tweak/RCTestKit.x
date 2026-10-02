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
//   POST /api/testkit/lua               body (or ?code=): Lua; returns what it printed and returned
//   GET  /api/testkit/suites            the test suites
//   POST /api/testkit/suite/run?name=   run one (conditions, toggles, all, guided, differential); &wait=1 returns the
//                                       report when done; &disruptive=1 adds Wi-Fi etc. toggles
//   POST /api/testkit/suite/skip        skip the current guided step; suite/stop ends the run
//   GET  /api/testkit/report[?id=]      the current/last run, or a saved one
//   GET  /api/testkit/reports           saved report ids

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
            // Rootful package databases are large and can hold descriptions that aren't valid
            // UTF-8, which fails a strict read of the whole file - fall back to Latin-1
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data) continue;
            NSString *status = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
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

// light: only the fast reads (for polling) - no device info, status commands, photos or config
static NSDictionary *RCTKProbeWith(BOOL light) {
    NSMutableDictionary *probe = [NSMutableDictionary dictionary];
    probe[@"t"] = @(RCTKNowMs());

    struct utsname systemInfo;
    uname(&systemInfo);
    if (!light) probe[@"device"] = @{
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

    if (light) return probe;

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

static NSDictionary *RCTKProbe(void) {
    return RCTKProbeWith(NO);
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


#pragma mark - Suites

// A suite run: started over HTTP (suite/run), executed on a background queue, results
// recorded as they happen (report, and test.result events in the journal), saved as JSON
// under kRCTKReportsDir when done.

static NSString *const kRCTKReportsDir = @"/var/mobile/Documents/rc_testkit_reports";
static NSMutableDictionary *g_tkRun; // the run in progress, or the last one

static void RCTKRecordResult(NSMutableDictionary *run, NSString *testId, NSString *status, NSDictionary *detail, double ms) {
    NSMutableDictionary *result = [@{ @"id": testId, @"status": status } mutableCopy];
    if (detail.count) result[@"detail"] = detail;
    if (ms >= 0) result[@"ms"] = @(round(ms));
    @synchronized (run) { [run[@"tests"] addObject:result]; }
    RCTKEvent(@"test.result", result);
}

static BOOL RCTKCondition(NSString *key, NSString *value) {
    return RCEvaluateIfCondition(@{ @"conditionKey": key, @"expectedValue": value });
}

// "ON"/"OFF" from a probe boolean or a status line ("DND OFF"); nil if unknown
static NSString *RCTKOnOff(id state) {
    if (!state || state == [NSNull null]) return nil;
    if ([state isKindOfClass:[NSString class]]) {
        NSString *upper = [state uppercaseString];
        if ([upper containsString:@"OFF"]) return @"OFF";
        if ([upper containsString:@"ON"]) return @"ON";
        return nil;
    }
    return [state boolValue] ? @"ON" : @"OFF";
}

// The cheap part of the probe, for polling while waiting on a change
static NSDictionary *RCTKProbeLight(void) {
    return RCTKProbeWith(YES);
}

#pragma mark Conditions suite

// Every If condition, evaluated with the device left as it is: enumerated conditions must
// read TRUE for exactly one value, and that value must match the device state where the
// probe can read it independently
static void RCTKSuiteConditions(NSMutableDictionary *run) {
    NSDictionary *p = RCTKProbe();
    NSDictionary *status = p[@"status"];

    NSString *autolock = nil;
    int seconds = [p[@"autoLockSeconds"] intValue];
    if (p[@"autoLockSeconds"]) {
        if (seconds >= INT_MAX) autolock = @"NEVER";
        else if (seconds == 30) autolock = @"30S";
        else if (seconds % 60 == 0 && seconds / 60 >= 1 && seconds / 60 <= 5) autolock = [NSString stringWithFormat:@"%dM", seconds / 60];
    }
    id none = [NSNull null];
    NSString *(^yesNo)(id, NSString *, NSString *) = ^NSString *(id state, NSString *yes, NSString *no) {
        if (!state || state == [NSNull null]) return nil;
        return [state boolValue] ? yes : no;
    };

    // key, values, the value the device state says should be TRUE (or null if unreadable)
    NSArray *specs = @[
        @[@"lock", @[@"LOCKED", @"UNLOCKED"], yesNo(p[@"locked"], @"LOCKED", @"UNLOCKED") ?: none],
        @[@"autolock", @[@"30S", @"1M", @"2M", @"3M", @"4M", @"5M", @"NEVER"], autolock ?: none],
        @[@"player", @[@"PLAYING", @"PAUSED", @"STOPPED"], none],
        @[@"wifi", @[@"ON", @"OFF"], RCTKOnOff(p[@"wifiEnabled"]) ?: none],
        @[@"bluetooth", @[@"ON", @"OFF"], RCTKOnOff(p[@"bluetoothPowered"]) ?: none],
        @[@"cellular", @[@"ON", @"OFF"], RCTKOnOff(status[@"cellular"]) ?: none],
        @[@"location", @[@"ON", @"OFF"], RCTKOnOff(status[@"location"]) ?: none],
        @[@"airplane", @[@"ON", @"OFF"], RCTKOnOff(status[@"airplane"]) ?: none],
        @[@"dnd", @[@"ON", @"OFF"], RCTKOnOff(status[@"dnd"]) ?: none],
        @[@"lpm", @[@"ON", @"OFF"], RCTKOnOff(p[@"lowPowerMode"]) ?: none],
        @[@"ringer", @[@"SILENT", @"RING"], yesNo(p[@"ringerMuted"], @"SILENT", @"RING") ?: none],
        @[@"silent_vibration", @[@"ON", @"OFF"], none],
        @[@"ring_vibration", @[@"ON", @"OFF"], none],
        @[@"orientation", @[@"PORTRAIT", @"LANDSCAPE"], none],
        @[@"rotation_lock", @[@"LOCKED", @"UNLOCKED"], yesNo(p[@"rotationLocked"], @"LOCKED", @"UNLOCKED") ?: none],
        @[@"appearance", @[@"DARK", @"LIGHT"], yesNo(p[@"darkMode"], @"DARK", @"LIGHT") ?: none],
        @[@"flashlight", @[@"ON", @"OFF"], RCTKOnOff(p[@"flashlightOn"]) ?: none],
        @[@"screenrecord", @[@"ACTIVE", @"INACTIVE"], none],
        @[@"charging", @[@"CHARGING", @"NOT_CHARGING"], yesNo(p[@"battery"][@"charging"], @"CHARGING", @"NOT_CHARGING") ?: none],
        @[@"proximity", @[@"NEAR", @"FAR"], none],
        @[@"screen", @[@"ON", @"OFF"], RCTKOnOff(p[@"screenOn"]) ?: none],
    ];

    for (NSArray *spec in specs) {
        NSString *key = spec[0];
        NSArray *values = spec[1];
        id truth = spec[2];
        double start = RCTKNowMs();
        NSMutableArray *trueValues = [NSMutableArray array];
        for (NSString *value in values) {
            if (RCTKCondition(key, value)) [trueValues addObject:value];
        }
        double ms = RCTKNowMs() - start;
        // Auto-Lock can be set to a value the condition doesn't list (e.g. 10 minutes)
        BOOL zeroAllowed = [key isEqualToString:@"autolock"] && truth == none;
        BOOL exclusive = trueValues.count == 1 || (zeroAllowed && trueValues.count == 0);
        RCTKRecordResult(run, [NSString stringWithFormat:@"conditions.%@.exclusive", key], exclusive ? @"pass" : @"fail",
                         @{ @"true": trueValues, @"values": values }, ms);
        if (truth != none) {
            BOOL matches = trueValues.count == 1 && [trueValues[0] isEqualToString:truth];
            RCTKRecordResult(run, [NSString stringWithFormat:@"conditions.%@.matchesState", key], matches ? @"pass" : @"fail",
                             @{ @"state": truth, @"true": trueValues }, -1);
        } else {
            RCTKRecordResult(run, [NSString stringWithFormat:@"conditions.%@.matchesState", key], @"skip",
                             @{ @"reason": @"the probe can't read this state" }, -1);
        }
    }

    // One expectation: the condition with this value should read `expected`
    void (^expect)(NSString *, NSString *, NSString *, BOOL) = ^(NSString *testId, NSString *key, NSString *value, BOOL expected) {
        double start = RCTKNowMs();
        BOOL got = RCTKCondition(key, value);
        RCTKRecordResult(run, testId, got == expected ? @"pass" : @"fail",
                         @{ @"condition": key, @"value": value, @"expected": @(expected), @"got": @(got) }, RCTKNowMs() - start);
    };

    // Day of week: today, tomorrow, the weekday/weekend groups, a list
    NSArray *days = @[@"SUN", @"MON", @"TUE", @"WED", @"THU", @"FRI", @"SAT"];
    NSInteger weekday = [[NSCalendar currentCalendar] component:NSCalendarUnitWeekday fromDate:[NSDate date]]; // 1 = Sunday
    NSString *today = days[weekday - 1], *tomorrow = days[weekday % 7];
    BOOL isWeekend = weekday == 1 || weekday == 7;
    expect(@"conditions.day_of_week.today", @"day_of_week", today, YES);
    expect(@"conditions.day_of_week.tomorrow", @"day_of_week", tomorrow, NO);
    expect(@"conditions.day_of_week.weekdays", @"day_of_week", @"WEEKDAYS", !isWeekend);
    expect(@"conditions.day_of_week.weekends", @"day_of_week", @"WEEKENDS", isWeekend);
    expect(@"conditions.day_of_week.list", @"day_of_week", [NSString stringWithFormat:@"%@,%@", tomorrow, today], YES);

    // Time of day: a range around now, and one starting an hour from now
    NSDateComponents *now = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:[NSDate date]];
    NSInteger minutes = now.hour * 60 + now.minute;
    NSString *(^hhmm)(NSInteger) = ^NSString *(NSInteger m) {
        m = ((m % 1440) + 1440) % 1440;
        return [NSString stringWithFormat:@"%02ld:%02ld", (long)(m / 60), (long)(m % 60)];
    };
    expect(@"conditions.time_between.now", @"time_between", [NSString stringWithFormat:@"%@-%@", hhmm(minutes - 60), hhmm(minutes + 60)], YES);
    expect(@"conditions.time_between.later", @"time_between", [NSString stringWithFormat:@"%@-%@", hhmm(minutes + 60), hhmm(minutes + 120)], NO);

    // Thresholds around the current battery level and volume
    double battery = [p[@"battery"][@"level"] doubleValue] * 100.0;
    if (battery >= 10 && battery <= 90) {
        expect(@"conditions.battery.above", @"battery", [NSString stringWithFormat:@"ABOVE %.0f", battery - 5], YES);
        expect(@"conditions.battery.below", @"battery", [NSString stringWithFormat:@"BELOW %.0f", battery + 5], YES);
        expect(@"conditions.battery.notAbove", @"battery", [NSString stringWithFormat:@"ABOVE %.0f", battery + 5], NO);
    } else {
        RCTKRecordResult(run, @"conditions.battery", @"skip", @{ @"reason": @"battery level too close to 0 or 100", @"level": @(battery) }, -1);
    }
    if (p[@"volume"]) {
        double volume = [p[@"volume"] doubleValue] * 100.0;
        if (volume >= 10 && volume <= 90) {
            expect(@"conditions.volume.above", @"volume", [NSString stringWithFormat:@"ABOVE %.0f", volume - 5], YES);
            expect(@"conditions.volume.below", @"volume", [NSString stringWithFormat:@"BELOW %.0f", volume + 5], YES);
            expect(@"conditions.volume.notAbove", @"volume", [NSString stringWithFormat:@"ABOVE %.0f", volume + 5], NO);
        } else {
            RCTKRecordResult(run, @"conditions.volume", @"skip", @{ @"reason": @"volume too close to 0 or 100", @"level": @(volume) }, -1);
        }
    }

    // Names: the current Wi-Fi network (exact and lowercase), and ones that don't exist
    NSString *ssid = [p[@"wifiNetwork"] isKindOfClass:[NSString class]] ? p[@"wifiNetwork"] : nil;
    if (ssid.length) {
        expect(@"conditions.wifi_network.current", @"wifi_network", ssid, YES);
        expect(@"conditions.wifi_network.caseInsensitive", @"wifi_network", ssid.lowercaseString, YES);
    } else {
        RCTKRecordResult(run, @"conditions.wifi_network.current", @"skip", @{ @"reason": @"not on Wi-Fi" }, -1);
    }
    expect(@"conditions.wifi_network.other", @"wifi_network", @"RCTK No Such Network", NO);
    expect(@"conditions.bt_device.other", @"bt_device", @"RCTK No Such Device", NO);

    NSString *front = p[@"frontApp"];
    if (front.length && ![front isEqualToString:@"com.apple.springboard"]) {
        expect(@"conditions.front_app.current", @"front_app", front, YES);
    }
    expect(@"conditions.front_app.other", @"front_app", @"com.example.rctk.none", NO);
}

#pragma mark Toggles suite

// Waits until read() returns `want` (polling), up to timeout. Returns the ms it took, or -1.
static double RCTKWaitFor(id (^read)(void), id want, double timeoutMs, id *last) {
    double start = RCTKNowMs();
    while (YES) {
        id now = read();
        if (last) *last = now;
        if ([now isEqual:want]) return RCTKNowMs() - start;
        if (RCTKNowMs() - start > timeoutMs) return -1;
        [NSThread sleepForTimeInterval:0.1];
    }
}

// Runs `command`, then waits for read() to report `want`; records the step and then whether
// the matching If condition agrees with the new state
static void RCTKToggleStep(NSMutableDictionary *run, NSString *testId, NSString *command, id (^read)(void), id want,
                           NSString *conditionKey, NSString *conditionValue) {
    NSString *output = [RCHandleCommand(command) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    id last = nil;
    double ms = RCTKWaitFor(read, want, 3000, &last);
    RCTKRecordResult(run, testId, ms >= 0 ? @"pass" : @"fail",
                     @{ @"command": command, @"output": output, @"want": want ?: [NSNull null], @"got": last ?: [NSNull null] }, ms);
    if (conditionKey && ms >= 0) {
        BOOL holds = RCTKCondition(conditionKey, conditionValue);
        RCTKRecordResult(run, [testId stringByAppendingString:@".condition"], holds ? @"pass" : @"fail",
                         @{ @"condition": conditionKey, @"value": conditionValue, @"got": @(holds) }, -1);
    }
}

// Each toggle: on/off commands, the toggle command, how to read it back, the matching
// condition, and whether it disrupts connectivity or other apps (run only on request)
static NSArray *RCTKToggleSpecs(void) {
    id (^probeBool)(NSString *) = ^id(NSString *key) {
        return ^id { return RCTKOnOff(RCTKProbeLight()[key]); };
    };
    id (^statusOnOff)(NSString *) = ^id(NSString *command) {
        return ^id { return RCTKOnOff(RCTKStatus(command)); };
    };
    return @[
        @{ @"name": @"lpm", @"on": @"lpm on", @"off": @"lpm off", @"toggle": @"lpm toggle", @"read": probeBool(@"lowPowerMode"), @"condition": @"lpm" },
        @{ @"name": @"rotationLock", @"on": @"rotate lock", @"off": @"rotate unlock", @"toggle": @"rotate toggle", @"read": probeBool(@"rotationLocked"), @"condition": @"rotation_lock", @"conditionOn": @"LOCKED", @"conditionOff": @"UNLOCKED" },
        @{ @"name": @"appearance", @"on": @"appearance dark", @"off": @"appearance light", @"toggle": @"appearance toggle", @"read": probeBool(@"darkMode"), @"condition": @"appearance", @"conditionOn": @"DARK", @"conditionOff": @"LIGHT" },
        @{ @"name": @"flashlight", @"on": @"flashlight on", @"off": @"flashlight off", @"toggle": @"flashlight toggle", @"read": probeBool(@"flashlightOn"), @"condition": @"flashlight" },
        @{ @"name": @"dnd", @"on": @"dnd on", @"off": @"dnd off", @"toggle": @"dnd toggle", @"read": statusOnOff(@"dnd status"), @"condition": @"dnd" },
        @{ @"name": @"bluetooth", @"on": @"bluetooth on", @"off": @"bluetooth off", @"toggle": @"bluetooth toggle", @"read": probeBool(@"bluetoothPowered"), @"condition": @"bluetooth", @"disruptive": @YES },
        @{ @"name": @"wifi", @"on": @"wifi on", @"off": @"wifi off", @"toggle": @"wifi toggle", @"read": probeBool(@"wifiEnabled"), @"condition": @"wifi", @"disruptive": @YES },
        @{ @"name": @"location", @"on": @"location on", @"off": @"location off", @"toggle": @"location toggle", @"read": statusOnOff(@"location status"), @"condition": @"location", @"disruptive": @YES },
        @{ @"name": @"cellular", @"on": @"cellular on", @"off": @"cellular off", @"read": statusOnOff(@"cell status"), @"condition": @"cellular", @"disruptive": @YES },
        @{ @"name": @"airplane", @"on": @"airplane on", @"off": @"airplane off", @"read": statusOnOff(@"airplane status"), @"condition": @"airplane", @"disruptive": @YES },
    ];
}

static void RCTKSuiteToggles(NSMutableDictionary *run, BOOL disruptive) {
    for (NSDictionary *spec in RCTKToggleSpecs()) {
        NSString *name = spec[@"name"];
        if ([spec[@"disruptive"] boolValue] && !disruptive) {
            RCTKRecordResult(run, [NSString stringWithFormat:@"toggles.%@", name], @"skip", @{ @"reason": @"disruptive - run with disruptive=1" }, -1);
            continue;
        }
        id (^read)(void) = spec[@"read"];
        NSString *initial = read();
        if (!initial) {
            RCTKRecordResult(run, [NSString stringWithFormat:@"toggles.%@", name], @"skip", @{ @"reason": @"state unreadable" }, -1);
            continue;
        }
        NSString *other = [initial isEqualToString:@"ON"] ? @"OFF" : @"ON";
        NSString *conditionOn = spec[@"conditionOn"] ?: @"ON", *conditionOff = spec[@"conditionOff"] ?: @"OFF";
        NSString *(^conditionFor)(NSString *) = ^NSString *(NSString *state) {
            return [state isEqualToString:@"ON"] ? conditionOn : conditionOff;
        };
        // Away from the starting state and back with on/off, then the same with toggle
        for (NSString *target in @[other, initial]) {
            NSString *command = [target isEqualToString:@"ON"] ? spec[@"on"] : spec[@"off"];
            RCTKToggleStep(run, [NSString stringWithFormat:@"toggles.%@.%@", name, target.lowercaseString], command, read, target,
                           spec[@"condition"], conditionFor(target));
        }
        if (spec[@"toggle"]) {
            RCTKToggleStep(run, [NSString stringWithFormat:@"toggles.%@.toggle", name], spec[@"toggle"], read, other, spec[@"condition"], conditionFor(other));
            RCTKToggleStep(run, [NSString stringWithFormat:@"toggles.%@.toggleBack", name], spec[@"toggle"], read, initial, spec[@"condition"], conditionFor(initial));
        }
    }

    // Auto-Lock: three values, read back in seconds
    id (^autoLock)(void) = ^id { return RCTKProbeLight()[@"autoLockSeconds"]; };
    RCTKToggleStep(run, @"toggles.autolock.2m", @"autolock 2m", autoLock, @120, @"autolock", @"2M");
    RCTKToggleStep(run, @"toggles.autolock.30s", @"autolock 30s", autoLock, @30, @"autolock", @"30S");
    RCTKToggleStep(run, @"toggles.autolock.never", @"autolock never", autoLock, @(INT_MAX), @"autolock", @"NEVER");

    // Volume: an absolute level, then one step up and back down (1/16 per step)
    id (^volume)(void) = ^id {
        id level = RCTKProbeLight()[@"volume"];
        return level ? @(round([level doubleValue] * 1000) / 1000) : nil;
    };
    RCTKToggleStep(run, @"toggles.volume.set", @"set-vol 25", volume, @0.25, @"volume", @"ABOVE 20");
    RCTKToggleStep(run, @"toggles.volume.up", @"volume up", volume, @0.313, @"volume", @"ABOVE 30");
    RCTKToggleStep(run, @"toggles.volume.down", @"volume down", volume, @0.25, @"volume", @"BELOW 30");
}


#pragma mark Guided suite

// Button and gesture triggers, asked for one at a time with a banner prompt. Every trigger in
// RCTKGuidedTriggerKeys is bound in a temporary config with capture on, so detection is
// tested without running anyone's actions. A step passes if exactly its expected triggers
// fired, once each, and no other button/gesture trigger did.

static volatile BOOL g_tkSkipStep = NO;
static volatile BOOL g_tkStopRun = NO;

static NSArray<NSString *> *RCTKGuidedTriggerKeys(void) {
    return @[@"volume_up_hold", @"volume_down_hold", @"volume_both_press", @"volume_up_then_down", @"volume_down_then_up",
             @"power_double_tap", @"power_long_press", @"power_triple_click", @"power_quadruple_click",
             @"power_volume_up", @"power_volume_down",
             @"trigger_statusbar_left_hold", @"trigger_statusbar_center_hold", @"trigger_statusbar_right_hold",
             @"trigger_statusbar_swipe_left", @"trigger_statusbar_swipe_right", @"trigger_statusbar_double_tap",
             @"trigger_home_double_click", @"trigger_home_triple_click", @"trigger_home_quadruple_click",
             @"trigger_ringer_mute", @"trigger_ringer_unmute", @"trigger_ringer_toggle"];
}

static BOOL RCTKHasHomeButton(void) {
    __block long type = -1;
    void (^read)(void) = ^{
        id lockButton = RCTKSend([UIApplication sharedApplication], @"lockHardwareButton");
        NSNumber *value = RCTKSendLong(lockButton, @"homeButtonType");
        if (value) type = value.longValue;
    };
    if ([NSThread isMainThread]) read(); else dispatch_sync(dispatch_get_main_queue(), read);
    return type != 2; // 2: no Home button (Face ID); 1: solid-state Home button
}

// id, prompt, expected trigger keys, and optionally: oneOf (exactly one of these must fire too),
// home (YES: Home-button phones only, NO: phones without one)
static NSArray<NSDictionary *> *RCTKGuidedSteps(BOOL hasHome) {
    NSMutableArray *steps = [NSMutableArray arrayWithArray:@[
        @{ @"id": @"volume_up_hold", @"prompt": @"Hold Volume Up for a second", @"expect": @[@"volume_up_hold"] },
        @{ @"id": @"volume_down_hold", @"prompt": @"Hold Volume Down for a second", @"expect": @[@"volume_down_hold"] },
        @{ @"id": @"volume_both_press", @"prompt": @"Press Volume Up + Down together", @"expect": @[@"volume_both_press"] },
        @{ @"id": @"volume_up_then_down", @"prompt": @"Press Volume Up, then Volume Down", @"expect": @[@"volume_up_then_down"] },
        @{ @"id": @"volume_down_then_up", @"prompt": @"Press Volume Down, then Volume Up", @"expect": @[@"volume_down_then_up"] },
        @{ @"id": @"power_double_tap", @"prompt": @"Double-press Power", @"expect": @[@"power_double_tap"] },
        @{ @"id": @"power_triple_click", @"prompt": @"Triple-press Power", @"expect": @[@"power_triple_click"] },
        @{ @"id": @"power_quadruple_click", @"prompt": @"Press Power 4 times", @"expect": @[@"power_quadruple_click"] },
        @{ @"id": @"power_long_press", @"prompt": @"Hold Power for a second, then let go", @"expect": @[@"power_long_press"] },
        @{ @"id": @"power_volume_up", @"prompt": @"Press Power + Volume Up together", @"expect": @[@"power_volume_up"] },
        @{ @"id": @"power_volume_down", @"prompt": @"Press Power + Volume Down together", @"expect": @[@"power_volume_down"] },
        @{ @"id": @"ringer_flip", @"prompt": @"Flip the ring/silent switch", @"expect": @[@"trigger_ringer_toggle"], @"oneOf": @[@"trigger_ringer_mute", @"trigger_ringer_unmute"] },
        @{ @"id": @"ringer_flip_back", @"prompt": @"Flip the ring/silent switch back", @"expect": @[@"trigger_ringer_toggle"], @"oneOf": @[@"trigger_ringer_mute", @"trigger_ringer_unmute"] },
        @{ @"id": @"statusbar_left_hold", @"prompt": @"Touch and hold the top-left corner", @"expect": @[@"trigger_statusbar_left_hold"] },
        @{ @"id": @"statusbar_center_hold", @"prompt": @"Touch and hold the top-center", @"expect": @[@"trigger_statusbar_center_hold"] },
        @{ @"id": @"statusbar_right_hold", @"prompt": @"Touch and hold the top-right corner", @"expect": @[@"trigger_statusbar_right_hold"] },
        @{ @"id": @"statusbar_double_tap", @"prompt": @"Double-tap the status bar", @"expect": @[@"trigger_statusbar_double_tap"] },
        @{ @"id": @"statusbar_swipe_left", @"prompt": @"Swipe left along the status bar", @"expect": @[@"trigger_statusbar_swipe_left"] },
        @{ @"id": @"statusbar_swipe_right", @"prompt": @"Swipe right along the status bar", @"expect": @[@"trigger_statusbar_swipe_right"] },
        @{ @"id": @"home_double_click", @"prompt": @"Double-click Home", @"expect": @[@"trigger_home_double_click"], @"home": @YES },
        @{ @"id": @"home_triple_click", @"prompt": @"Triple-click Home", @"expect": @[@"trigger_home_triple_click"], @"home": @YES },
        @{ @"id": @"home_quadruple_click", @"prompt": @"Click Home 4 times", @"expect": @[@"trigger_home_quadruple_click"], @"home": @YES },
    ]];
    NSIndexSet *wrongDevice = [steps indexesOfObjectsPassingTest:^BOOL(NSDictionary *step, NSUInteger idx, BOOL *stop) {
        return step[@"home"] && [step[@"home"] boolValue] != hasHome;
    }];
    [steps removeObjectsAtIndexes:wrongDevice];
    return steps;
}

// Trigger keys captured (dry-run) after journal seq `since`
static NSArray<NSString *> *RCTKCapturedSince(unsigned long long since) {
    NSMutableArray *keys = [NSMutableArray array];
    for (NSDictionary *event in RCTKJournal(since, @"trigger.captured", 0)[@"events"]) {
        [keys addObject:event[@"key"] ?: @""];
    }
    return keys;
}

static void RCTKSuiteGuided(NSMutableDictionary *run) {
    BOOL hasHome = RCTKHasHomeButton();
    NSArray *steps = RCTKGuidedSteps(hasHome);
    NSSet *buttonKeys = [NSSet setWithArray:RCTKGuidedTriggerKeys()];
    @synchronized (run) { run[@"homeButton"] = @(hasHome); }

    // Bind every button/gesture trigger to a placeholder action, and record instead of running
    NSMutableDictionary *config = [RCCopyTriggerConfig() mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *triggers = [config[@"triggers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *key in RCTKGuidedTriggerKeys()) {
        NSMutableDictionary *trigger = [triggers[key] mutableCopy] ?: [NSMutableDictionary dictionary];
        trigger[@"enabled"] = @YES;
        trigger[@"actions"] = @[@"testkit noop"];
        triggers[key] = trigger;
    }
    config[@"triggers"] = triggers;
    config[@"masterEnabled"] = @YES;
    RCSetTriggerConfig(config);
    g_tkCapture = YES;
    RCTKEvent(@"testkit.capture", @{ @"on": @YES });

    RCShowPrompt(@"RemoteCompanion Test", [NSString stringWithFormat:@"%lu steps - starting...", (unsigned long)steps.count], @"checklist", 3.0);
    [NSThread sleepForTimeInterval:3.5];

    NSUInteger index = 0, passed = 0;
    for (NSDictionary *step in steps) {
        index++;
        if (g_tkStopRun) break;
        g_tkSkipStep = NO;
        NSString *testId = [@"guided." stringByAppendingString:step[@"id"]];
        NSString *title = [NSString stringWithFormat:@"Step %lu of %lu", (unsigned long)index, (unsigned long)steps.count];
        unsigned long long since = RCTKRecord(@"mark", @{ @"label": testId });
        RCShowPrompt(title, step[@"prompt"], @"hand.point.up.left", 60.0);

        NSArray *expect = step[@"expect"];
        NSArray *oneOf = step[@"oneOf"];
        double start = RCTKNowMs(), firstAt = -1;
        BOOL timedOut = NO;
        while (YES) {
            NSArray *got = RCTKCapturedSince(since);
            BOOL allExpected = YES;
            for (NSString *key in expect) if (![got containsObject:key]) allExpected = NO;
            if (got.count && firstAt < 0) firstAt = RCTKNowMs();
            if (allExpected) break;
            if (g_tkSkipStep || g_tkStopRun) break;
            if (RCTKNowMs() - start > 20000) { timedOut = YES; break; }
            [NSThread sleepForTimeInterval:0.05];
        }
        if (g_tkSkipStep || g_tkStopRun || timedOut) {
            NSString *reason = timedOut ? @"timed out - no input detected" : (g_tkStopRun ? @"run stopped" : @"skipped");
            RCTKRecordResult(run, testId, @"skip", @{ @"reason": reason, @"got": RCTKCapturedSince(since) }, -1);
            RCShowPrompt(title, timedOut ? @"Skipped (timed out)" : @"Skipped", @"forward.fill", 1.5);
            [NSThread sleepForTimeInterval:2.0];
            continue;
        }
        double detected = RCTKNowMs() - start;
        [NSThread sleepForTimeInterval:1.2]; // anything that fires a moment later counts too

        NSMutableArray *got = [NSMutableArray array];
        for (NSString *key in RCTKCapturedSince(since)) if ([buttonKeys containsObject:key]) [got addObject:key];
        NSMutableArray *problems = [NSMutableArray array];
        NSCountedSet *counts = [[NSCountedSet alloc] initWithArray:got];
        for (NSString *key in expect) {
            if ([counts countForObject:key] != 1) [problems addObject:[NSString stringWithFormat:@"%@ fired %lu times", key, (unsigned long)[counts countForObject:key]]];
        }
        NSUInteger oneOfCount = 0;
        for (NSString *key in oneOf) oneOfCount += [counts countForObject:key];
        if (oneOf && oneOfCount != 1) [problems addObject:[NSString stringWithFormat:@"expected one of %@, got %lu", [oneOf componentsJoinedByString:@"/"], (unsigned long)oneOfCount]];
        for (NSString *key in counts) {
            if (![expect containsObject:key] && ![oneOf containsObject:key]) [problems addObject:[NSString stringWithFormat:@"unexpected %@", key]];
        }
        BOOL pass = problems.count == 0;
        if (pass) passed++;
        NSMutableDictionary *detail = [@{ @"expected": expect, @"got": got } mutableCopy];
        if (problems.count) detail[@"problems"] = problems;
        RCTKRecordResult(run, testId, pass ? @"pass" : @"fail", detail, detected);
        RCShowPrompt(title, pass ? @"Passed" : [@"Failed: " stringByAppendingString:problems.firstObject],
                     pass ? @"checkmark.circle.fill" : @"xmark.circle.fill", 1.5);
        [NSThread sleepForTimeInterval:2.0];
    }

    g_tkCapture = NO;
    RCTKEvent(@"testkit.capture", @{ @"on": @NO });
    RCShowPrompt(@"RemoteCompanion Test", [NSString stringWithFormat:@"Done: %lu of %lu passed", (unsigned long)passed, (unsigned long)steps.count],
                 @"flag.checkered", 3.0);
}


#pragma mark Differential suite (stock vs tweak)

// Each physical input twice: once with RemoteCompanion's master switch off (stock iOS),
// once with the tweak armed but not claiming the input - every button trigger unbound except
// a placeholder quadruple-click, which arms the Power hold-back-and-replay machinery. The
// outcome (screen on/off sequence, screenshot saved, volume change, Siri, switcher, front
// app) must be the same. If the presses themselves differed between the passes, the step is
// inconclusive rather than failed.

static NSArray<NSDictionary *> *RCTKDifferentialSteps(BOOL hasHome) {
    NSMutableArray *steps = [NSMutableArray arrayWithArray:@[
        @{ @"id": @"power_single", @"buttons": @[@"power"], @"prompt": @"Press Power once" },
        @{ @"id": @"power_double", @"buttons": @[@"power"], @"prompt": @"Double-press Power" },
        @{ @"id": @"power_triple", @"buttons": @[@"power"], @"prompt": @"Triple-press Power" },
        @{ @"id": @"power_volume_up", @"buttons": @[@"power", @"volumeUp"], @"prompt": @"Press Power + Volume Up together" },
        // Stock iOS sleeps or not depending on which is released last. "ordered": the
        // passes are comparable only if the buttons went down and up in the same order.
        @{ @"id": @"power_volume_down_hold", @"buttons": @[@"power", @"volumeDown"], @"prompt": @"Hold Volume Down, click Power, then let go of Volume Down", @"ordered": @YES },
        @{ @"id": @"power_volume_down_inside", @"buttons": @[@"power", @"volumeDown"], @"prompt": @"Hold Power, click Volume Down, then let go of Power (quickly)", @"ordered": @YES },
        @{ @"id": @"home_power", @"buttons": @[@"home", @"power"], @"prompt": @"Press Home + Power together", @"home": @YES },
        @{ @"id": @"volume_up", @"buttons": @[@"volumeUp"], @"prompt": @"Press Volume Up once" },
        @{ @"id": @"volume_both", @"buttons": @[@"volumeUp", @"volumeDown"], @"prompt": @"Press Volume Up + Down together" },
    ]];
    NSIndexSet *wrongDevice = [steps indexesOfObjectsPassingTest:^BOOL(NSDictionary *step, NSUInteger idx, BOOL *stop) {
        return step[@"home"] && [step[@"home"] boolValue] != hasHome;
    }];
    [steps removeObjectsAtIndexes:wrongDevice];
    return steps;
}

static NSDictionary *RCTKConfigWith(NSDictionary *base, BOOL master, BOOL armed) {
    NSMutableDictionary *config = [base mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *triggers = [config[@"triggers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *key in RCTKGuidedTriggerKeys()) {
        NSMutableDictionary *trigger = [triggers[key] mutableCopy];
        if (!trigger) continue;
        trigger[@"enabled"] = @NO;
        triggers[key] = trigger;
    }
    if (armed) triggers[@"power_quadruple_click"] = @{ @"enabled": @YES, @"actions": @[@"testkit noop"], @"name": @"Test kit placeholder" };
    config[@"triggers"] = triggers;
    config[@"masterEnabled"] = @(master);
    return config;
}

// The real (not replayed) button presses after `since`: e.g. @{ @"power": @2, @"volumeUp": @1 }
// Real presses since `since`: a count per button, plus - when more than one button was
// used - the order they first went down and which was released last ("together" within
// 15 ms), which can change what iOS does with a chord. Only presses up to journal entry
// `until` (0: no limit) of the step's `buttons` count: after the first of them, a press of
// any other button (Home to wake an iPhone 8, say) ends the input, and its entry is
// returned in *foreignAt.
static NSDictionary *RCTKInputsSince(unsigned long long since, unsigned long long until, NSArray *buttons,
                                     double *lastInputAt, unsigned long long *foreignAt) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    NSString *lastUp = nil, *previousUp = nil;
    double lastUpAt = 0, previousUpAt = 0, powerDownAt = 0;
    for (NSDictionary *event in RCTKJournal(since, @"hid.", 0)[@"events"]) {
        if (until && [event[@"seq"] unsignedLongLongValue] > until) break;
        if ([event[@"replay"] boolValue]) continue;
        NSString *button = [event[@"type"] isEqualToString:@"hid.power"] ? @"power"
                         : [event[@"type"] isEqualToString:@"hid.home"] ? @"home"
                         : [event[@"button"] isEqualToString:@"up"] ? @"volumeUp" : @"volumeDown";
        if (![buttons containsObject:button]) {
            // Before the step's first press it's just getting ready (waking the phone)
            if (![event[@"down"] boolValue] || !order.count) continue;
            if (foreignAt) *foreignAt = [event[@"seq"] unsignedLongLongValue];
            break;
        }
        if (lastInputAt) *lastInputAt = MAX(*lastInputAt, [event[@"t"] doubleValue]);
        if ([button isEqualToString:@"power"]) {
            // Held long enough for iOS's own long press (Siri, power-off): a different input
            if ([event[@"down"] boolValue]) powerDownAt = [event[@"t"] doubleValue];
            else if (powerDownAt && [event[@"t"] doubleValue] - powerDownAt > 500) counts[@"powerHeldLong"] = @YES;
        }
        if (![event[@"down"] boolValue]) {
            if (![button isEqualToString:lastUp]) { previousUp = lastUp; previousUpAt = lastUpAt; }
            lastUp = button; lastUpAt = [event[@"t"] doubleValue];
            continue;
        }
        counts[button] = @([counts[button] integerValue] + 1);
        if (![order containsObject:button]) [order addObject:button];
    }
    if (order.count > 1) {
        counts[@"order"] = order;
        if (lastUp) counts[@"releasedLast"] = previousUp && lastUpAt - previousUpAt < 15 ? @"together" : lastUp;
    }
    return counts;
}

// Everything a pass changed between journal entries `since` and `until`, and the probes
// before and after. The screen is the list of its changes ("slept", "woke"). SpringBoard's
// notification is read after the fact - a quick off/on can arrive as two "on"s - so each
// one counts as a change from the state before. A wake more than 600 ms after the last
// Power / Home event (real or replayed) is the user waking the phone (a tap, raising it),
// and ends what the pass is judged on.
static NSDictionary *RCTKOutcome(unsigned long long since, unsigned long long until, NSDictionary *before, NSDictionary *after) {
    double lastButtonAt = 0;
    BOOL on = [before[@"screenOn"] boolValue];
    NSMutableArray *changes = [NSMutableArray array];
    for (NSDictionary *event in RCTKJournal(since, nil, 0)[@"events"]) {
        if ([event[@"seq"] unsignedLongLongValue] > until) break;
        NSString *type = event[@"type"];
        if ([type isEqualToString:@"hid.power"] || [type isEqualToString:@"hid.home"]) lastButtonAt = [event[@"t"] doubleValue];
        if (![type isEqualToString:@"screen"]) continue;
        if (!on && (!lastButtonAt || [event[@"t"] doubleValue] - lastButtonAt > 600)) break;
        on = !on;
        [changes addObject:on ? @"woke" : @"slept"];
    }
    NSString *screen = changes.count ? [changes componentsJoinedByString:@", then "]
                                     : ([before[@"screenOn"] boolValue] ? @"stayed on" : @"stayed off");
    NSString *photoBefore = before[@"latestPhoto"][@"file"], *photoAfter = after[@"latestPhoto"][@"file"];
    BOOL screenshot = photoAfter.length && ![photoAfter isEqualToString:photoBefore ?: @""];
    long volumeSteps = lround(([after[@"volume"] doubleValue] - [before[@"volume"] doubleValue]) * 16.0);
    NSMutableDictionary *outcome = [@{
        @"screen": screen,
        @"screenshotSaved": @(screenshot),
        @"volumeSteps": @(volumeSteps),
        @"siri": @([after[@"siriVisible"] boolValue]),
        @"switcher": @([after[@"switcherVisible"] boolValue]),
    } mutableCopy];
    if (![after[@"frontApp"] isEqual:before[@"frontApp"]]) outcome[@"frontApp"] = after[@"frontApp"] ?: @"";
    return outcome;
}

// One pass: prompt, wait for the input, let it settle, record the outcome. Returns nil if no
// input came (timeout, skip, stop).
static NSDictionary *RCTKDifferentialPass(NSString *title, NSString *prompt, NSArray *buttons) {
    NSDictionary *before = RCTKProbe();
    unsigned long long since = RCTKRecord(@"mark", @{ @"label": title });
    RCShowPrompt(title, prompt, @"hand.point.up.left", 60.0);

    // Wait for the first press, then until nothing has been pressed for 2.5 s - or another
    // button is pressed, which is the user waking the phone
    double start = RCTKNowMs(), lastInput = 0;
    unsigned long long foreign = 0;
    while (YES) {
        double last = 0;
        NSDictionary *inputs = RCTKInputsSince(since, 0, buttons, &last, &foreign);
        if (inputs.count) lastInput = last;
        if (lastInput > 0 && (foreign || RCTKNowMs() - lastInput > 2500)) break;
        if (g_tkSkipStep || g_tkStopRun || (lastInput == 0 && RCTKNowMs() - start > 45000)) return nil;
        [NSThread sleepForTimeInterval:0.05];
    }
    unsigned long long until = RCTKRecord(@"mark", @{ @"label": [title stringByAppendingString:@" (recorded)"] });
    if (foreign) until = foreign - 1;
    NSDictionary *after = RCTKProbe();
    NSDictionary *inputs = RCTKInputsSince(since, until, buttons, NULL, NULL);
    NSDictionary *outcome = RCTKOutcome(since, until, before, after);

    // If the pass left the screen off, wait for the user to wake it (that press isn't part of it)
    if (![after[@"screenOn"] boolValue]) {
        double waitStart = RCTKNowMs();
        while (![RCTKProbeLight()[@"screenOn"] boolValue] && RCTKNowMs() - waitStart < 60000 && !g_tkStopRun) {
            [NSThread sleepForTimeInterval:0.2];
        }
        [NSThread sleepForTimeInterval:1.0];
    }
    // Siri / switcher / an app left open would get in the way of the next pass
    if ([outcome[@"siri"] boolValue] || [outcome[@"switcher"] boolValue]) {
        RCShowPrompt(title, @"Close it and go back to the home screen", @"house", 4.0);
        [NSThread sleepForTimeInterval:4.0];
    }
    return @{ @"inputs": inputs, @"outcome": outcome };
}

static const NSUInteger kRCTKDifferentialAttempts = 3; // an inconclusive step is redone twice

static void RCTKSuiteDifferential(NSMutableDictionary *run) {
    BOOL hasHome = RCTKHasHomeButton();
    NSArray *steps = RCTKDifferentialSteps(hasHome);
    NSDictionary *base = RCCopyTriggerConfig();
    NSDictionary *stockConfig = RCTKConfigWith(base, NO, NO);
    NSDictionary *tweakConfig = RCTKConfigWith(base, YES, YES);
    @synchronized (run) { run[@"homeButton"] = @(hasHome); }
    g_tkCapture = YES;
    RCTKEvent(@"testkit.capture", @{ @"on": @YES });

    RCShowPrompt(@"Stock vs tweak test", [NSString stringWithFormat:@"%lu inputs, each twice - starting...", (unsigned long)steps.count], @"square.split.2x1", 3.0);
    [NSThread sleepForTimeInterval:3.5];

    NSUInteger index = 0, same = 0;
    for (NSDictionary *step in steps) {
        index++;
        if (g_tkStopRun) break;
        g_tkSkipStep = NO;
        NSString *testId = [@"differential." stringByAppendingString:step[@"id"]];
        // An inconclusive attempt (the input wasn't the same both times, or wasn't the one
        // asked for) is redone, up to kRCTKDifferentialAttempts in all; earlier attempts
        // stay in the report.
        NSMutableArray *earlier = [NSMutableArray array];
        NSMutableDictionary *detail = nil;
        NSString *status = nil, *retryHint = nil;
        BOOL stepAbandoned = NO;
        for (NSUInteger attempt = 1; attempt <= kRCTKDifferentialAttempts; attempt++) {
            if (retryHint) {
                RCShowPrompt([NSString stringWithFormat:@"Step %lu of %lu - again", (unsigned long)index, (unsigned long)steps.count],
                             retryHint, @"arrow.counterclockwise", 3.0);
                [NSThread sleepForTimeInterval:3.5];
            }
            NSMutableDictionary *passes = [NSMutableDictionary dictionary];
            for (NSString *pass in @[@"stock", @"tweak"]) {
                RCSetTriggerConfig([pass isEqualToString:@"stock"] ? stockConfig : tweakConfig);
                [NSThread sleepForTimeInterval:0.5];
                NSString *title = [NSString stringWithFormat:@"Step %lu of %lu - %@", (unsigned long)index, (unsigned long)steps.count,
                                   [pass isEqualToString:@"stock"] ? @"stock" : @"with tweak"];
                NSDictionary *result = RCTKDifferentialPass(title, step[@"prompt"], step[@"buttons"]);
                if (!result) break;
                passes[pass] = result;
                RCShowPrompt(title, @"Recorded", @"checkmark", 1.0);
                [NSThread sleepForTimeInterval:1.2];
            }
            if (passes.count < 2) {
                RCTKRecordResult(run, testId, @"skip", @{ @"reason": g_tkStopRun ? @"run stopped" : @"no input / skipped", @"passes": passes,
                                                          @"earlierAttempts": earlier }, -1);
                stepAbandoned = YES;
                break;
            }
            NSDictionary *stock = passes[@"stock"], *tweak = passes[@"tweak"];
            detail = [@{ @"stock": stock, @"tweak": tweak, @"attempt": @(attempt) } mutableCopy];
            NSMutableDictionary *stockInputs = [stock[@"inputs"] mutableCopy], *tweakInputs = [tweak[@"inputs"] mutableCopy];
            if (![step[@"ordered"] boolValue]) {
                [stockInputs removeObjectsForKeys:@[@"order", @"releasedLast"]];
                [tweakInputs removeObjectsForKeys:@[@"order", @"releasedLast"]];
            }
            if (stockInputs[@"powerHeldLong"] || tweakInputs[@"powerHeldLong"]) {
                status = @"skip";
                detail[@"reason"] = @"not the requested input - Power was held long enough for iOS's long press (over 0.5 s)";
                retryHint = @"Power was held too long - keep it quick";
            } else if (![stockInputs isEqual:tweakInputs]) {
                status = @"skip";
                detail[@"reason"] = @"inconclusive - the presses (or their order) differed between the two passes";
                retryHint = [step[@"ordered"] boolValue] ? @"The presses differed - same order both times, and release the last button clearly after"
                                                         : @"The presses differed - do exactly the same thing both times";
            } else if ([stock[@"outcome"] isEqual:tweak[@"outcome"]]) {
                status = @"pass";
                break;
            } else {
                status = @"fail";
                NSMutableArray *differs = [NSMutableArray array];
                NSMutableSet *keys = [NSMutableSet setWithArray:[stock[@"outcome"] allKeys]];
                [keys addObjectsFromArray:[tweak[@"outcome"] allKeys]];
                for (NSString *key in keys) if (![stock[@"outcome"][key] isEqual:tweak[@"outcome"][key]]) [differs addObject:key];
                detail[@"differs"] = differs;
                break;
            }
            if (attempt < kRCTKDifferentialAttempts && !g_tkStopRun) [earlier addObject:detail];
            else break;
        }
        if (stepAbandoned) continue;
        if (earlier.count) detail[@"earlierAttempts"] = earlier;
        if ([status isEqualToString:@"pass"]) same++;
        RCTKRecordResult(run, testId, status, detail, -1);
        NSString *verdict = [status isEqualToString:@"pass"] ? @"Same as stock"
                          : [status isEqualToString:@"fail"] ? [@"Differs: " stringByAppendingString:[detail[@"differs"] componentsJoinedByString:@", "]]
                          : @"Inconclusive - the input wasn't the same both times";
        RCShowPrompt([NSString stringWithFormat:@"Step %lu of %lu", (unsigned long)index, (unsigned long)steps.count], verdict,
                     [status isEqualToString:@"pass"] ? @"checkmark.circle.fill" : @"exclamationmark.circle.fill", 1.5);
        [NSThread sleepForTimeInterval:2.0];
    }

    g_tkCapture = NO;
    RCTKEvent(@"testkit.capture", @{ @"on": @NO });
    RCShowPrompt(@"Stock vs tweak test", [NSString stringWithFormat:@"Done: %lu of %lu same as stock", (unsigned long)same, (unsigned long)steps.count],
                 @"flag.checkered", 3.0);
}

#pragma mark Running

static NSDictionary *RCTKSuites(void) {
    return @{ @"suites": @[
        @{ @"name": @"conditions", @"changesState": @NO, @"description": @"Every If condition: exactly one value TRUE, and it matches the device state" },
        @{ @"name": @"toggles", @"changesState": @YES, @"description": @"Toggle actions switch and read back, and their conditions follow; state is snapshotted and restored. disruptive=1 adds Wi-Fi, Bluetooth, location, cellular and airplane mode" },
        @{ @"name": @"all", @"changesState": @YES, @"description": @"conditions, then toggles" },
        @{ @"name": @"guided", @"changesState": @YES, @"description": @"Banner prompts for each button and gesture trigger; passes when exactly that trigger fires. Your config is swapped for a test one (with capture on) and restored. suite/skip skips a step, suite/stop ends the run" },
        @{ @"name": @"differential", @"changesState": @YES, @"description": @"Each Power / Volume / Home input twice - stock (master switch off) and with the tweak armed but not claiming it - and the outcomes (screen, screenshot, volume, Siri, switcher, front app) must match. Real screenshots may be saved during the run" },
    ] };
}

static NSDictionary *RCTKSummarize(NSMutableDictionary *run) {
    NSMutableDictionary *report;
    @synchronized (run) {
        report = [run mutableCopy];
        report[@"tests"] = [run[@"tests"] copy];
    }
    NSUInteger pass = 0, fail = 0, skip = 0;
    for (NSDictionary *test in report[@"tests"]) {
        NSString *status = test[@"status"];
        if ([status isEqualToString:@"pass"]) pass++; else if ([status isEqualToString:@"fail"]) fail++; else skip++;
    }
    report[@"summary"] = @{ @"pass": @(pass), @"fail": @(fail), @"skip": @(skip), @"total": @(pass + fail + skip) };
    return report;
}

static NSDictionary *RCTKRunSuite(NSString *name, BOOL disruptive, BOOL wait) {
    if (![@[@"conditions", @"toggles", @"all", @"guided", @"differential"] containsObject:name ?: @""]) {
        return @{ @"error": [NSString stringWithFormat:@"unknown suite '%@'", name ?: @""], @"suites": RCTKSuites()[@"suites"] };
    }
    NSMutableDictionary *run;
    @synchronized (RCTKLock()) {
        if ([g_tkRun[@"status"] isEqualToString:@"running"]) return @{ @"error": @"a run is in progress", @"id": g_tkRun[@"id"] };
        NSDictionary *probe = RCTKProbe();
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyyMMdd-HHmmss";
        run = [@{
            @"id": [NSString stringWithFormat:@"%@-%@", [formatter stringFromDate:[NSDate date]], name],
            @"suite": name, @"disruptive": @(disruptive), @"status": @"running",
            @"started": @(RCTKNowMs()), @"device": probe[@"device"], @"session": g_tkSession ?: @"",
            @"tests": [NSMutableArray array]
        } mutableCopy];
        g_tkRun = run;
        g_tkStopRun = NO;
        g_tkSkipStep = NO;
    }
    RCTKEvent(@"suite.start", @{ @"id": run[@"id"], @"suite": name });

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL changesState = ![name isEqualToString:@"conditions"];
        if (changesState) RCTKTakeSnapshot();
        if ([name isEqualToString:@"conditions"] || [name isEqualToString:@"all"]) RCTKSuiteConditions(run);
        if ([name isEqualToString:@"toggles"] || [name isEqualToString:@"all"]) RCTKSuiteToggles(run, disruptive);
        if ([name isEqualToString:@"guided"]) RCTKSuiteGuided(run);
        if ([name isEqualToString:@"differential"]) RCTKSuiteDifferential(run);
        if (changesState) {
            NSDictionary *restored = RCTKRestore();
            @synchronized (run) { run[@"restored"] = restored[@"restored"] ?: @[]; }
        }
        @synchronized (run) {
            run[@"status"] = @"done";
            run[@"finished"] = @(RCTKNowMs());
            run[@"durationMs"] = @(round([run[@"finished"] doubleValue] - [run[@"started"] doubleValue]));
        }
        NSDictionary *report = RCTKSummarize(run);
        [[NSFileManager defaultManager] createDirectoryAtPath:kRCTKReportsDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        [json writeToFile:[kRCTKReportsDir stringByAppendingPathComponent:[report[@"id"] stringByAppendingString:@".json"]] atomically:YES];
        RCTKEvent(@"suite.end", @{ @"id": report[@"id"], @"summary": report[@"summary"] });
        dispatch_semaphore_signal(done);
    });

    if (!wait) return @{ @"id": run[@"id"], @"status": @"running" };
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)));
    return RCTKSummarize(run);
}

static NSDictionary *RCTKReport(NSString *reportId) {
    NSMutableDictionary *run = g_tkRun;
    if (!reportId.length) return run ? RCTKSummarize(run) : @{ @"error": @"no runs yet" };
    // The run in progress isn't saved until it ends
    if (run && [run[@"id"] isEqual:reportId] && [run[@"status"] isEqual:@"running"]) return RCTKSummarize(run);
    NSData *data = [NSData dataWithContentsOfFile:[kRCTKReportsDir stringByAppendingPathComponent:[reportId stringByAppendingString:@".json"]]];
    id report = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return report ?: @{ @"error": [NSString stringWithFormat:@"no report '%@'", reportId] };
}

static NSDictionary *RCTKReports(void) {
    NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:kRCTKReportsDir error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *file in files) if ([file hasSuffix:@".json"]) [ids addObject:[file stringByDeletingPathExtension]];
    return @{ @"reports": ids };
}

static NSDictionary *RCTKLua(NSString *code) {
    if (!code.length) return @{ @"error": @"missing code" };
    RCTKEvent(@"testkit.lua", nil);
    __block NSDictionary *result;
    void (^evaluate)(void) = ^{ result = RCEvaluateLuaCapturing(code); };
    if ([NSThread isMainThread]) evaluate(); else dispatch_sync(dispatch_get_main_queue(), evaluate);
    return result;
}

#pragma mark - Routing

static NSDictionary *RCTKInfo(void) {
    return @{
        @"testkit": @1,
        @"session": g_tkSession ?: @"",
        @"tweakVersion": RCTKPackageVersion(),
        @"endpoints": @[@"info", @"probe", @"journal", @"journal/clear", @"mark", @"run", @"lua", @"capture", @"snapshot", @"restore",
                        @"suites", @"suite/run", @"suite/skip", @"suite/stop", @"report", @"reports"]
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
    if ([endpoint isEqualToString:@"lua"]) return RCTKLua(params[@"code"] ?: body);
    if ([endpoint isEqualToString:@"suites"]) return RCTKSuites();
    if ([endpoint isEqualToString:@"suite/run"]) {
        NSString *name = params[@"name"] ?: body;
        return RCTKRunSuite(name, [params[@"disruptive"] boolValue], [params[@"wait"] boolValue]);
    }
    if ([endpoint isEqualToString:@"suite/skip"]) { g_tkSkipStep = YES; return @{ @"skip": @YES }; }
    if ([endpoint isEqualToString:@"suite/stop"]) { g_tkStopRun = YES; return @{ @"stop": @YES }; }
    if ([endpoint isEqualToString:@"report"]) return RCTKReport(params[@"id"]);
    if ([endpoint isEqualToString:@"reports"]) return RCTKReports();
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
