#import <Foundation/Foundation.h>

// Add-ons (ADDONS.md): JSON files that add actions, conditions and banners for other apps and
// tweaks. Read from the Add-ons folder at start and again when it changes.

// Runs an add-on command ("<add-on id> <action> [options]"), or "addons [reload]". Returns nil
// when no add-on has that id. Called after the built-in commands, so they always come first.
NSString *RCAddOnsHandleCommand(NSString *cmd);

// Whether a command runs an add-on action that shows a banner of its own (so no generic banner)
BOOL RCAddOnsCommandShowsOwnBanner(NSString *cmd);

// The value of an add-on condition ("addon:<add-on id>:<condition id>"), or nil if unknown.
// *isNumber says whether it's compared as a number.
NSString *RCAddOnsConditionValue(NSString *key, BOOL *isNumber);

// The image an add-on's icon names (name nil), or one of its other icons (an action's, trigger's or
// condition's), and its content type; nil when it isn't an image the add-on lists
NSData *RCAddOnsIconData(NSString *addOnId, NSString *name, NSString **contentType);

// The add-ons offered on this device, as JSON for the Web UI: {"add-ons": [...], "problems": [...]}
NSString *RCAddOnsCatalogJSON(void);

// Loads the add-ons and registers their event banners. Call once in SpringBoard.
void RCAddOnsStart(void);
