#import <UIKit/UIKit.h>

// Before a guided or stock-vs-tweak run: the suite's steps on this device, grouped, each
// with how many times to do it (0 leaves it out). Remembers the choice per suite.
@interface RCTestKitSetupViewController : UITableViewController

- (instancetype)initWithSuite:(NSString *)suite;

// Called with the options for "suite/run" (e.g. "&steps=a,b:2"; empty for every step once)
@property (nonatomic, copy) void (^onStart)(NSString *options);

@end
