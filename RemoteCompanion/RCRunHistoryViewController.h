#import <UIKit/UIKit.h>

// A trigger's last runs: when, how long, and whether it finished or was stopped; tapping one shows
// what it did (the If branches it took, its loops' rounds, its waits). Keep sets how many are kept.
@interface RCRunHistoryViewController : UITableViewController
- (instancetype)initWithTriggerKey:(NSString *)triggerKey;
@end
