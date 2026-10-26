#import "RCTriggerSettingsViewController.h"
#import "RCConfigManager.h"
#import "RCUITweaker.h"

@interface RCTriggerSettingsViewController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISwitch *nfcSwitch;
@end

// Sections of the Triggers & Buttons table, in order
typedef NS_ENUM(NSInteger, RCTriggerSettingsSection) {
    RCTriggerSettingsSectionNFC,
    RCTriggerSettingsSectionTiming,
};

@implementation RCTriggerSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Triggers & Buttons";
    
    // Enable Large Titles
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.tintColor = [UIColor labelColor];

    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    // Setup Table View
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.rowHeight = 50;
    
    // Improved Section Spacing
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 10;
    }
    
    [self.view addSubview:self.tableView];
    
    // Constraints
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    
    // Listen for color tweak changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleTweaksChanged:)
                                                 name:@"RCConfigTweaksChangedNotification"
                                               object:nil];
    [self applyTweaks];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleTweaksChanged:(NSNotification *)note {
    [self applyTweaks];
}

- (void)applyTweaks {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    CGFloat mainBG = [cm tweakValueForKey:@"mainBackground" defaultVal:0.09];
    UIColor *settingsBG = [cm tweakColorForKey:@"settingsBackground" defaultVal:mainBG];
    self.view.backgroundColor = settingsBG;
    self.tableView.backgroundColor = settingsBG;
    self.navigationController.navigationBar.backgroundColor = [cm tweakColorForKey:@"navBar" defaultVal:0.09];
    self.tableView.separatorColor = [cm tweakColorForKey:@"separators" defaultVal:0.30];
    [self.tableView reloadData];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self applyTweaks];
        }
    }
}

#pragma mark - Timing Rows

// The Button Timing rows, in order: the click and sequence windows, then the hold times. Home
// Clicks only on a phone with a Home button.
- (NSArray<NSDictionary *> *)timingRows {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@{ @"title": @"Volume Sequence",
        @"message": @"How soon after a volume press the other volume button completes an Up then Down or Down then Up sequence.",
        @"values": @[@0.20, @0.25, @0.30, @0.38, @0.45, @0.55, @0.65], @"default": @0.38,
        @"get": ^double{ return cm.volumeSequenceWindow; }, @"set": ^(double v) { cm.volumeSequenceWindow = v; } }];
    [rows addObject:@{ @"title": @"Power Clicks",
        @"message": @"How long a Power press waits for the next click before the clicks count as a double, triple or quadruple click.",
        @"values": @[@0.10, @0.15, @0.20, @0.25, @0.30, @0.35, @0.40, @0.50, @0.60, @0.70], @"default": @0.40,
        @"get": ^double{ return cm.powerClickWindow; }, @"set": ^(double v) { cm.powerClickWindow = v; } }];
    // A phone with a Home button has no safe area at the bottom of the screen
    UIWindow *window = self.view.window ?: [UIApplication sharedApplication].windows.firstObject;
    if (window && window.safeAreaInsets.bottom <= 0) {
        [rows addObject:@{ @"title": @"Home Clicks",
            @"message": @"How long a Home press waits for the next click before the clicks count as a double, triple or quadruple click.",
            @"values": @[@0.25, @0.30, @0.35, @0.45, @0.55, @0.65], @"default": @0.35,
            @"get": ^double{ return cm.homeClickWindow; }, @"set": ^(double v) { cm.homeClickWindow = v; } }];
    }
    [rows addObject:@{ @"title": @"Volume Hold",
        @"message": @"How long a Volume Up or Down press is held before it counts as a hold rather than a tap. Taps wait this long when a hold trigger is set.",
        @"values": @[@0.20, @0.25, @0.30, @0.35, @0.45, @0.55, @0.70], @"default": @0.35,
        @"get": ^double{ return cm.volumeHoldTime; }, @"set": ^(double v) { cm.volumeHoldTime = v; } }];
    [rows addObject:@{ @"title": @"Power Hold",
        @"message": @"How long a Power press is held before it counts as a long press.",
        @"values": @[@0.30, @0.40, @0.50, @0.60, @0.75], @"default": @0.50,
        @"get": ^double{ return cm.powerHoldTime; }, @"set": ^(double v) { cm.powerHoldTime = v; } }];
    return rows;
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = (section == RCTriggerSettingsSectionNFC) ? @"NFC" : @"Button Timing";
    
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 40)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 15, tableView.bounds.size.width - 40, 20)];
    label.text = [title uppercaseString];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    [headerView addSubview:label];
    return headerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 40.0f;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == RCTriggerSettingsSectionTiming) {
        return @"How long a press waits for the next one before it counts. A shorter time responds sooner and needs quicker presses.";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == RCTriggerSettingsSectionNFC) return 2;
    return (NSInteger)[self timingRows].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    
    BOOL isValueRow = (indexPath.section == RCTriggerSettingsSectionNFC && indexPath.row == 1) || indexPath.section == RCTriggerSettingsSectionTiming;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:isValueRow ? UITableViewCellStyleValue1 : UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = [cm tweakColorForKey:@"blockBackground" defaultVal:0.12];
    
    UIView *selBg = [[UIView alloc] init];
    selBg.backgroundColor = [cm tweakColorForKey:@"selectionHighlight" defaultVal:0.15];
    cell.selectedBackgroundView = selBg;

    cell.layer.borderColor = [cm tweakColorForKey:@"borders" defaultVal:0.14].CGColor;
    cell.layer.borderWidth = 1.0;
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.layer.masksToBounds = YES;
    cell.textLabel.textColor = [UIColor labelColor];
    if (cell.detailTextLabel) {
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    
    if (indexPath.section == RCTriggerSettingsSectionNFC) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"NFC Scanning";
            _nfcSwitch = [[UISwitch alloc] init];
            _nfcSwitch.on = cm.nfcEnabled;
            [_nfcSwitch addTarget:self action:@selector(nfcToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _nfcSwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"NFC With Screen Off";
            cell.detailTextLabel.text = [self nfcWindowTitleForSeconds:cm.nfcScreenOffSeconds];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == RCTriggerSettingsSectionTiming) {
        NSDictionary *row = [self timingRows][indexPath.row];
        double (^get)(void) = row[@"get"];
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2f s", get()];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == RCTriggerSettingsSectionNFC && indexPath.row == 1) {
        [self chooseNFCWindowFromView:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == RCTriggerSettingsSectionTiming) {
        NSDictionary *row = [self timingRows][indexPath.row];
        double (^get)(void) = row[@"get"];
        void (^set)(double) = row[@"set"];
        [self chooseTimingNamed:row[@"title"] message:row[@"message"] values:row[@"values"] defaultValue:[row[@"default"] doubleValue]
                        current:get() from:[tableView cellForRowAtIndexPath:indexPath] apply:set];
    }
}

#pragma mark - Actions

- (void)nfcToggleChanged:(UISwitch *)sender {
    [RCConfigManager sharedManager].nfcEnabled = sender.on;
}

// A list of times in seconds, the current one ticked, for one of the Button Timing rows
- (void)chooseTimingNamed:(NSString *)name message:(NSString *)message values:(NSArray<NSNumber *> *)values defaultValue:(double)defaultValue
                  current:(double)current from:(UIView *)sourceView apply:(void (^)(double value))apply {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name message:message preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *value in values) {
        BOOL isCurrent = fabs(value.doubleValue - current) < 0.005;
        BOOL isDefault = fabs(value.doubleValue - defaultValue) < 0.005;
        NSString *title = [NSString stringWithFormat:@"%.2f s%@%@", value.doubleValue, isDefault ? @" (Default)" : @"", isCurrent ? @" \u2713" : @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            apply(value.doubleValue);
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// How long the NFC scan keeps going after the screen turns off. A window longer than the default
// asks first: it costs battery and keeps the reader in use.
static const double kRCNFCDefaultWindow = 120.0;

- (NSString *)nfcWindowTitleForSeconds:(double)seconds {
    if (seconds <= 0) return @"Off";
    if (seconds < 60) return [NSString stringWithFormat:@"%.0f s", seconds];
    NSInteger minutes = (NSInteger)lround(seconds / 60.0);
    return minutes == 1 ? @"1 min" : [NSString stringWithFormat:@"%ld min", (long)minutes];
}

- (void)chooseNFCWindowFromView:(UIView *)sourceView {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"NFC With Screen Off"
        message:@"How long a tag can still be tapped after the screen turns off. Off reads tags only while the screen is on."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *choices = @[@0, @30, @60, @120, @300, @600, @1800];
    NSArray<NSString *> *names = @[@"Off", @"30 Seconds", @"1 Minute", @"2 Minutes", @"5 Minutes", @"10 Minutes", @"30 Minutes"];
    for (NSUInteger i = 0; i < choices.count; i++) {
        double seconds = choices[i].doubleValue;
        BOOL isCurrent = fabs(seconds - cm.nfcScreenOffSeconds) < 1.0;
        NSString *title = [NSString stringWithFormat:@"%@%@%@", names[i], seconds == kRCNFCDefaultWindow ? @" (Default)" : @"", isCurrent ? @" \u2713" : @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (seconds <= kRCNFCDefaultWindow) {
                cm.nfcScreenOffSeconds = seconds;
                [self.tableView reloadData];
                return;
            }
            UIAlertController *warning = [UIAlertController alertControllerWithTitle:@"Longer Scan Window"
                message:@"The NFC reader stays in use while the screen is off. That costs battery (about 3% an hour on an iPhone 8) and warms the phone, and the system may switch the reader off for a few minutes. A longer window only helps when tags are tapped long after the screen goes dark."
                preferredStyle:UIAlertControllerStyleAlert];
            [warning addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Use %@", names[i]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *confirm) {
                cm.nfcScreenOffSeconds = seconds;
                [self.tableView reloadData];
            }]];
            [warning addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:warning animated:YES completion:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
