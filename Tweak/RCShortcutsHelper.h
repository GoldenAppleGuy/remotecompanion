// Shared by the tweak (SpringBoard) and RCShortcutsHelper (siriactionsd)

// Posted by the helper when siriactionsd is ready to run shortcuts; its state is siriactionsd's pid
#define kRCShortcutsHelperNotification "com.saihgupr.remotecompanion.shortcuts-helper"

// SpringBoard asks the helper to run a shortcut, or (action "list") for the shortcut names, which
// it answers with state "list" and names. To run one, the helper answers (distributed notifications,
// which carry a dictionary). Request: name, input (optional), id. Reply: id, state ("started",
// "missing", or "unsupported" when this iOS lacks what it needs), error. Once a started shortcut
// ends, a second reply has state "finished", "cancelled" or "failed".
#define kRCShortcutsRunRequest @"com.saihgupr.remotecompanion.shortcuts.run"
#define kRCShortcutsRunReply   @"com.saihgupr.remotecompanion.shortcuts.reply"
