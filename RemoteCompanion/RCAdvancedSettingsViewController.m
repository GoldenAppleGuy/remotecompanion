#import "RCAdvancedSettingsViewController.h"
#import "RCConfigManager.h"
#import "RCUITweaker.h"
#import "RCBannersViewController.h"

@interface RCAdvancedSettingsViewController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISwitch *nfcSwitch;
@property (nonatomic, strong) UISwitch *webUISwitch;
@property (nonatomic, strong) UISwitch *wrapLongNamesSwitch;
@end

// Sections of the Advanced Settings table, in order
typedef NS_ENUM(NSInteger, RCAdvancedSettingsSection) {
    RCAdvancedSettingsSectionBanners,
    RCAdvancedSettingsSectionNFC,
    RCAdvancedSettingsSectionOptions,
};

@implementation RCAdvancedSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Advanced Settings";
    
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
    [self.tableView reloadData]; // refresh the Banners count after returning from it
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

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title;
    if (section == RCAdvancedSettingsSectionBanners) title = @"Banners";
    else if (section == RCAdvancedSettingsSectionNFC) title = @"NFC";
    else title = @"Options";
    
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
    if (section == RCAdvancedSettingsSectionBanners) {
        return @"Actions that show a banner when a trigger runs them.";
    } else if (section == RCAdvancedSettingsSectionNFC) {
        return @"NFC scanning options.";
    } else if (section == RCAdvancedSettingsSectionOptions) {
        return @"Web UI, logging, and display options.";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == RCAdvancedSettingsSectionBanners) return 1;
    if (section == RCAdvancedSettingsSectionNFC) return 2;
    return 3; // Web UI, Wrap Long Names, Logging
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    
    BOOL isValueRow = (indexPath.section == RCAdvancedSettingsSectionBanners) ||
                      (indexPath.section == RCAdvancedSettingsSectionNFC && indexPath.row == 1) ||
                      (indexPath.section == RCAdvancedSettingsSectionOptions && indexPath.row == 2);
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
    
    if (indexPath.section == RCAdvancedSettingsSectionBanners) {
        cell.textLabel.text = @"Banners";
        NSUInteger count = [RCBannersViewController checkedCount];
        cell.detailTextLabel.text = count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : @"Off";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == RCAdvancedSettingsSectionNFC) {
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
    } else if (indexPath.section == RCAdvancedSettingsSectionOptions) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Web UI";
            _webUISwitch = [[UISwitch alloc] init];
            _webUISwitch.on = cm.webUIEnabled;
            [_webUISwitch addTarget:self action:@selector(webUIToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _webUISwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Wrap Long Names";
            _wrapLongNamesSwitch = [[UISwitch alloc] init];
            _wrapLongNamesSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"RCWrapLongNamesEnabled"];
            [_wrapLongNamesSwitch addTarget:self action:@selector(wrapLongNamesToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _wrapLongNamesSwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Logging";
            cell.detailTextLabel.text = [cm.logLevel capitalizedString];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == RCAdvancedSettingsSectionBanners) {
        [self.navigationController pushViewController:[[RCBannersViewController alloc] init] animated:YES];
    } else if (indexPath.section == RCAdvancedSettingsSectionNFC && indexPath.row == 1) {
        [self chooseNFCWindowFromView:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == RCAdvancedSettingsSectionOptions && indexPath.row == 2) {
        [self chooseLogLevelFromView:[tableView cellForRowAtIndexPath:indexPath]];
    }
}

#pragma mark - Actions

- (void)nfcToggleChanged:(UISwitch *)sender {
    [RCConfigManager sharedManager].nfcEnabled = sender.on;
}

- (void)webUIToggleChanged:(UISwitch *)sender {
    [RCConfigManager sharedManager].webUIEnabled = sender.on;
}

- (void)wrapLongNamesToggleChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:@"RCWrapLongNamesEnabled"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RCWrapLongNamesSettingChanged" object:nil];
}

- (void)chooseLogLevelFromView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Logging"
        message:@"Minimal records triggers, their actions and conditions, and errors. Full records every step, for tracking down a problem."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *current = [RCConfigManager sharedManager].logLevel;
    for (NSString *level in @[@"off", @"minimal", @"full"]) {
        NSString *title = [level isEqualToString:current] ? [NSString stringWithFormat:@"%@ \u2713", [level capitalizedString]] : [level capitalizedString];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [RCConfigManager sharedManager].logLevel = level;
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
