// Loaded into companionfindlocallyd, which plays the sound when Ping iPhone is used on a paired Apple
// Watch. Each ping is passed to SpringBoard as the Watch Ping trigger (tap) or Watch Ping Hold trigger
// (press and hold, which also asks for the flash). When that trigger has actions, the phone skips the
// sound and flash for that ping; the Watch still gets its usual reply. Without actions, or with the
// trigger's keepDefault set, Ping iPhone works as on a stock iPhone.
//
// Every class and method is looked up by name and checked; nothing is called by address.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <os/log.h>
#import <stdatomic.h>

#define kRCWatchPingArmed "com.pizzaman.rc.watch_ping_armed" // state: 1 tap has actions, 2 hold has actions (set by SpringBoard)
#define kRCWatchPing      "com.pizzaman.rc.watch_ping"       // posted per ping: state 1 tap, 2 hold

// Sound and flash are skipped until this time (seconds since reference date)
static _Atomic double g_quietUntil;

static uint64_t RCArmedState(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID && notify_register_check(kRCWatchPingArmed, &token) != NOTIFY_STATUS_OK) return 0;
    uint64_t state = 0;
    notify_get_state(token, &state);
    return state;
}

// The ping message: field 1 a timestamp (double), field 2 the flash flag (varint), as seen on iOS 17
static BOOL RCPingWantsFlash(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length, i = 0;
    while (i < length) {
        uint64_t key = 0;
        for (int shift = 0; i < length && shift < 64; shift += 7) {
            uint8_t b = bytes[i++];
            key |= (uint64_t)(b & 0x7f) << shift;
            if (!(b & 0x80)) break;
        }
        uint64_t field = key >> 3, wire = key & 7;
        if (wire == 0) {
            uint64_t value = 0;
            for (int shift = 0; i < length && shift < 64; shift += 7) {
                uint8_t b = bytes[i++];
                value |= (uint64_t)(b & 0x7f) << shift;
                if (!(b & 0x80)) break;
            }
            if (field == 2) return value != 0;
        } else if (wire == 1) {
            i += 8;
        } else if (wire == 5) {
            i += 4;
        } else if (wire == 2) {
            uint64_t size = 0;
            for (int shift = 0; i < length && shift < 64; shift += 7) {
                uint8_t b = bytes[i++];
                size |= (uint64_t)(b & 0x7f) << shift;
                if (!(b & 0x80)) break;
            }
            if (size > length - MIN(i, length)) return NO;
            i += size;
        } else {
            return NO;
        }
    }
    return NO;
}

static void RCHandlePing(id protobuf) {
    NSData *data = [protobuf respondsToSelector:@selector(data)] ? ((id (*)(id, SEL))objc_msgSend)(protobuf, @selector(data)) : nil;
    uint64_t kind = ([data isKindOfClass:[NSData class]] && RCPingWantsFlash(data)) ? 2 : 1;
    if (RCArmedState() & kind) atomic_store(&g_quietUntil, [NSDate timeIntervalSinceReferenceDate] + 3.0);

    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) notify_register_check(kRCWatchPing, &token);
    notify_set_state(token, kind);
    notify_post(kRCWatchPing);
}

static BOOL RCQuiet(void) {
    return [NSDate timeIntervalSinceReferenceDate] < atomic_load(&g_quietUntil);
}

// Replaces a BOOL method with no arguments: returns YES (done) while quiet, otherwise runs as usual
static void RCQuietWhenArmed(Class cls, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || strcmp(method_getTypeEncoding(method) ?: "", "B16@0:8") != 0) return;
    IMP previous = method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^BOOL(id receiver) {
        if (RCQuiet()) return YES;
        return ((BOOL (*)(id, SEL))previous)(receiver, selector);
    }));
}

__attribute__((constructor)) static void RCWatchPingStart(void) {
    @autoreleasepool {
        Class remote = objc_getClass("NFMRemoteFindLocally");
        Class player = objc_getClass("NFMPlayCommands");
        SEL ping = NSSelectorFromString(@"playSound:");
        Method pingMethod = remote ? class_getInstanceMethod(remote, ping) : NULL;
        if (!pingMethod || !player || strcmp(method_getTypeEncoding(pingMethod) ?: "", "v24@0:8@16") != 0) {
            os_log(OS_LOG_DEFAULT, "[RemoteCompanion] companionfindlocallyd: Ping iPhone not found on this iOS");
            return;
        }

        // Sound and flash: skipped while quiet, before the ping is handled (it plays on its own queue)
        for (NSString *name in @[@"playFindLocallySound", @"playSoundAndFlash", @"flashLEDIfAppropriate", @"flashLights"]) {
            RCQuietWhenArmed(player, name);
        }

        IMP previous = method_getImplementation(pingMethod);
        method_setImplementation(pingMethod, imp_implementationWithBlock(^(id receiver, id protobuf) {
            @try { RCHandlePing(protobuf); } @catch (NSException *e) {}
            ((void (*)(id, SEL, id))previous)(receiver, ping, protobuf);
        }));
        os_log(OS_LOG_DEFAULT, "[RemoteCompanion] companionfindlocallyd: Ping iPhone hooked");
    }
}
