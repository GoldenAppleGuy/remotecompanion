#import <UIKit/UIKit.h>

// The Set Variable editor: the name, the kind of change as a grid of tiles, the kind's
// fields and This Run Only, on one screen. Present it inside a navigation controller.
@interface RCSetVariableViewController : UITableViewController

// The action being edited, or nil for a new one
- (instancetype)initWithAction:(NSDictionary *)action;

// Called with the finished set_variable action when Save is tapped
@property (nonatomic, copy) void (^onSave)(NSDictionary *action);

@end
