#import "RCSettingsViewController.h"
#import "RCConfigManager.h"
#import "RCUITweaker.h"
#import "RCIntegrationsViewController.h"
#import "RCBannersViewController.h"
#import "RCTriggerSettingsViewController.h"
#import "RCAdvancedSettingsViewController.h"
#import "RCBackupDiagnosticsViewController.h"

@interface RCSettingsViewController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *appTitleLabel;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) UISwitch *wrapLongNamesSwitch;
@end

// Sections of the Settings table, in order
typedef NS_ENUM(NSInteger, RCSettingsSection) {
    RCSettingsSectionGeneral,
    RCSettingsSectionTriggers,
    RCSettingsSectionIntegrations,
    RCSettingsSectionAdvanced,
    RCSettingsSectionBackupDiagnostics,
};

@implementation RCSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Settings";
    
    // Enable Large Titles
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.tintColor = [UIColor labelColor];

    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    // Close button
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissSettings)];
    
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
    
    // Setup App Title Label (Sticky Bottom)
    UILabel *appTitleLabel = [[UILabel alloc] init];
    appTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    appTitleLabel.textAlignment = NSTextAlignmentCenter;
    appTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    appTitleLabel.textColor = [UIColor secondaryLabelColor];
    appTitleLabel.text = @"RemoteCompanion";
    [self.view addSubview:appTitleLabel];

    // Setup Version Label (Sticky Bottom)
    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.font = [UIFont systemFontOfSize:13];
    versionLabel.textColor = [UIColor secondaryLabelColor];
    
    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString *version = [infoDict objectForKey:@"CFBundleShortVersionString"];
    versionLabel.text = [NSString stringWithFormat:@"v%@", version];
    [self.view addSubview:versionLabel];
    
    // Add Tap Gesture to Footer Labels
    appTitleLabel.userInteractionEnabled = YES;
    versionLabel.userInteractionEnabled = YES;
    
    UITapGestureRecognizer *titleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openGitHub)];
    [appTitleLabel addGestureRecognizer:titleTap];
    
    UITapGestureRecognizer *versionTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openGitHub)];
    [versionLabel addGestureRecognizer:versionTap];
    
    // Constraints for Sticky Footer
    [NSLayoutConstraint activateConstraints:@[
        [versionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [versionLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-10],
        
        [appTitleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [appTitleLabel.bottomAnchor constraintEqualToAnchor:versionLabel.topAnchor constant:-2]
    ]];
    
    // Constraints
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // The table view ends above the footer labels
        [self.tableView.bottomAnchor constraintEqualToAnchor:appTitleLabel.topAnchor constant:-10]
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

- (void)dismissSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title;
    if (section == RCSettingsSectionGeneral) title = @"General";
    else if (section == RCSettingsSectionTriggers) title = @"Triggers & Buttons";
    else if (section == RCSettingsSectionIntegrations) title = @"Integrations";
    else if (section == RCSettingsSectionAdvanced) title = @"Advanced";
    else title = @"Backup & Diagnostics";
    
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
    if (section == RCSettingsSectionGeneral) {
        return nil;
    } else if (section == RCSettingsSectionTriggers) {
        return @"Button timing and NFC scanning options.";
    } else if (section == RCSettingsSectionIntegrations) {
        return @"Configure connections to external services and automations.";
    } else if (section == RCSettingsSectionAdvanced) {
        return @"Network and debugging options.";
    } else if (section == RCSettingsSectionBackupDiagnostics) {
        return @"Export or import your configuration, and run on-device diagnostics.";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == RCSettingsSectionGeneral) return 3; // Master + Banners + Wrap Long Names
    return 1; // Triggers & Buttons, Integrations, Advanced, Backup & Diagnostics
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    
    BOOL isValueRow = (indexPath.section == RCSettingsSectionGeneral && indexPath.row == 1);
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
    
    if (indexPath.section == RCSettingsSectionGeneral) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Enable All Triggers";
            _masterSwitch = [[UISwitch alloc] init];
            _masterSwitch.on = cm.masterEnabled;
            [_masterSwitch addTarget:self action:@selector(masterToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _masterSwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Banners";
            NSUInteger count = [RCBannersViewController checkedCount];
            cell.detailTextLabel.text = count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : @"Off";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Wrap Long Names";
            _wrapLongNamesSwitch = [[UISwitch alloc] init];
            _wrapLongNamesSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"RCWrapLongNamesEnabled"];
            [_wrapLongNamesSwitch addTarget:self action:@selector(wrapLongNamesToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _wrapLongNamesSwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (indexPath.section == RCSettingsSectionTriggers) {
        cell.textLabel.text = @"Triggers & Buttons";
        UIImage *img = [UIImage systemImageNamed:@"hand.tap.fill"];
        if (!img) img = [UIImage systemImageNamed:@"circle.grid.2x2"];
        cell.imageView.image = img;
        cell.imageView.tintColor = [UIColor systemOrangeColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == RCSettingsSectionIntegrations) {
        cell.textLabel.text = @"Integrations";
        UIImage *puzzleImg = [UIImage systemImageNamed:@"puzzlepiece.extension.fill"];
        if (!puzzleImg) {
            puzzleImg = [UIImage systemImageNamed:@"network"];
        }
        cell.imageView.image = puzzleImg;
        cell.imageView.tintColor = [UIColor systemIndigoColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == RCSettingsSectionAdvanced) {
        cell.textLabel.text = @"Advanced";
        UIImage *img = [UIImage systemImageNamed:@"gearshape.2.fill"];
        if (!img) img = [UIImage systemImageNamed:@"gearshape"];
        cell.imageView.image = img;
        cell.imageView.tintColor = [UIColor systemPurpleColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == RCSettingsSectionBackupDiagnostics) {
        cell.textLabel.text = @"Backup & Diagnostics";
        UIImage *img = [UIImage systemImageNamed:@"externaldrive.fill"];
        if (!img) img = [UIImage systemImageNamed:@"folder"];
        cell.imageView.image = img;
        cell.imageView.tintColor = [UIColor systemTealColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == RCSettingsSectionGeneral && indexPath.row == 1) {
        [self.navigationController pushViewController:[[RCBannersViewController alloc] init] animated:YES];
    } else if (indexPath.section == RCSettingsSectionTriggers) {
        [self.navigationController pushViewController:[[RCTriggerSettingsViewController alloc] init] animated:YES];
    } else if (indexPath.section == RCSettingsSectionIntegrations) {
        RCIntegrationsViewController *integrationsVC = [[RCIntegrationsViewController alloc] init];
        [self.navigationController pushViewController:integrationsVC animated:YES];
    } else if (indexPath.section == RCSettingsSectionAdvanced) {
        [self.navigationController pushViewController:[[RCAdvancedSettingsViewController alloc] init] animated:YES];
    } else if (indexPath.section == RCSettingsSectionBackupDiagnostics) {
        [self.navigationController pushViewController:[[RCBackupDiagnosticsViewController alloc] init] animated:YES];
    }
}

#pragma mark - Actions

- (void)masterToggleChanged:(UISwitch *)sender {
    [RCConfigManager sharedManager].masterEnabled = sender.on;
}

- (void)wrapLongNamesToggleChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:@"RCWrapLongNamesEnabled"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RCWrapLongNamesSettingChanged" object:nil];
}

- (void)openGitHub {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/saihgupr/RemoteCompanion"] options:@{} completionHandler:nil];
}

@end
