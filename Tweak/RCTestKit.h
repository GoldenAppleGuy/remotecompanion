#import <Foundation/Foundation.h>

// On-device test kit (RCTestKit.x): an event journal with millisecond timestamps, a state
// probe, dry-run trigger capture, state snapshot/restore, and a JSON HTTP API under
// /api/testkit/ that returns results synchronously - for test runners, users reporting
// problems, and agents.

// Records an event in the journal. Safe from any thread; cheap enough for hook paths.
void RCTKEvent(NSString *type, NSDictionary *info);

// Called as a trigger fires. Returns YES while capture (dry-run) is on: the trigger is
// recorded and its actions must not run.
BOOL RCTKCaptureTrigger(NSString *triggerKey);

// Handles a request under /api/testkit/ and returns the complete HTTP response. Reads any
// remaining request body from fd itself.
NSString *RCTKHandleHTTP(int fd, const char *buffer, long length, NSString *method, NSString *path, NSString *cors);

// "testkit <subcommand>" from handle_command (rc-client / UNIX socket): returns JSON.
NSString *RCTKHandleCommand(NSString *args);

// Provided by Tweak.x for the test kit
NSString *RCHandleCommand(NSString *cmd);
NSDictionary *RCCopyTriggerConfig(void);
void RCSetTriggerConfig(NSDictionary *config);
BOOL RCEvaluateIfCondition(NSDictionary *ifAction);
NSDictionary *RCEvaluateLuaCapturing(NSString *code); // {output, returns, error?}
void RCShowPrompt(NSString *title, NSString *subtitle, NSString *iconSymbol, NSTimeInterval hold);
void RCHidePrompt(void);
