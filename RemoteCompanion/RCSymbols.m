#import "RCSymbols.h"
#import <objc/runtime.h>

// Symbol -> stand-ins to try in order, each available since iOS 14.0 unless noted
static NSDictionary<NSString *, NSArray<NSString *> *> *RCSymbolFallbacks(void) {
    static NSDictionary *fallbacks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fallbacks = @{
            // iOS 15
            @"airplayaudio.badge.exclamationmark": @[@"airplayaudio"],
            @"battery.50": @[@"battery.25"],
            @"battery.75": @[@"battery.100"],
            @"beats.headphones": @[@"headphones"],
            @"checklist": @[@"list.bullet.rectangle"],
            @"circle.lefthalf.filled": @[@"circle.lefthalf.fill"],
            @"cup.and.saucer.fill": @[@"drop.fill"],
            @"fanblades.fill": @[@"wind"],
            @"fork.knife": @[@"cart.fill"],
            @"keyboard.fill": @[@"keyboard"],
            @"line.3.horizontal": @[@"line.horizontal.3"],
            @"list.bullet.circle": @[@"list.bullet"],
            @"pawprint.fill": @[@"hare.fill"],
            @"powerplug.fill": @[@"bolt.fill"],
            @"rectangle.bottomthird.inset.filled": @[@"rectangle.bottomthird.inset.fill"],
            @"rectangle.lefthalf.inset.filled": @[@"rectangle.lefthalf.inset.fill"],
            @"rectangle.portrait.and.arrow.right": @[@"arrow.right.square"],
            // rectangle.topthird.inset.fill is iOS 14.5, rectangle.topthird.inset iOS 14.2
            @"rectangle.topthird.inset.filled": @[@"rectangle.topthird.inset.fill", @"rectangle.topthird.inset", @"menubar.rectangle"],
            @"sensor.tag.radiowaves.forward.fill": @[@"hand.raised.fill"],
            @"snowflake": @[@"thermometer.snowflake"],
            @"xmark.app.fill": @[@"xmark.square.fill"],
            // iOS 16
            @"door.left.hand.open": @[@"lock.open.fill"],
            @"lamp.desk.fill": @[@"lightbulb"],
            @"sensor.fill": @[@"dot.radiowaves.left.and.right"],
            @"sofa.fill": @[@"bed.double.fill"],
            @"washer.fill": @[@"drop.fill"],
            @"web.camera.fill": @[@"video.fill"],
            // iOS 17
            @"accessibility": @[@"figure.stand"],
            @"fan.fill": @[@"wind"],
            @"rectangle.portrait.rotate": @[@"rotate.right.fill"],
        };
    });
    return fallbacks;
}

// UIKit's own lookups, saved when the app's fallbacks are installed
static UIImage *(*RCOrigNamed)(id, SEL, NSString *);
static UIImage *(*RCOrigNamedConfig)(id, SEL, NSString *, UIImageConfiguration *);
static UIImage *(*RCOrigNamedTraits)(id, SEL, NSString *, UITraitCollection *);

static UIImage *RCLookup(NSString *name, UIImageConfiguration *config) {
    if (RCOrigNamedConfig) return RCOrigNamedConfig([UIImage class], @selector(systemImageNamed:withConfiguration:), name, config);
    return [UIImage systemImageNamed:name withConfiguration:config];
}

static NSString *RCDrawnName(NSString *name, UIImage *(^lookup)(NSString *)) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return nil;
    if (lookup(name)) return name;
    for (NSString *fallback in RCSymbolFallbacks()[name]) if (lookup(fallback)) return fallback;
    return nil;
}

UIImage *RCSystemImage(NSString *name, UIImageConfiguration *config) {
    __block UIImage *image = nil;
    RCDrawnName(name, ^UIImage *(NSString *candidate) { return image = RCLookup(candidate, config); });
    return image;
}

NSString *RCSystemImageDrawnName(NSString *name) {
    return RCDrawnName(name, ^UIImage *(NSString *candidate) { return RCLookup(candidate, nil); });
}

static UIImage *RCNamed(id self, SEL _cmd, NSString *name) {
    UIImage *image = RCOrigNamed(self, _cmd, name);
    if (image || !RCSymbolFallbacks()[name]) return image;
    return RCSystemImage(name, nil);
}

static UIImage *RCNamedConfig(id self, SEL _cmd, NSString *name, UIImageConfiguration *config) {
    UIImage *image = RCOrigNamedConfig(self, _cmd, name, config);
    if (image || !RCSymbolFallbacks()[name]) return image;
    return RCSystemImage(name, config);
}

static UIImage *RCNamedTraits(id self, SEL _cmd, NSString *name, UITraitCollection *traits) {
    UIImage *image = RCOrigNamedTraits(self, _cmd, name, traits);
    if (image || !RCSymbolFallbacks()[name]) return image;
    for (NSString *fallback in RCSymbolFallbacks()[name]) {
        image = RCOrigNamedTraits(self, _cmd, fallback, traits);
        if (image) return image;
    }
    return nil;
}

static void RCReplace(SEL selector, IMP replacement, IMP *original) {
    Method method = class_getClassMethod([UIImage class], selector);
    if (method) *original = method_setImplementation(method, replacement);
}

void RCInstallSymbolFallbacks(void) {
    if (@available(iOS 17.0, *)) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RCReplace(@selector(systemImageNamed:withConfiguration:), (IMP)RCNamedConfig, (IMP *)&RCOrigNamedConfig);
        RCReplace(@selector(systemImageNamed:), (IMP)RCNamed, (IMP *)&RCOrigNamed);
        RCReplace(@selector(systemImageNamed:compatibleWithTraitCollection:), (IMP)RCNamedTraits, (IMP *)&RCOrigNamedTraits);
    });
}
