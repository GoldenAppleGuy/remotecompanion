#import "RCChoiceViewController.h"
#import "RCConfigManager.h"
#import "RCNumberSettingViewController.h"

static NSString *const RCTimedPausePrefix = @"button triggers pause ";

// A line under the choices for the actions that need one
static NSString *RCChoiceNote(NSString *key, NSArray<NSString *> *suffixes) {
    NSDictionary *notes = @{
        @"autolock": @"Toggle switches between Never and the time it was set to before.",
        @"buttontriggers": @"Pause stops button triggers until a Resume; a time resumes them by itself.",
        @"haptics": @"When the system plays haptics.",
        @"anc": @"For AirPods and Beats with Noise Control.",
        @"camera_photo": @"Opens the Camera in this mode.",
        @"camera_video": @"Opens the Camera to record video with this lens.",
        @"nfcscanner": @"Pause stops NFC tag triggers until a Resume.",
    };
    if (notes[key]) return notes[key];
    if ([suffixes containsObject:@"toggle"]) return @"Toggle switches to the other state each time it runs.";
    return nil;
}

@interface RCChoiceViewController ()
@property (nonatomic, copy) NSDictionary *info;
@property (nonatomic, copy) NSString *currentSuffix;
@property (nonatomic, copy) NSString *timedMinutes; // "30" or "{name}" when the current one is a timed pause
@property (nonatomic, copy) NSArray *otherActions;
@end

@implementation RCChoiceViewController

+ (BOOL)isTimedPauseCommand:(NSString *)command {
    if (![command.lowercaseString hasPrefix:RCTimedPausePrefix]) return NO;
    NSString *rest = [command substringFromIndex:RCTimedPausePrefix.length];
    return rest.length > 0 && ![rest isEqualToString:@"15"] && ![rest isEqualToString:@"60"];
}

- (instancetype)initWithToggleInfo:(NSDictionary *)info current:(NSString *)current otherActions:(NSArray *)otherActions {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _info = [info copy];
        _otherActions = [otherActions copy];
        self.title = info[@"name"];
        if ([RCChoiceViewController isTimedPauseCommand:current]) {
            _timedMinutes = [[current substringFromIndex:RCTimedPausePrefix.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        } else if (current) {
            NSDictionary *matched = [[RCConfigManager sharedManager] toggleInfoForCommand:current];
            if ([matched[@"key"] isEqualToString:info[@"key"]]) _currentSuffix = matched[@"currentSuffix"];
        }
    }
    return self;
}

- (BOOL)isButtonTriggers {
    return [self.info[@"key"] isEqualToString:@"buttontriggers"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UIColor *bg = [cm tweakColorForKey:@"mainBackground" defaultVal:0.09];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    self.tableView.separatorColor = [cm tweakColorForKey:@"separators" defaultVal:0.30];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    }
    self.tableView.tableHeaderView = [self headerView];
}

// The action's icon over its name
- (UIView *)headerView {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 104)];
    UIView *tile = [[UIView alloc] init];
    tile.backgroundColor = [[RCConfigManager sharedManager] tweakColorForKey:@"blockBackground" defaultVal:0.12];
    tile.layer.cornerRadius = 16;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:tile];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:self.info[@"icon"] ?: @"switch.2"]];
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightRegular];
    icon.tintColor = [UIColor labelColor];
    icon.contentMode = UIViewContentModeCenter;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [tile.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [tile.topAnchor constraintEqualToAnchor:header.topAnchor constant:16],
        [tile.widthAnchor constraintEqualToConstant:64],
        [tile.heightAnchor constraintEqualToConstant:64],
        [icon.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
    ]];
    header.isAccessibilityElement = NO;
    return header;
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table

- (NSArray<NSString *> *)suffixes {
    return self.info[@"suffixes"] ?: @[];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self suffixes].count + ([self isButtonTriggers] ? 1 : 0);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return RCChoiceNote(self.info[@"key"], [self suffixes]);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = [cm tweakColorForKey:@"blockBackground" defaultVal:0.12];
    UIView *selection = [[UIView alloc] init];
    selection.backgroundColor = [cm tweakColorForKey:@"selectionHighlight" defaultVal:0.15];
    cell.selectedBackgroundView = selection;
    cell.textLabel.textColor = [UIColor labelColor];
    NSArray *suffixes = [self suffixes];
    if (indexPath.row < (NSInteger)suffixes.count) {
        cell.textLabel.text = self.info[@"displaySuffixes"][indexPath.row];
        BOOL chosen = [suffixes[indexPath.row] isEqualToString:self.currentSuffix ?: @""];
        cell.accessoryType = chosen ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
        // Button Triggers: paused for a time of your own
        cell.textLabel.text = @"Pause for a Time";
        cell.detailTextLabel.text = self.timedMinutes ? [self minutesText:self.timedMinutes] : nil;
        cell.accessoryType = self.timedMinutes ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (NSString *)minutesText:(NSString *)minutes {
    if ([minutes hasPrefix:@"{"]) return minutes;
    return [minutes isEqualToString:@"1"] ? @"1 minute" : [NSString stringWithFormat:@"%@ minutes", minutes];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *suffixes = [self suffixes];
    if (indexPath.row >= (NSInteger)suffixes.count) {
        [self askMinutes];
        return;
    }
    NSString *suffix = suffixes[indexPath.row];
    NSString *prefix = [self.info[@"matchedPrefix"] length] ? self.info[@"matchedPrefix"] : [self.info[@"prefixes"] firstObject] ?: @"";
    NSString *command = [prefix stringByAppendingString:suffix];
    // AudioMix's toggle is the bare command
    if (![self.info[@"matchedPrefix"] length] && [self.info[@"key"] isEqualToString:@"audiomix"] && [suffix isEqualToString:@"toggle"]) command = @"audiomix";
    self.currentSuffix = suffix;
    self.timedMinutes = nil;
    [tableView reloadData];
    [self finishWithCommand:command];
}

// Button Triggers paused for a number of minutes, or a variable
- (void)askMinutes {
    RCNumberSettingViewController *editor = [[RCNumberSettingViewController alloc] initWithTitle:@"Pause for a Time" label:@"Minutes"
                                                                                             value:self.timedMinutes otherActions:self.otherActions];
    editor.placeholder = @"30";
    editor.minimum = 1;
    editor.maximum = 1440;
    editor.allowsRound = NO;
    editor.note = @"Button triggers resume by themselves after this long, up to a day.";
    editor.saveTitle = @"Done";
    __weak typeof(self) weakSelf = self;
    editor.onSave = ^(id minutes, __unused NSInteger choice) {
        NSString *text = [minutes isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%ld", (long)[minutes integerValue]] : [minutes description];
        [weakSelf finishWithCommand:[RCTimedPausePrefix stringByAppendingString:text]];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    if (@available(iOS 15.0, *)) {
        nav.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)finishWithCommand:(NSString *)command {
    void (^onPick)(NSString *) = self.onPick;
    if (self.navigationController.viewControllers.firstObject == self && self.presentingViewController) {
        // Editing: this screen closes, then the action changes
        [self dismissViewControllerAnimated:YES completion:^{ if (onPick) onPick(command); }];
    } else if (onPick) {
        onPick(command); // in the picker: whoever opened it closes it
    }
}

@end
