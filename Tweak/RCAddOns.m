#import "RCAddOns.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <poll.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>

// From Tweak.x
void SRLog(NSString *format, ...);
void SRLogMin(NSString *format, ...);
NSString *RCHandleCommand(NSString *cmd);
void RCShowBanner(NSString *title, NSString *subtitle, NSString *iconSymbol, NSTimeInterval hold);
void RCExecuteTrigger(NSString *triggerKey);
BOOL RCBannerEnabled(NSString *bannerId);
BOOL RCEvaluateIfCondition(NSDictionary *ifAction);

extern char **environ;

static const NSTimeInterval kRCAOExecTimeout = 10.0;
static const NSTimeInterval kRCAOMaxDelay = 5.0;
static const NSTimeInterval kRCAORecheck = 2.0;   // how often the folder is checked for changes
static const int kRCAOMaxDepth = 4;                // add-on commands running add-on commands
static const int kRCAOAPIVersion = 1;              // the add-on API this build implements ("api" in a file)

// Guarded by rcao_lock()
static NSArray<NSDictionary *> *rcao_addOns;      // offered add-ons, as validated
static NSArray<NSString *> *rcao_problems;         // "file: reason"
static NSArray<NSString *> *rcao_absent;           // names of add-ons whose app or tweak isn't installed
static NSString *rcao_signature;                   // the folder's files and modification times
static CFAbsoluteTime rcao_checkedAt;
static NSMutableArray<NSNumber *> *rcao_eventTokens;

static id rcao_lock(void) {
    static id lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static dispatch_queue_t rcao_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.saihgupr.remotecompanion.addons", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSArray<NSString *> *rcao_folders(void) {
    return @[@"/var/jb/Library/RemoteCompanion/AddOns", @"/Library/RemoteCompanion/AddOns"];
}

#pragma mark - Templates

// Replaces each {name} with vars[name]. nil when a name has no value (the step is skipped).
static NSString *rcao_fill(NSString *template, NSDictionary<NSString *, NSString *> *vars) {
    if (![template isKindOfClass:[NSString class]]) return nil;
    NSMutableString *out = [NSMutableString string];
    NSScanner *scanner = [NSScanner scannerWithString:template];
    scanner.charactersToBeSkipped = nil;
    while (!scanner.isAtEnd) {
        NSString *text = nil;
        if ([scanner scanUpToString:@"{" intoString:&text]) [out appendString:text];
        if (scanner.isAtEnd) break;
        scanner.scanLocation += 1;
        NSString *name = nil;
        if (![scanner scanUpToString:@"}" intoString:&name] || scanner.isAtEnd) {
            // No closing brace: kept as written
            [out appendFormat:@"{%@", name ?: @""];
            break;
        }
        scanner.scanLocation += 1;
        NSString *value = vars[name];
        if (!value) return nil;
        [out appendString:value];
    }
    return out;
}

#pragma mark - Loading

static BOOL rcao_is_string(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0;
}

static BOOL rcao_word_list(NSString *text) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-. "];
    return text.length && [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound
        && ![text hasPrefix:@" "] && ![text hasSuffix:@" "] && [text rangeOfString:@"  "].location == NSNotFound;
}

// Why a step is invalid, or nil
static NSString *rcao_check_step(id step) {
    if (![step isKindOfClass:[NSDictionary class]]) return @"a step isn't an object";
    NSDictionary *s = step;
    NSArray *kinds = @[@"notify", @"defaults", @"exec", @"url", @"command", @"delay"];
    NSArray *modifiers = @[@"state", @"root", @"as", @"ifOptions", @"if"];
    NSString *kind = nil;
    for (NSString *key in s) {
        if ([kinds containsObject:key]) {
            if (kind) return [NSString stringWithFormat:@"a step has both %@ and %@", kind, key];
            kind = key;
        } else if (![modifiers containsObject:key]) {
            return [NSString stringWithFormat:@"unknown step key '%@'", key];
        }
    }
    if (!kind) return @"a step has no kind";
    if (s[@"if"] && (![s[@"if"] isKindOfClass:[NSDictionary class]] || !rcao_is_string(s[@"if"][@"var"]) || (!s[@"if"][@"is"] && !s[@"if"][@"isNot"] && ![s[@"if"][@"unset"] boolValue]))) {
        return @"if needs var and is, isNot or unset";
    }
    if (s[@"state"] && ![kind isEqualToString:@"notify"]) return @"state only goes with notify";
    if (s[@"root"] && ![kind isEqualToString:@"exec"]) return @"root only goes with exec";
    if (s[@"as"] && (![kind isEqualToString:@"exec"] || !rcao_is_string(s[@"as"]))) return @"as (a name for the output) only goes with exec";
    id value = s[kind];
    if ([kind isEqualToString:@"exec"]) {
        if (![value isKindOfClass:[NSArray class]] || [value count] == 0) return @"exec needs a list";
        for (id arg in value) if (![arg isKindOfClass:[NSString class]]) return @"exec arguments must be strings";
        if (![[value firstObject] hasPrefix:@"/"]) return @"exec needs a full path";
    } else if ([kind isEqualToString:@"defaults"]) {
        if (![value isKindOfClass:[NSDictionary class]] || !rcao_is_string(value[@"domain"]) || !rcao_is_string(value[@"key"])) return @"defaults needs domain and key";
        if ([value[@"read"] boolValue] && !rcao_is_string(value[@"as"])) return @"defaults read needs as";
        if (![value[@"toggle"] boolValue] && ![value[@"read"] boolValue] && !value[@"value"]) return @"defaults needs value, toggle or read";
    } else if ([kind isEqualToString:@"delay"]) {
        if (![value isKindOfClass:[NSNumber class]]) return @"delay needs a number";
    } else if (!rcao_is_string(value)) {
        return [NSString stringWithFormat:@"%@ needs text", kind];
    }
    return nil;
}

// A word of letters, digits, - and . (a choice's word, a trigger's id)
static BOOL rcao_is_word(id value) {
    if (!rcao_is_string(value)) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-."];
    return [(NSString *)value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

// An option id: lowercase letters, digits and _, starting with a letter; not a name the runtime fills in
static BOOL rcao_is_option_id(id value) {
    if (!rcao_is_string(value)) return NO;
    NSString *text = value;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_"];
    if ([text rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    if (![[NSCharacterSet lowercaseLetterCharacterSet] characterIsMember:[text characterAtIndex:0]]) return NO;
    if ([text isEqualToString:@"input"] || [text isEqualToString:@"state"]) return NO;
    if ([text hasPrefix:@"word"] && text.length > 4 && [[text substringFromIndex:4] rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet].invertedSet].location == NSNotFound) return NO;
    return YES;
}

// Why a banner is invalid, or nil
static NSString *rcao_check_banner(id banner, NSString *where) {
    if (![banner isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"%@: banner isn't an object", where];
    for (NSString *key in @[@"title", @"subtitle", @"icon", @"await"]) {
        if (banner[key] && !rcao_is_string(banner[key])) return [NSString stringWithFormat:@"%@: banner %@ must be text", where, key];
    }
    for (NSString *key in @[@"hold", @"timeout"]) {
        if (banner[key] && ![banner[key] isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"%@: banner %@ must be a number", where, key];
    }
    if (banner[@"states"]) {
        if (![banner[@"states"] isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"%@: banner states must be an object", where];
        for (NSString *key in banner[@"states"]) if (![banner[@"states"][key] isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"%@: banner states must map to text", where];
    }
    return nil;
}

// Why an add-on is invalid, or nil
static NSString *rcao_check_addOn(NSDictionary *addOn) {
    NSString *pid = addOn[@"id"];
    if (!rcao_is_string(pid) || !rcao_word_list(pid) || [pid rangeOfString:@" "].location != NSNotFound || [pid containsString:@"."]) {
        return @"id must be lowercase letters, digits and -";
    }
    if ([pid isEqualToString:@"addons"]) return [NSString stringWithFormat:@"id '%@' is reserved", pid];
    if (addOn[@"api"]) {
        if (![addOn[@"api"] isKindOfClass:[NSNumber class]] || [addOn[@"api"] integerValue] < 1) return @"api must be a whole number from 1";
        if ([addOn[@"api"] integerValue] > kRCAOAPIVersion) return [NSString stringWithFormat:@"needs add-on API %@; this RemoteCompanion has %d", addOn[@"api"], kRCAOAPIVersion];
    }
    if (!rcao_is_string(addOn[@"name"])) return @"name is missing";
    if (addOn[@"icon"] && !rcao_is_string(addOn[@"icon"])) return @"icon must be text";
    if (addOn[@"requires"]) {
        if (![addOn[@"requires"] isKindOfClass:[NSArray class]]) return @"requires must be a list of paths";
        for (id path in addOn[@"requires"]) if (!rcao_is_string(path)) return @"requires must be a list of paths";
    }
    NSArray *actions = addOn[@"actions"];
    if (![actions isKindOfClass:[NSArray class]] || actions.count == 0) return @"actions are missing";
    NSMutableSet *commands = [NSMutableSet set];
    for (NSDictionary *action in actions) {
        if (![action isKindOfClass:[NSDictionary class]]) return @"an action isn't an object";
        NSString *command = action[@"command"];
        if (!rcao_is_string(command) || !rcao_word_list(command)) return @"an action's command must be lowercase words";
        if ([commands containsObject:command]) return [NSString stringWithFormat:@"two actions are '%@'", command];
        [commands addObject:command];
        if (!rcao_is_string(action[@"name"])) return [NSString stringWithFormat:@"action '%@' has no name", command];
        if (action[@"icon"] && !rcao_is_string(action[@"icon"])) return [NSString stringWithFormat:@"action '%@': icon must be text", command];
        NSArray *run = action[@"run"];
        if (![run isKindOfClass:[NSArray class]] || run.count == 0) return [NSString stringWithFormat:@"action '%@' has no steps", command];
        for (id step in run) {
            NSString *problem = rcao_check_step(step);
            if (problem) return [NSString stringWithFormat:@"action '%@': %@", command, problem];
        }
        if (action[@"banner"]) {
            NSString *problem = rcao_check_banner(action[@"banner"], [NSString stringWithFormat:@"action '%@'", command]);
            if (problem) return problem;
        }
        if (action[@"input"]) {
            NSDictionary *input = action[@"input"];
            if (![input isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"action '%@': input isn't an object", command];
            for (NSString *key in @[@"title", @"placeholder"]) if (input[key] && ![input[key] isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"action '%@': input %@ must be text", command, key];
        }
        NSMutableSet *optionIds = [NSMutableSet set], *words = [NSMutableSet set];
        NSArray *options = action[@"options"] ?: @[];
        if (![options isKindOfClass:[NSArray class]]) return [NSString stringWithFormat:@"action '%@': options must be a list", command];
        for (NSDictionary *option in options) {
            if (![option isKindOfClass:[NSDictionary class]] || ![option[@"choices"] isKindOfClass:[NSArray class]] || [option[@"choices"] count] == 0) {
                return [NSString stringWithFormat:@"action '%@' has an option without id or choices", command];
            }
            if (!rcao_is_option_id(option[@"id"])) return [NSString stringWithFormat:@"action '%@': option id '%@' must be lowercase letters, digits and _ (not input, state or wordN)", command, option[@"id"]];
            if ([optionIds containsObject:option[@"id"]]) return [NSString stringWithFormat:@"action '%@': two options are '%@'", command, option[@"id"]];
            [optionIds addObject:option[@"id"]];
            for (NSDictionary *choice in option[@"choices"]) {
                if (![choice isKindOfClass:[NSDictionary class]] || !rcao_is_string(choice[@"word"])) {
                    return [NSString stringWithFormat:@"action '%@' has a choice without a word", command];
                }
                if (!rcao_is_word(choice[@"word"])) return [NSString stringWithFormat:@"action '%@': choice word '%@' must be one lowercase word", command, choice[@"word"]];
                if ([words containsObject:choice[@"word"]]) return [NSString stringWithFormat:@"action '%@': the word '%@' is used by two choices", command, choice[@"word"]];
                [words addObject:choice[@"word"]];
                if (choice[@"label"] && ![choice[@"label"] isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"action '%@': a choice's label must be text", command];
            }
        }
        for (NSDictionary *option in options) {
            NSDictionary *skipWhen = option[@"skipWhen"];
            if (!skipWhen) continue;
            if (![skipWhen isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"action '%@': skipWhen must be an object", command];
            for (NSString *other in skipWhen) {
                if (![optionIds containsObject:other] || [other isEqualToString:option[@"id"]]) return [NSString stringWithFormat:@"action '%@': skipWhen names '%@', which isn't another option", command, other];
            }
        }
    }
    for (NSDictionary *condition in addOn[@"conditions"] ?: @[]) {
        if (![condition isKindOfClass:[NSDictionary class]] || !rcao_is_string(condition[@"id"]) || !rcao_is_string(condition[@"name"])) return @"a condition needs id and name";
        if (condition[@"icon"] && !rcao_is_string(condition[@"icon"])) return [NSString stringWithFormat:@"condition '%@': icon must be text", condition[@"id"]];
        if (![@[@"number", @"choice"] containsObject:condition[@"type"] ?: @""]) return [NSString stringWithFormat:@"condition '%@': type must be number or choice", condition[@"id"]];
        if (!condition[@"exec"] && !rcao_is_string(condition[@"notifyState"])) return [NSString stringWithFormat:@"condition '%@' needs exec or notifyState", condition[@"id"]];
        if (condition[@"exec"] && rcao_check_step(@{@"exec": condition[@"exec"]})) return [NSString stringWithFormat:@"condition '%@': exec needs a list starting with a full path", condition[@"id"]];
        if ([condition[@"type"] isEqualToString:@"choice"]) {
            NSDictionary *choices = condition[@"choices"];
            if (![choices isKindOfClass:[NSDictionary class]] || choices.count == 0) return [NSString stringWithFormat:@"condition '%@': a choice needs choices (value: label)", condition[@"id"]];
            for (NSString *key in choices) if (![choices[key] isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"condition '%@': choices must map to text", condition[@"id"]];
        }
    }
    NSMutableSet *triggerIds = [NSMutableSet set];
    for (NSDictionary *event in addOn[@"events"] ?: @[]) {
        if (![event isKindOfClass:[NSDictionary class]] || !rcao_is_string(event[@"notify"])) return @"an event needs notify";
        BOOL hasBanner = event[@"banner"] != nil;
        NSDictionary *trigger = event[@"trigger"];
        if (hasBanner) {
            NSString *problem = rcao_check_banner(event[@"banner"], [NSString stringWithFormat:@"event '%@'", event[@"notify"]]);
            if (problem) return problem;
        }
        if (trigger) {
            if (![trigger isKindOfClass:[NSDictionary class]] || !rcao_is_string(trigger[@"id"]) || !rcao_is_string(trigger[@"name"])) return @"an event's trigger needs id and name";
            if (trigger[@"icon"] && !rcao_is_string(trigger[@"icon"])) return @"a trigger's icon must be text";
            if (!rcao_is_word(trigger[@"id"])) return [NSString stringWithFormat:@"trigger id '%@' must be lowercase letters, digits, - and .", trigger[@"id"]];
            if ([triggerIds containsObject:trigger[@"id"]]) return [NSString stringWithFormat:@"two triggers are '%@'", trigger[@"id"]];
            [triggerIds addObject:trigger[@"id"]];
            id states = trigger[@"states"];
            if (states && ![states isEqual:@NO] && ![states isKindOfClass:[NSDictionary class]]) return @"a trigger's states must be an object or false";
        }
        if (!hasBanner && !trigger) return @"an event needs a banner or a trigger";
        if (event[@"action"] && (!rcao_is_string(event[@"action"]) || ![commands containsObject:event[@"action"]])) return [NSString stringWithFormat:@"event '%@': action '%@' isn't one of the actions", event[@"notify"], event[@"action"]];
    }
    return nil;
}

// Keys that mean nothing here (ignored when loading, listed by "add-ons validate")
static NSArray<NSString *> *rcao_icons(NSDictionary *addOn);
static NSArray<NSString *> *rcao_warnings(NSDictionary *addOn, NSString *folder) {
    NSMutableArray *warnings = [NSMutableArray array];
    void (^check)(NSDictionary *, NSArray *, NSString *) = ^(NSDictionary *object, NSArray *known, NSString *where) {
        if (![object isKindOfClass:[NSDictionary class]]) return;
        for (NSString *key in object) if (![known containsObject:key]) [warnings addObject:[NSString stringWithFormat:@"%@: unknown key '%@' is ignored", where, key]];
    };
    check(addOn, @[@"$schema", @"api", @"id", @"name", @"icon", @"requires", @"actions", @"conditions", @"events"], @"add-on");
    for (NSDictionary *action in addOn[@"actions"]) {
        NSString *where = [NSString stringWithFormat:@"action '%@'", action[@"command"]];
        check(action, @[@"command", @"name", @"icon", @"options", @"input", @"run", @"banner"], where);
        check(action[@"banner"], @[@"title", @"subtitle", @"icon", @"hold", @"await", @"states", @"timeout"], [where stringByAppendingString:@" banner"]);
        check(action[@"input"], @[@"title", @"placeholder", @"number"], [where stringByAppendingString:@" input"]);
        for (NSDictionary *option in action[@"options"]) {
            check(option, @[@"id", @"title", @"choices", @"skipWhen"], [where stringByAppendingString:@" option"]);
            for (NSDictionary *choice in option[@"choices"]) check(choice, @[@"word", @"label", @"value"], [where stringByAppendingString:@" choice"]);
        }
    }
    for (NSDictionary *condition in addOn[@"conditions"]) check(condition, @[@"id", @"name", @"icon", @"type", @"exec", @"root", @"notifyState", @"choices"], @"condition");
    for (NSDictionary *event in addOn[@"events"]) {
        check(event, @[@"notify", @"action", @"banner", @"trigger"], @"event");
        check(event[@"banner"], @[@"title", @"subtitle", @"icon", @"hold", @"states"], @"event banner");
        check(event[@"trigger"], @[@"id", @"name", @"icon", @"states"], @"event trigger");
    }
    for (NSString *icon in rcao_icons(addOn)) {
        if (![@[@"png", @"jpg", @"jpeg"] containsObject:icon.pathExtension.lowercaseString]) continue;
        NSString *path = [icon hasPrefix:@"/"] ? icon : [folder stringByAppendingPathComponent:icon];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) [warnings addObject:[NSString stringWithFormat:@"icon: no image at %@", path]];
        else if (data.length > 512 * 1024) [warnings addObject:[NSString stringWithFormat:@"icon: %@ is over 512 KB and isn't used", icon]];
    }
    return warnings;
}

static BOOL rcao_installed(NSDictionary *addOn) {
    NSArray *paths = addOn[@"requires"];
    if (![paths isKindOfClass:[NSArray class]] || paths.count == 0) return YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if (![path isKindOfClass:[NSString class]]) continue;
        if ([fm fileExistsAtPath:path]) return YES;
        if (![path hasPrefix:@"/var/"] && [fm fileExistsAtPath:[@"/var/jb" stringByAppendingString:path]]) return YES;
    }
    return NO;
}

// The folder's .json files with their modification times: changes when one is added, removed or edited
static NSString *rcao_folder_signature(NSArray<NSString *> **files) {
    NSMutableString *signature = [NSMutableString string];
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *folder in rcao_folders()) {
        NSArray *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *name in names) {
            if (![name.pathExtension isEqualToString:@"json"]) continue;
            NSString *path = [folder stringByAppendingPathComponent:name];
            struct stat st;
            if (stat(path.fileSystemRepresentation, &st) != 0) continue;
            [signature appendFormat:@"%@:%ld.%ld;", path, (long)st.st_mtimespec.tv_sec, (long)st.st_mtimespec.tv_nsec];
            [found addObject:path];
        }
    }
    if (files) *files = found;
    return signature;
}

static void rcao_register_events(NSArray<NSDictionary *> *addOns);

// Reads the folder again if it changed (at most every couple of seconds unless forced)
static void rcao_load(BOOL force) {
    @synchronized (rcao_lock()) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!force && rcao_addOns && now - rcao_checkedAt < kRCAORecheck) return;
        rcao_checkedAt = now;
        NSArray<NSString *> *files = nil;
        NSString *signature = rcao_folder_signature(&files);
        if (!force && rcao_addOns && [signature isEqualToString:rcao_signature]) return;
        rcao_signature = signature;

        NSMutableArray *addOns = [NSMutableArray array];
        NSMutableArray *problems = [NSMutableArray array];
        NSMutableArray *absent = [NSMutableArray array];
        NSMutableSet *ids = [NSMutableSet set];
        for (NSString *path in files) {
            NSData *data = [NSData dataWithContentsOfFile:path];
            NSError *error = nil;
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
            NSString *problem = nil;
            if (![json isKindOfClass:[NSDictionary class]]) problem = error ? @"not valid JSON" : @"not a JSON object";
            else problem = rcao_check_addOn(json);
            if (!problem && [ids containsObject:json[@"id"]]) problem = [NSString stringWithFormat:@"another add-on already uses id '%@'", json[@"id"]];
            if (problem) {
                [problems addObject:[NSString stringWithFormat:@"%@: %@", path.lastPathComponent, problem]];
                continue;
            }
            [ids addObject:json[@"id"]];
            NSMutableDictionary *loaded = [json mutableCopy];
            loaded[@"_folder"] = path.stringByDeletingLastPathComponent;   // where the file is (its icon image sits beside it)
            if (rcao_installed(json)) [addOns addObject:loaded];
            else [absent addObject:json[@"name"]];
        }
        rcao_addOns = addOns;
        rcao_problems = problems;
        rcao_absent = absent;
        SRLog(@"[AddOns] Loaded %lu (%lu not installed, %lu with problems)", (unsigned long)addOns.count, (unsigned long)absent.count, (unsigned long)problems.count);
        for (NSString *problem in problems) SRLogMin(@"[AddOns] %@", problem);
        rcao_register_events(addOns);
    }
}

static NSArray<NSDictionary *> *rcao_current(void) {
    rcao_load(NO);
    @synchronized (rcao_lock()) { return rcao_addOns; }
}

#pragma mark - Running steps

// SpringBoard's environment with the jailbreak's tools on PATH (as RemoteCompanion's exec has)
static char **rcao_environment(void) {
    static char **env;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *vars = [NSMutableArray array];
        for (char **e = environ; *e; e++) {
            NSString *var = [NSString stringWithUTF8String:*e];
            if (var && ![var hasPrefix:@"PATH="]) [vars addObject:var];
        }
        [vars addObject:@"PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin"];
        env = calloc(vars.count + 1, sizeof(char *));
        for (NSUInteger i = 0; i < vars.count; i++) env[i] = strdup(vars[i].UTF8String);
    });
    return env;
}

static NSString *rcao_rc_root(void) {
    return access("/var/jb/usr/bin/rc-root", X_OK) == 0 ? @"/var/jb/usr/bin/rc-root" : @"/usr/bin/rc-root";
}

// Runs a program directly (no shell) and returns its output (stdout and stderr), or nil if it
// couldn't start. Killed after kRCAOExecTimeout.
static NSString *rcao_exec(NSArray<NSString *> *arguments, BOOL root, int *exitStatus) {
    NSArray<NSString *> *argv = root ? [@[rcao_rc_root(), @"exec"] arrayByAddingObjectsFromArray:arguments] : arguments;
    int fds[2];
    if (pipe(fds) != 0) return nil;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1);
    posix_spawn_file_actions_adddup2(&actions, fds[1], 2);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
    char **cargv = calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = (char *)argv[i].UTF8String;
    pid_t pid = 0;
    int err = posix_spawn(&pid, cargv[0], &actions, &attr, cargv, rcao_environment());
    free(cargv);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(fds[1]);
    if (err != 0) {
        close(fds[0]);
        SRLogMin(@"[AddOns] Could not run %@: %s", argv.firstObject, strerror(err));
        return nil;
    }
    NSMutableData *output = [NSMutableData data];
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + kRCAOExecTimeout;
    BOOL timedOut = NO;
    while (1) {
        int left = (int)((deadline - CFAbsoluteTimeGetCurrent()) * 1000);
        if (left <= 0) { timedOut = YES; break; }
        struct pollfd p = { .fd = fds[0], .events = POLLIN };
        int ready = poll(&p, 1, left);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) { timedOut = ready == 0; break; }
        char buffer[4096];
        ssize_t n = read(fds[0], buffer, sizeof(buffer));
        if (n <= 0) break;
        if (output.length < 65536) [output appendBytes:buffer length:(NSUInteger)n];
    }
    close(fds[0]);
    if (timedOut) {
        kill(pid, SIGKILL);
        SRLogMin(@"[AddOns] %@ took longer than %.0f s and was stopped", argv.firstObject, kRCAOExecTimeout);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (exitStatus) *exitStatus = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
}

static id rcao_typed(NSString *value, NSString *type) {
    if ([type isEqualToString:@"bool"]) {
        NSString *v = value.lowercaseString;
        return @([v isEqualToString:@"1"] || [v isEqualToString:@"true"] || [v isEqualToString:@"yes"] || [v isEqualToString:@"on"]);
    }
    if ([type isEqualToString:@"int"]) return @(value.integerValue);
    return value;
}

// A boolean's label: labels {"true": ..., "false": ...}, default On/Off
static NSString *rcao_bool_label(NSDictionary *spec, BOOL value) {
    NSDictionary *labels = [spec[@"labels"] isKindOfClass:[NSDictionary class]] ? spec[@"labels"] : nil;
    NSString *label = labels[value ? @"true" : @"false"];
    return [label isKindOfClass:[NSString class]] ? label : (value ? @"On" : @"Off");
}

// read: saves the value in vars[as] (a boolean as its label). A toggle with "as" saves its new value.
static void rcao_write_default(NSDictionary *spec, NSMutableDictionary *vars) {
    NSString *domain = spec[@"domain"], *key = spec[@"key"];
    BOOL springboard = [domain isEqualToString:@"com.apple.springboard"];
    NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
    if ([spec[@"read"] boolValue]) {
        id value = springboard ? [standard objectForKey:key]
                               : CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain));
        if (!value || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) vars[spec[@"as"]] = rcao_bool_label(spec, [value boolValue]);
        else vars[spec[@"as"]] = [value description];
        return;
    }
    if ([spec[@"toggle"] boolValue]) {
        BOOL current = springboard ? [standard boolForKey:key]
                                   : CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain, NULL);
        if (springboard) [standard setBool:!current forKey:key];
        else CFPreferencesSetAppValue((__bridge CFStringRef)key, current ? kCFBooleanFalse : kCFBooleanTrue, (__bridge CFStringRef)domain);
        if (rcao_is_string(spec[@"as"])) vars[spec[@"as"]] = rcao_bool_label(spec, !current);
    } else {
        id raw = spec[@"value"];
        NSString *text = [raw isKindOfClass:[NSString class]] ? rcao_fill(raw, vars) : [raw description];
        id value = [raw isKindOfClass:[NSNumber class]] && !spec[@"type"] ? raw : rcao_typed(text, spec[@"type"]);
        if (springboard) [standard setObject:value forKey:key];
        else CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)domain);
    }
    if (!springboard) CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
}

// Whether a step's text values can all be filled in (an option left as Keep Current skips it)
static BOOL rcao_step_fillable(NSDictionary *step, NSDictionary *vars) {
    for (NSString *key in @[@"notify", @"url", @"command"]) {
        if (step[key] && !rcao_fill(step[key], vars)) return NO;
    }
    for (NSString *arg in step[@"exec"] ?: @[]) if (!rcao_fill(arg, vars)) return NO;
    id value = step[@"defaults"][@"value"];
    if ([value isKindOfClass:[NSString class]] && !rcao_fill(value, vars)) return NO;
    return YES;
}

static NSString *rcao_run_steps(NSArray<NSDictionary *> *steps, NSMutableDictionary *vars, BOOL optionsChosen) {
    NSMutableString *output = [NSMutableString string];
    for (NSDictionary *step in steps) {
        if ([step[@"ifOptions"] boolValue] && !optionsChosen) continue;
        NSDictionary *condition = step[@"if"];
        if (condition) {
            NSString *value = vars[condition[@"var"]];
            if ([condition[@"unset"] boolValue] && value) continue;
            if (condition[@"is"] && ![value isEqualToString:[condition[@"is"] description]]) continue;
            if (condition[@"isNot"] && [value isEqualToString:[condition[@"isNot"] description]]) continue;
        }
        if (!rcao_step_fillable(step, vars)) continue;
        if (step[@"notify"]) {
            NSString *name = rcao_fill(step[@"notify"], vars);
            if (step[@"state"]) {
                // The state lasts only while someone is registered for the name, so the
                // registration is kept (one per name)
                static NSMutableDictionary<NSString *, NSNumber *> *tokens;
                @synchronized (rcao_lock()) {
                    if (!tokens) tokens = [NSMutableDictionary dictionary];
                    int token = tokens[name].intValue;
                    if (!tokens[name] && notify_register_check(name.UTF8String, &token) == NOTIFY_STATUS_OK) tokens[name] = @(token);
                    if (tokens[name]) notify_set_state(token, [step[@"state"] unsignedLongLongValue]);
                }
            }
            notify_post(name.UTF8String);
        } else if (step[@"defaults"]) {
            rcao_write_default(step[@"defaults"], vars);
        } else if (step[@"exec"]) {
            NSMutableArray *args = [NSMutableArray array];
            for (NSString *arg in step[@"exec"]) [args addObject:rcao_fill(arg, vars)];
            int status = 0;
            NSString *result = rcao_exec(args, [step[@"root"] boolValue], &status);
            if (!result) {
                [output appendFormat:@"Error: Could not run %@\n", args.firstObject];
            } else if (rcao_is_string(step[@"as"])) {
                // Kept as a variable for the steps after it and the banner (lines joined), not added to the reply
                NSMutableArray *lines = [NSMutableArray array];
                for (NSString *line in [result componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length) [lines addObject:trimmed];
                }
                if (lines.count) vars[step[@"as"]] = [lines componentsJoinedByString:@" · "];
            } else {
                [output appendString:result];
            }
        } else if (step[@"url"]) {
            NSURL *url = [NSURL URLWithString:rcao_fill(step[@"url"], vars)];
            if (url) dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            });
        } else if (step[@"command"]) {
            NSString *result = RCHandleCommand(rcao_fill(step[@"command"], vars));
            if (result.length) [output appendString:result];
        } else if (step[@"delay"]) {
            double seconds = MIN(MAX([step[@"delay"] doubleValue], 0), kRCAOMaxDelay);
            usleep((useconds_t)(seconds * 1000000));
        }
    }
    return output;
}

#pragma mark - Banners

// The text for a notification's state: states[state] when there's a map, else the number.
// nil when the map has no entry (no banner).
static NSString *rcao_state_text(NSDictionary *banner, uint64_t state) {
    NSDictionary *states = banner[@"states"];
    NSString *key = [NSString stringWithFormat:@"%llu", state];
    if ([states isKindOfClass:[NSDictionary class]]) return [states[key] isKindOfClass:[NSString class]] ? states[key] : nil;
    return key;
}

static void rcao_show_state_banner(NSDictionary *banner, NSString *title, NSString *icon, uint64_t state, NSDictionary *vars) {
    NSString *text = rcao_state_text(banner, state);
    if (!text) return;
    NSMutableDictionary *withState = [vars mutableCopy] ?: [NSMutableDictionary dictionary];
    withState[@"state"] = text;
    NSString *subtitle = banner[@"subtitle"] ? rcao_fill(banner[@"subtitle"], withState) : text;
    if (subtitle) RCShowBanner(title, subtitle, icon, [banner[@"hold"] doubleValue] ?: 2.0);
}

// Waits for the notification in banner.await and shows the text for its state, or nothing
// after the timeout. Armed before the steps run, so a quick reply isn't missed.
static void rcao_await_banner(NSDictionary *banner, NSString *title, NSString *icon, NSDictionary *vars) {
    NSString *name = rcao_fill(banner[@"await"], vars);
    if (!name) return;
    double timeout = MIN(MAX([banner[@"timeout"] doubleValue] ?: 8.0, 1.0), 30.0);
    dispatch_queue_t queue = rcao_queue();
    __block int token = NOTIFY_TOKEN_INVALID;
    __block BOOL finished = NO;
    if (notify_register_dispatch(name.UTF8String, &token, queue, ^(int t) {
        if (finished) return;
        finished = YES;
        uint64_t state = 0;
        notify_get_state(t, &state);
        notify_cancel(t);
        rcao_show_state_banner(banner, title, icon, state, vars);
    }) != NOTIFY_STATUS_OK) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), queue, ^{
        if (finished) return;
        finished = YES;
        notify_cancel(token);
    });
}

static NSString *rcao_banner_id(NSDictionary *addOn, NSString *command) {
    return [NSString stringWithFormat:@"%@ %@", addOn[@"id"], command];
}

static NSDictionary *rcao_action_named(NSDictionary *addOn, NSString *command) {
    for (NSDictionary *action in addOn[@"actions"]) if ([action[@"command"] isEqualToString:command]) return action;
    return nil;
}

// Banners for notifications an add-on's tweak posts by itself
static void rcao_register_events(NSArray<NSDictionary *> *addOns) {
    if (!rcao_eventTokens) rcao_eventTokens = [NSMutableArray array];
    for (NSNumber *token in rcao_eventTokens) notify_cancel(token.intValue);
    [rcao_eventTokens removeAllObjects];
    for (NSDictionary *addOn in addOns) {
        for (NSDictionary *event in addOn[@"events"] ?: @[]) {
            NSDictionary *banner = [event[@"banner"] isKindOfClass:[NSDictionary class]] ? event[@"banner"] : nil;
            NSDictionary *trigger = event[@"trigger"];
            // The trigger's key (RCAddOnCatalog builds the same ones): any state, and each state
            NSString *triggerKey = trigger ? [NSString stringWithFormat:@"addon_%@_%@", addOn[@"id"], trigger[@"id"]] : nil;
            NSString *actionCommand = event[@"action"];
            NSDictionary *action = rcao_is_string(actionCommand) ? rcao_action_named(addOn, actionCommand) : nil;
            NSString *title = banner[@"title"] ?: addOn[@"name"];
            NSString *icon = banner[@"icon"] ?: action[@"icon"];
            int token = NOTIFY_TOKEN_INVALID;
            notify_register_dispatch([event[@"notify"] UTF8String], &token, rcao_queue(), ^(int t) {
                uint64_t state = 0;
                notify_get_state(t, &state);
                if (triggerKey) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        RCExecuteTrigger(triggerKey);
                        RCExecuteTrigger([NSString stringWithFormat:@"%@_%llu", triggerKey, state]);
                    });
                }
                // An event tied to an action shares that action's switch in Settings > Banners
                if (!banner || (action && !RCBannerEnabled(rcao_banner_id(addOn, actionCommand)))) return;
                rcao_show_state_banner(banner, title, icon, state, @{});
            });
            if (token != NOTIFY_TOKEN_INVALID) [rcao_eventTokens addObject:@(token)];
        }
    }
}

#pragma mark - Commands

static NSString *rcao_usage(NSDictionary *addOn) {
    NSMutableString *out = [NSMutableString stringWithFormat:@"%@:\n", addOn[@"name"]];
    for (NSDictionary *action in addOn[@"actions"]) {
        NSMutableString *line = [NSMutableString stringWithFormat:@"%@ %@", addOn[@"id"], action[@"command"]];
        for (NSDictionary *option in action[@"options"] ?: @[]) {
            NSMutableArray *words = [NSMutableArray array];
            for (NSDictionary *choice in option[@"choices"]) [words addObject:choice[@"word"]];
            [line appendFormat:@" [%@]", [words componentsJoinedByString:@"|"]];
        }
        if (action[@"input"]) [line appendFormat:@" <%@>", action[@"input"][@"title"] ?: @"text"];
        [out appendFormat:@"  %@\n", line];
    }
    return out;
}

static NSString *rcao_list(void) {
    NSArray *addOns, *problems, *absent;
    @synchronized (rcao_lock()) {
        addOns = rcao_addOns;
        problems = rcao_problems;
        absent = rcao_absent;
    }
    NSMutableString *out = [NSMutableString string];
    if (addOns.count == 0 && absent.count == 0 && problems.count == 0) return @"No add-ons\n";
    for (NSDictionary *addOn in addOns) {
        [out appendFormat:@"%@ (%@): %lu action%@\n", addOn[@"name"], addOn[@"id"], (unsigned long)[addOn[@"actions"] count], [addOn[@"actions"] count] == 1 ? @"" : @"s"];
    }
    for (NSString *name in absent) [out appendFormat:@"%@: not installed\n", name];
    for (NSString *problem in problems) [out appendFormat:@"Problem: %@\n", problem];
    return out;
}

static NSString *rcao_run_action(NSDictionary *addOn, NSDictionary *action, NSArray<NSString *> *words) {
    NSMutableDictionary<NSString *, NSString *> *vars = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *rest = [NSMutableArray array];
    BOOL optionsChosen = NO;
    for (NSString *word in words) {
        BOOL matched = NO;
        for (NSDictionary *option in action[@"options"] ?: @[]) {
            for (NSDictionary *choice in option[@"choices"]) {
                if ([[choice[@"word"] lowercaseString] isEqualToString:word.lowercaseString]) {
                    id value = choice[@"value"] ?: choice[@"word"];
                    vars[option[@"id"]] = [value description];
                    matched = optionsChosen = YES;
                    break;
                }
            }
            if (matched) break;
        }
        if (!matched) [rest addObject:word];
    }
    for (NSUInteger i = 0; i < rest.count; i++) vars[[NSString stringWithFormat:@"word%lu", (unsigned long)i + 1]] = rest[i];
    if (rest.count) vars[@"input"] = [rest componentsJoinedByString:@" "];

    NSDictionary *banner = [action[@"banner"] isKindOfClass:[NSDictionary class]] ? action[@"banner"] : nil;
    BOOL showBanner = banner && RCBannerEnabled(rcao_banner_id(addOn, action[@"command"]));
    NSString *title = banner[@"title"] ?: addOn[@"name"];
    NSString *icon = banner[@"icon"] ?: action[@"icon"];
    if (showBanner && banner[@"await"]) rcao_await_banner(banner, title, icon, vars);

    SRLog(@"[AddOns] %@ %@ %@", addOn[@"id"], action[@"command"], vars);
    NSString *output = rcao_run_steps(action[@"run"], vars, optionsChosen);

    if (showBanner && !banner[@"await"]) {
        NSString *subtitle = banner[@"subtitle"] ? rcao_fill(banner[@"subtitle"], vars) : nil;
        // The title can use variables too (an unset one falls back to the add-on's name)
        NSString *filledTitle = banner[@"title"] ? rcao_fill(banner[@"title"], vars) : nil;
        RCShowBanner(filledTitle ?: title, subtitle ?: action[@"name"], icon, [banner[@"hold"] doubleValue] ?: 2.0);
    }
    if (output.length) return [output hasSuffix:@"\n"] ? output : [output stringByAppendingString:@"\n"];
    return [NSString stringWithFormat:@"%@: %@\n", addOn[@"name"], action[@"name"]];
}

static NSArray<NSString *> *rcao_words(NSString *cmd) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *w in [cmd componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (w.length) [words addObject:w];
    }
    return words;
}

// The action whose command words follow the add-on id (the longest one); *length: its word count
static NSDictionary *rcao_match_action(NSDictionary *addOn, NSArray<NSString *> *words, NSUInteger *length) {
    NSDictionary *match = nil;
    NSUInteger matchLength = 0;
    for (NSDictionary *action in addOn[@"actions"]) {
        NSArray *commandWords = [action[@"command"] componentsSeparatedByString:@" "];
        if (commandWords.count > words.count - 1 || commandWords.count <= matchLength) continue;
        BOOL same = YES;
        for (NSUInteger i = 0; i < commandWords.count && same; i++) same = [words[i + 1].lowercaseString isEqualToString:commandWords[i]];
        if (same) { match = action; matchLength = commandWords.count; }
    }
    if (length) *length = matchLength;
    return match;
}

static NSDictionary *rcao_addOn_for(NSArray<NSString *> *words) {
    if (words.count == 0) return nil;
    for (NSDictionary *p in rcao_current()) if ([p[@"id"] isEqualToString:words[0].lowercaseString]) return p;
    return nil;
}

BOOL RCAddOnsCommandShowsOwnBanner(NSString *cmd) {
    NSArray<NSString *> *words = rcao_words(cmd);
    NSDictionary *addOn = rcao_addOn_for(words);
    NSDictionary *action = addOn ? rcao_match_action(addOn, words, NULL) : nil;
    return [action[@"banner"] isKindOfClass:[NSDictionary class]];
}

NSString *RCAddOnsHandleCommand(NSString *cmd) {
    NSArray<NSString *> *words = rcao_words(cmd);
    if (words.count == 0) return nil;
    NSString *first = words[0].lowercaseString;

    if ([first isEqualToString:@"addons"]) {
        if (words.count == 2 && [words[1].lowercaseString isEqualToString:@"reload"]) {
            rcao_load(YES);
            return rcao_list();
        }
        if (words.count == 1) {
            rcao_load(NO);
            return rcao_list();
        }
        // "add-ons check add-on:<id>:<condition> [expected]": the value, and whether it matches
        if (words.count >= 3 && [words[1].lowercaseString isEqualToString:@"check"]) {
            BOOL isNumber = NO;
            NSString *value = RCAddOnsConditionValue(words[2], &isNumber);
            if (!value) return @"Error: No such condition, or no value\n";
            if (words.count == 3) return [NSString stringWithFormat:@"%@\n", value];
            NSString *expected = [[words subarrayWithRange:NSMakeRange(3, words.count - 3)] componentsJoinedByString:@" "];
            BOOL matches = RCEvaluateIfCondition(@{ @"conditionKey": words[2], @"expectedValue": expected });
            return [NSString stringWithFormat:@"%@ (%@ %@)\n", value, matches ? @"matches" : @"doesn't match", expected];
        }
        // "add-ons validate <file>": whether a file is a valid add-on, with warnings
        if (words.count == 3 && [words[1].lowercaseString isEqualToString:@"validate"]) {
            NSData *data = [NSData dataWithContentsOfFile:words[2]];
            if (!data) return [NSString stringWithFormat:@"Error: Can't read %@\n", words[2]];
            NSError *error = nil;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (![json isKindOfClass:[NSDictionary class]]) return @"Problem: not a JSON object\n";
            NSString *problem = rcao_check_addOn(json);
            if (problem) return [NSString stringWithFormat:@"Problem: %@\n", problem];
            NSMutableString *out = [NSMutableString stringWithFormat:@"OK: %@ (%@), %lu action%@\n", json[@"name"], json[@"id"], (unsigned long)[json[@"actions"] count], [json[@"actions"] count] == 1 ? @"" : @"s"];
            for (NSString *warning in rcao_warnings(json, [words[2] stringByDeletingLastPathComponent])) [out appendFormat:@"Warning: %@\n", warning];
            return out;
        }
        return @"Error: Use addons, addons reload, addons validate <file> or addons check <condition> [expected]\n";
    }

    NSDictionary *addOn = rcao_addOn_for(words);
    if (!addOn) return nil;

    // An add-on command running add-on commands: limited, so two can't call each other forever
    static __thread int depth = 0;
    if (depth >= kRCAOMaxDepth) return @"Error: Add-on commands nested too deeply\n";

    NSUInteger matchLength = 0;
    NSDictionary *match = rcao_match_action(addOn, words, &matchLength);
    if (!match) return rcao_usage(addOn);

    depth++;
    NSArray<NSString *> *rest = [words subarrayWithRange:NSMakeRange(1, words.count - 1)];
    NSString *result = rcao_run_action(addOn, match, [rest subarrayWithRange:NSMakeRange(matchLength, rest.count - matchLength)]);
    depth--;
    return result;
}

NSString *RCAddOnsConditionValue(NSString *key, BOOL *isNumber) {
    NSArray *parts = [key componentsSeparatedByString:@":"];
    if (parts.count != 3 || ![parts[0] isEqualToString:@"addon"]) return nil;
    for (NSDictionary *addOn in rcao_current()) {
        if (![addOn[@"id"] isEqualToString:parts[1]]) continue;
        for (NSDictionary *condition in addOn[@"conditions"] ?: @[]) {
            if (![condition[@"id"] isEqualToString:parts[2]]) continue;
            if (isNumber) *isNumber = [condition[@"type"] isEqualToString:@"number"];
            NSString *raw = nil;
            if (condition[@"exec"]) {
                int status = 0;
                raw = [rcao_exec(condition[@"exec"], [condition[@"root"] boolValue], &status)
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (status != 0) return nil;
            } else {
                int token = 0;
                uint64_t state = 0;
                if (notify_register_check([condition[@"notifyState"] UTF8String], &token) != NOTIFY_STATUS_OK) return nil;
                notify_get_state(token, &state);
                notify_cancel(token);
                raw = [NSString stringWithFormat:@"%llu", state];
            }
            // A choice condition's raw value maps to its label
            NSDictionary *choices = condition[@"choices"];
            if ([choices isKindOfClass:[NSDictionary class]] && [choices[raw] isKindOfClass:[NSString class]]) return choices[raw];
            return raw;
        }
    }
    return nil;
}

// An icon naming an image file (png, jpg or jpeg) in place of an SF Symbol
static BOOL rcao_icon_is_image(NSString *icon) {
    NSString *ext = icon.pathExtension.lowercaseString;
    return [@[@"png", @"jpg", @"jpeg"] containsObject:ext];
}

// Every icon string in an add-on: its own, its actions', its triggers' and its conditions'
static NSArray<NSString *> *rcao_icons(NSDictionary *addOn) {
    NSMutableArray *icons = [NSMutableArray array];
    void (^add)(id) = ^(id icon) { if (rcao_is_string(icon)) [icons addObject:icon]; };
    add(addOn[@"icon"]);
    for (NSDictionary *action in addOn[@"actions"] ?: @[]) if ([action isKindOfClass:[NSDictionary class]]) add(action[@"icon"]);
    for (NSDictionary *condition in addOn[@"conditions"] ?: @[]) if ([condition isKindOfClass:[NSDictionary class]]) add(condition[@"icon"]);
    for (NSDictionary *event in addOn[@"events"] ?: @[]) if ([event isKindOfClass:[NSDictionary class]] && [event[@"trigger"] isKindOfClass:[NSDictionary class]]) add(event[@"trigger"][@"icon"]);
    return icons;
}

// The image file an icon string names: beside the add-on's JSON file, or an absolute path. nil when
// it is an SF Symbol or the file isn't there.
static NSString *rcao_icon_path(NSString *icon, NSString *folder) {
    if (!rcao_is_string(icon) || !rcao_icon_is_image(icon)) return nil;
    NSString *path = [icon hasPrefix:@"/"] ? icon : [folder stringByAppendingPathComponent:icon];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

// The image an add-on's icon names (name nil), or one of its other icons (an action's, trigger's or
// condition's), with its content type. Only icons the add-on itself lists are served.
NSData *RCAddOnsIconData(NSString *addOnId, NSString *name, NSString **contentType) {
    for (NSDictionary *addOn in rcao_current()) {
        if (![addOn[@"id"] isEqualToString:addOnId]) continue;
        NSString *icon = name.length ? name : addOn[@"icon"];
        if (!icon || ![rcao_icons(addOn) containsObject:icon]) return nil;
        NSString *path = rcao_icon_path(icon, addOn[@"_folder"]);
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (!data || data.length > 512 * 1024) return nil;
        if (contentType) *contentType = [path.pathExtension.lowercaseString isEqualToString:@"png"] ? @"image/png" : @"image/jpeg";
        return data;
    }
    return nil;
}

NSString *RCAddOnsCatalogJSON(void) {
    NSArray *addOns, *problems;
    rcao_load(NO);
    @synchronized (rcao_lock()) {
        addOns = rcao_addOns ?: @[];
        problems = rcao_problems ?: @[];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"addons": addOns, @"problems": problems} options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{\"addons\":[],\"problems\":[]}";
}

void RCAddOnsStart(void) {
    dispatch_async(rcao_queue(), ^{ rcao_load(YES); });
}
