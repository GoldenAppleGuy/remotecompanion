#import <UIKit/UIKit.h>

// Older stand-ins for SF Symbols that iOS 14-16 lack, so every icon still shows there.
// A name that exists is always drawn as itself, so newer iOS looks the same.

// The symbol, or its stand-in where this iOS lacks it (nil when neither exists)
UIImage *RCSystemImage(NSString *name, UIImageConfiguration *config);

// The name drawn for `name` on this iOS: itself, its stand-in, or nil
NSString *RCSystemImageDrawnName(NSString *name);

// App only, before UIApplicationMain: makes every +[UIImage systemImageNamed:...] call use
// the stand-ins. Does nothing on iOS 17 and later, which has every symbol the app uses.
void RCInstallSymbolFallbacks(void);
