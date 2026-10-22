#import <UIKit/UIKit.h>

// "Select Condition": the If / Else If conditions grouped into sections, with icons and
// search. Each condition is a definition from RCActionsViewController (key, title, icon,
// section, values, input). Tapping a condition expands its options beneath it:
// - a value per row (picking one finishes),
// - Day of the Week: the days to tick, then Done,
// - conditions that need input (time range, a name, a level, an app): one row that hands
//   off to the editor's prompt.
// The picker pops itself, then calls the matching block once the pop has finished.
@interface RCConditionPickerViewController : UITableViewController

// existing: the If / Else If block being edited (opens its condition with the value ticked)
- (instancetype)initWithConditions:(NSArray<NSDictionary *> *)conditions title:(NSString *)title existing:(NSDictionary *)existing;
// value: @{ @"value": ..., @"title": ... }
@property (nonatomic, copy) void (^onValueSelected)(NSDictionary *condition, NSDictionary *value);
// Called after the picker closes, except for Front Application: the app list opens on top
// of the picker (so Back returns here), so it's called with the picker still on screen
@property (nonatomic, copy) void (^onInputRequested)(NSDictionary *condition);

@end
