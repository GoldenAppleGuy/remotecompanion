#import <UIKit/UIKit.h>

// The add-ons (ADDONS.md) the tweak has loaded, those whose app or tweak isn't installed, and any
// files with problems. Read from the tweak's "add-ons reload" command.
@interface RCAddOnsViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>

// A line for the Integrations list: "3 loaded", "1 problem", or "None"; nil until read
+ (NSString *)cachedSummary;

@end
