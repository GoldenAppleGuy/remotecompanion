#import "RCAddOnCatalog.h"
#import "RCAddOnOptionsViewController.h"

@implementation RCAddOnCatalog

// An icon that names an image file rather than an SF Symbol
+ (BOOL)iconIsImage:(NSString *)icon {
    return [@[@"png", @"jpg", @"jpeg"] containsObject:icon.pathExtension.lowercaseString];
}

// The add-on's own icon as an SF Symbol name; the puzzle piece when it has none or uses an image
+ (NSString *)iconForAddOn:(NSDictionary *)addOn {
    NSString *icon = addOn[@"icon"];
    return [icon isKindOfClass:[NSString class]] && icon.length && ![self iconIsImage:icon] ? icon : @"puzzlepiece.extension";
}

// An icon string (an add-on's, action's, trigger's or condition's) as a list-row image: the image
// file it names (beside the add-on's JSON file, or an absolute path), 26 pt and rounded; nil when
// it is a symbol, empty, or the file is missing or over 512 KB
+ (UIImage *)imageForIcon:(NSString *)icon inAddOn:(NSDictionary *)addOn {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    if (![icon isKindOfClass:[NSString class]] || ![self iconIsImage:icon]) return nil;
    NSString *path = [icon hasPrefix:@"/"] ? icon : [(addOn[@"_folder"] ?: @"") stringByAppendingPathComponent:icon];
    UIImage *cached = [cache objectForKey:path];
    if (cached) return cached;
    NSData *data = [NSData dataWithContentsOfFile:path];
    UIImage *image = data.length && data.length <= 512 * 1024 ? [UIImage imageWithData:data] : nil;
    if (!image) return nil;
    CGSize size = CGSizeMake(26, 26);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *rounded = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:6] addClip];
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
    rounded = [rounded imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    [cache setObject:rounded forKey:path];
    return rounded;
}

// The symbol for an icon string: itself, or the fallback when it is an image or empty
+ (NSString *)symbolForIcon:(NSString *)icon fallback:(NSString *)fallback {
    return [icon isKindOfClass:[NSString class]] && icon.length && ![self iconIsImage:icon] ? icon : fallback;
}

// A thing's own icon, else the add-on's: the image to show (nil when it shows a symbol)
+ (UIImage *)imageForOwnIcon:(NSString *)icon inAddOn:(NSDictionary *)addOn {
    if ([icon isKindOfClass:[NSString class]] && icon.length) return [self imageForIcon:icon inAddOn:addOn];
    return [self imageForIcon:addOn[@"icon"] inAddOn:addOn];
}

// A thing's own icon, else the add-on's: the symbol to show
+ (NSString *)symbolForOwnIcon:(NSString *)icon inAddOn:(NSDictionary *)addOn {
    if ([icon isKindOfClass:[NSString class]] && icon.length) return [self symbolForIcon:icon fallback:[self iconForAddOn:addOn]];
    return [self iconForAddOn:addOn];
}

+ (UIImage *)iconImageForAddOn:(NSDictionary *)addOn {
    return [self imageForIcon:addOn[@"icon"] inAddOn:addOn];
}

+ (NSString *)iconForAddOnNamed:(NSString *)name {
    for (NSDictionary *addOn in [self addOns]) if ([addOn[@"name"] isEqualToString:name]) return [self iconForAddOn:addOn];
    return @"puzzlepiece.extension";
}

+ (UIImage *)iconImageForAddOnNamed:(NSString *)name {
    for (NSDictionary *addOn in [self addOns]) if ([addOn[@"name"] isEqualToString:name]) return [self iconImageForAddOn:addOn];
    return nil;
}

// The valid, installed add-ons (re-read at most every couple of seconds)
+ (NSArray<NSDictionary *> *)addOns {
    static NSArray *cached;
    static CFAbsoluteTime readAt;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cached && now - readAt < 2.0) return cached;
    readAt = now;
    NSMutableArray *addOns = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *folder in @[@"/var/jb/Library/RemoteCompanion/AddOns", @"/Library/RemoteCompanion/AddOns"]) {
        for (NSString *name in [[fm contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            if (![name.pathExtension isEqualToString:@"json"]) continue;
            NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name]];
            NSDictionary *addOn = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![addOn isKindOfClass:[NSDictionary class]] || ![addOn[@"id"] isKindOfClass:[NSString class]] ||
                ![addOn[@"name"] isKindOfClass:[NSString class]] || ![addOn[@"actions"] isKindOfClass:[NSArray class]] ||
                [ids containsObject:addOn[@"id"]] || ![self installed:addOn]) continue;
            [ids addObject:addOn[@"id"]];
            NSMutableDictionary *loaded = [addOn mutableCopy];
            loaded[@"_folder"] = folder;   // the add-on's image icon sits beside its file
            [addOns addObject:loaded];
        }
    }
    cached = addOns;
    return addOns;
}

+ (BOOL)installed:(NSDictionary *)addOn {
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

+ (NSArray<NSString *> *)wordsIn:(NSString *)command {
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *w in [command componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (w.length) [words addObject:w];
    }
    return words;
}

// The add-on and action a command runs, and the words after the action's own
+ (BOOL)match:(NSString *)command addOn:(NSDictionary **)addOnOut action:(NSDictionary **)actionOut rest:(NSArray<NSString *> **)restOut {
    if (![command isKindOfClass:[NSString class]]) return NO;
    NSArray<NSString *> *words = [self wordsIn:command];
    if (words.count < 2) return NO;
    for (NSDictionary *addOn in [self addOns]) {
        if (![addOn[@"id"] isEqualToString:words[0].lowercaseString]) continue;
        NSDictionary *match = nil;
        NSUInteger matchLength = 0;
        for (NSDictionary *action in addOn[@"actions"]) {
            if (![action isKindOfClass:[NSDictionary class]] || ![action[@"command"] isKindOfClass:[NSString class]]) continue;
            NSArray *commandWords = [action[@"command"] componentsSeparatedByString:@" "];
            if (commandWords.count > words.count - 1 || commandWords.count <= matchLength) continue;
            BOOL same = YES;
            for (NSUInteger i = 0; i < commandWords.count && same; i++) same = [words[i + 1].lowercaseString isEqualToString:commandWords[i]];
            if (same) { match = action; matchLength = commandWords.count; }
        }
        if (!match) return NO;
        if (addOnOut) *addOnOut = addOn;
        if (actionOut) *actionOut = match;
        if (restOut) *restOut = [words subarrayWithRange:NSMakeRange(1 + matchLength, words.count - 1 - matchLength)];
        return YES;
    }
    return NO;
}

+ (NSString *)titleForAddOn:(NSDictionary *)addOn action:(NSDictionary *)action {
    return [NSString stringWithFormat:@"%@: %@", addOn[@"name"], action[@"name"]];
}

+ (NSArray<NSDictionary *> *)pickerSections {
    NSMutableArray *sections = [NSMutableArray array];
    for (NSDictionary *addOn in [self addOns]) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *action in addOn[@"actions"]) {
            if (![action isKindOfClass:[NSDictionary class]] || ![action[@"name"] isKindOfClass:[NSString class]]) continue;
            NSMutableDictionary *entry = [@{
                @"name": [self titleForAddOn:addOn action:action],
                @"command": [NSString stringWithFormat:@"%@ %@", addOn[@"id"], action[@"command"]],
                @"shortName": action[@"name"],
                @"icon": [self symbolForOwnIcon:action[@"icon"] inAddOn:addOn],
            } mutableCopy];
            // An image icon, the action's own or else the add-on's
            UIImage *image = [self imageForOwnIcon:action[@"icon"] inAddOn:addOn];
            if (image) entry[@"image"] = image;
            [items addObject:entry];
        }
        if (items.count) [sections addObject:@{ @"id": addOn[@"id"], @"title": addOn[@"name"], @"icon": [self iconForAddOn:addOn], @"image": [self iconImageForAddOn:addOn] ?: [NSNull null], @"actions": items }];
    }
    return sections;
}

+ (NSArray<NSDictionary *> *)addOnRows {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *section in [self pickerSections]) {
        NSArray *actions = section[@"actions"];
        [rows addObject:@{ @"name": section[@"title"], @"command": [@"__ADDON__" stringByAppendingString:section[@"id"]],
                           @"icon": section[@"icon"], @"image": section[@"image"], @"count": @(actions.count) }];
    }
    return rows;
}

+ (NSArray<NSDictionary *> *)actionsForAddOn:(NSString *)identifier {
    for (NSDictionary *section in [self pickerSections]) if ([section[@"id"] isEqualToString:identifier]) return section[@"actions"];
    return @[];
}

+ (NSArray<NSDictionary *> *)pickerActions {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *addOn in [self addOns]) {
        for (NSDictionary *action in addOn[@"actions"]) {
            if (![action isKindOfClass:[NSDictionary class]] || ![action[@"name"] isKindOfClass:[NSString class]]) continue;
            [items addObject:@{
                @"name": [self titleForAddOn:addOn action:action],
                @"command": [NSString stringWithFormat:@"%@ %@", addOn[@"id"], action[@"command"]],
                @"icon": [self symbolForOwnIcon:action[@"icon"] inAddOn:addOn],
            }];
        }
    }
    return items;
}

+ (NSString *)iconForCommand:(NSString *)command {
    NSDictionary *addOn = nil, *action = nil;
    if (![self match:command addOn:&addOn action:&action rest:NULL]) return nil;
    return [self symbolForOwnIcon:action[@"icon"] inAddOn:addOn];
}

+ (UIImage *)imageForCommand:(NSString *)command {
    NSDictionary *addOn = nil, *action = nil;
    if (![self match:command addOn:&addOn action:&action rest:NULL]) return nil;
    return [self imageForOwnIcon:action[@"icon"] inAddOn:addOn];
}

+ (NSString *)nameForCommand:(NSString *)command {
    NSDictionary *addOn = nil, *action = nil;
    return [self match:command addOn:&addOn action:&action rest:NULL] ? [self titleForAddOn:addOn action:action] : nil;
}

// The choice an option has in these words, or nil
+ (NSDictionary *)choiceForOption:(NSDictionary *)option inWords:(NSArray<NSString *> *)words {
    for (NSDictionary *choice in option[@"choices"]) {
        for (NSString *word in words) {
            if ([word.lowercaseString isEqualToString:[choice[@"word"] lowercaseString]]) return choice;
        }
    }
    return nil;
}

// The words that aren't an option's choice: the action's input
+ (NSString *)inputInWords:(NSArray<NSString *> *)words action:(NSDictionary *)action {
    NSMutableArray *rest = [NSMutableArray array];
    for (NSString *word in words) {
        BOOL isChoice = NO;
        for (NSDictionary *option in action[@"options"] ?: @[]) {
            if ([self choiceForOption:option inWords:@[word]]) { isChoice = YES; break; }
        }
        if (!isChoice) [rest addObject:word];
    }
    return rest.count ? [rest componentsJoinedByString:@" "] : nil;
}

+ (NSString *)summaryForCommand:(NSString *)command {
    NSDictionary *action = nil;
    NSArray *rest = nil;
    if (![self match:command addOn:NULL action:&action rest:&rest] || rest.count == 0) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *option in action[@"options"] ?: @[]) {
        NSDictionary *choice = [self choiceForOption:option inWords:rest];
        if (choice) [parts addObject:choice[@"label"] ?: choice[@"word"]];
    }
    NSString *input = [self inputInWords:rest action:action];
    if (input) [parts addObject:input];
    return parts.count ? [parts componentsJoinedByString:@" · "] : nil;
}

+ (BOOL)commandAsksForDetails:(NSString *)command {
    NSDictionary *action = nil;
    if (![self match:command addOn:NULL action:&action rest:NULL]) return NO;
    return [action[@"options"] count] > 0 || [action[@"input"] isKindOfClass:[NSDictionary class]];
}

+ (void)presentDetailsFrom:(UIViewController *)controller command:(NSString *)command current:(NSString *)current completion:(void (^)(NSString *))completion {
    NSDictionary *addOn = nil, *action = nil;
    if (![self match:command addOn:&addOn action:&action rest:NULL]) {
        completion(command);
        return;
    }
    NSString *base = [NSString stringWithFormat:@"%@ %@", addOn[@"id"], action[@"command"]];
    NSArray *currentRest = nil;
    [self match:current addOn:NULL action:NULL rest:&currentRest];
    RCAddOnOptionsViewController *screen = [[RCAddOnOptionsViewController alloc] initWithAction:action base:base current:currentRest ?: @[] editing:current != nil];
    screen.onDone = completion;
    // The action list stays open after Save; the picker closes itself once the action is added
    screen.popsWhenDone = [NSStringFromClass([controller class]) isEqualToString:@"RCActionsViewController"];
    if (controller.navigationController) {
        [controller.navigationController pushViewController:screen animated:YES];
    } else {
        [controller presentViewController:[[UINavigationController alloc] initWithRootViewController:screen] animated:YES completion:nil];
    }
}

+ (NSArray<NSDictionary *> *)bannerItems {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *addOn in [self addOns]) {
        for (NSDictionary *action in addOn[@"actions"]) {
            if (![action isKindOfClass:[NSDictionary class]] || ![action[@"banner"] isKindOfClass:[NSDictionary class]]) continue;
            [items addObject:@{
                @"id": [NSString stringWithFormat:@"%@ %@", addOn[@"id"], action[@"command"]],
                @"name": [self titleForAddOn:addOn action:action],
                @"icon": [self symbolForOwnIcon:action[@"icon"] inAddOn:addOn],
            }];
        }
    }
    return items;
}

+ (NSArray<NSDictionary *> *)triggerEvents {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *addOn in [self addOns]) {
        for (NSDictionary *event in [addOn[@"events"] isKindOfClass:[NSArray class]] ? addOn[@"events"] : @[]) {
            NSDictionary *trigger = [event isKindOfClass:[NSDictionary class]] ? event[@"trigger"] : nil;
            if (![trigger isKindOfClass:[NSDictionary class]] || ![trigger[@"id"] isKindOfClass:[NSString class]] || ![trigger[@"name"] isKindOfClass:[NSString class]]) continue;
            NSString *key = [NSString stringWithFormat:@"addon_%@_%@", addOn[@"id"], trigger[@"id"]];
            NSString *icon = [self symbolForOwnIcon:trigger[@"icon"] inAddOn:addOn];
            UIImage *image = [self imageForOwnIcon:trigger[@"icon"] inAddOn:addOn];
            NSMutableDictionary *first = [@{ @"key": key, @"name": [NSString stringWithFormat:@"%@: %@", addOn[@"name"], trigger[@"name"]], @"icon": icon, @"section": addOn[@"name"] } mutableCopy];
            if (image) first[@"image"] = image;
            [items addObject:first];
            // The trigger's own states, else the banner's; "states": false offers none
            NSDictionary *states = @{};
            if ([trigger[@"states"] isKindOfClass:[NSDictionary class]]) states = trigger[@"states"];
            else if (![trigger[@"states"] isEqual:@NO] && [event[@"banner"] isKindOfClass:[NSDictionary class]] && [event[@"banner"][@"states"] isKindOfClass:[NSDictionary class]]) states = event[@"banner"][@"states"];
            for (NSString *state in [states.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [a compare:b options:NSNumericSearch]; }]) {
                NSMutableDictionary *perState = [@{ @"key": [NSString stringWithFormat:@"%@_%@", key, state],
                                                    @"name": [NSString stringWithFormat:@"%@: %@ (%@)", addOn[@"name"], trigger[@"name"], states[state]],
                                                    @"icon": icon, @"section": addOn[@"name"] } mutableCopy];
                if (image) perState[@"image"] = image;
                [items addObject:perState];
            }
        }
    }
    return items;
}

+ (BOOL)isAddOnTriggerKey:(NSString *)key {
    return [key hasPrefix:@"addon_"];
}

// A trigger key's name: the add-on's wording for it, or nil
+ (NSString *)nameForTriggerKey:(NSString *)key {
    for (NSDictionary *item in [self triggerEvents]) if ([item[@"key"] isEqualToString:key]) return item[@"name"];
    return nil;
}

+ (NSArray<NSDictionary *> *)addOnTriggerGroups {
    NSMutableArray *groups = [NSMutableArray array];
    for (NSDictionary *addOn in [self addOns]) {
        NSMutableArray *triggers = [NSMutableArray array];
        for (NSDictionary *event in [addOn[@"events"] isKindOfClass:[NSArray class]] ? addOn[@"events"] : @[]) {
            NSDictionary *trigger = [event isKindOfClass:[NSDictionary class]] ? event[@"trigger"] : nil;
            if (![trigger isKindOfClass:[NSDictionary class]] || ![trigger[@"id"] isKindOfClass:[NSString class]] || ![trigger[@"name"] isKindOfClass:[NSString class]]) continue;
            NSString *key = [NSString stringWithFormat:@"addon_%@_%@", addOn[@"id"], trigger[@"id"]];
            NSDictionary *states = @{};
            if ([trigger[@"states"] isKindOfClass:[NSDictionary class]]) states = trigger[@"states"];
            else if (![trigger[@"states"] isEqual:@NO] && [event[@"banner"] isKindOfClass:[NSDictionary class]] && [event[@"banner"][@"states"] isKindOfClass:[NSDictionary class]]) states = event[@"banner"][@"states"];
            NSMutableArray *choices = [NSMutableArray array];
            for (NSString *state in [states.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [a compare:b options:NSNumericSearch]; }]) {
                [choices addObject:@{ @"key": [NSString stringWithFormat:@"%@_%@", key, state], @"label": states[state],
                                      @"name": [NSString stringWithFormat:@"%@: %@ (%@)", addOn[@"name"], trigger[@"name"], states[state]] }];
            }
            [triggers addObject:@{ @"key": key, @"title": trigger[@"name"], @"name": [NSString stringWithFormat:@"%@: %@", addOn[@"name"], trigger[@"name"]],
                                   @"states": choices }];
        }
        if (triggers.count) {
            [groups addObject:@{ @"id": addOn[@"id"], @"title": addOn[@"name"], @"icon": [self iconForAddOn:addOn],
                                 @"image": [self iconImageForAddOn:addOn] ?: [NSNull null], @"triggers": triggers }];
        }
    }
    return groups;
}

+ (UIImage *)imageForTriggerKey:(NSString *)key {
    for (NSDictionary *item in [self triggerEvents]) if ([item[@"key"] isEqualToString:key] && item[@"image"]) return item[@"image"];
    return nil;
}

+ (NSString *)iconForTriggerKey:(NSString *)key {
    for (NSDictionary *item in [self triggerEvents]) if ([item[@"key"] isEqualToString:key]) return item[@"icon"];
    return nil;
}

+ (NSArray<NSDictionary *> *)conditions {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *addOn in [self addOns]) {
        NSArray *conditions = [addOn[@"conditions"] isKindOfClass:[NSArray class]] ? addOn[@"conditions"] : @[];
        for (NSDictionary *condition in conditions) {
            if (![condition isKindOfClass:[NSDictionary class]] || ![condition[@"id"] isKindOfClass:[NSString class]]) continue;
            NSDictionary *choiceMap = [condition[@"choices"] isKindOfClass:[NSDictionary class]] ? condition[@"choices"] : @{};
            NSArray *keys = [choiceMap.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [a compare:b options:NSNumericSearch];
            }];
            NSMutableArray *labels = [NSMutableArray array];
            for (NSString *key in keys) [labels addObject:[choiceMap[key] description]];
            [items addObject:@{
                @"key": [NSString stringWithFormat:@"addon:%@:%@", addOn[@"id"], condition[@"id"]],
                @"name": [NSString stringWithFormat:@"%@: %@", addOn[@"name"], condition[@"name"]],
                @"type": [condition[@"type"] isEqual:@"number"] ? @"number" : @"choice",
                @"icon": [self symbolForOwnIcon:condition[@"icon"] inAddOn:addOn],
                @"image": [self imageForOwnIcon:condition[@"icon"] inAddOn:addOn] ?: [NSNull null],
                @"choices": labels,
            }];
        }
    }
    return items;
}

@end
