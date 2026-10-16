#import "RCSettingsViewController.h"
#import "RCConfigManager.h"
#import "RCUITweaker.h"
#import "RCIntegrationsViewController.h"
#import "RCBannersViewController.h"
#import "RCTestKitViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface RCSettingsViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *appTitleLabel;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) UISwitch *nfcSwitch;
@property (nonatomic, strong) UISwitch *webUISwitch;
@end

// Sections of the Settings table, in order
typedef NS_ENUM(NSInteger, RCSettingsSection) {
    RCSettingsSectionGeneral,
    RCSettingsSectionTiming,
    RCSettingsSectionIntegrations,
    RCSettingsSectionBackup,
    RCSettingsSectionDiagnostics,
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
        @"values": @[@0.25, @0.30, @0.35, @0.40, @0.50, @0.60, @0.70], @"default": @0.40,
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title;
    if (section == RCSettingsSectionGeneral) title = @"General";
    else if (section == RCSettingsSectionTiming) title = @"Button Timing";
    else if (section == RCSettingsSectionIntegrations) title = @"Integrations";
    else if (section == RCSettingsSectionDiagnostics) title = @"Diagnostics";
    else title = @"Backup";
    
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
    } else if (section == RCSettingsSectionTiming) {
        return @"How long a press waits for the next one before it counts. A shorter time responds sooner and needs quicker presses.";
    } else if (section == RCSettingsSectionIntegrations) {
        return @"Configure connections to external services and automations.";
    } else if (section == RCSettingsSectionBackup) {
        return @"Export your configuration to share or backup. Import to restore.";
    } else if (section == RCSettingsSectionDiagnostics) {
        return @"Tests RemoteCompanion on this device and shares the results.";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == RCSettingsSectionGeneral) return 5; // Master + NFC + WebUI + Banners + Logging
    if (section == RCSettingsSectionTiming) return (NSInteger)[self timingRows].count;
    if (section == RCSettingsSectionIntegrations) return 1; // Integrations Submenu Row
    if (section == RCSettingsSectionDiagnostics) return 1;  // Test Kit
    return 2; // Export, Import
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    
    BOOL isValueRow = (indexPath.section == RCSettingsSectionGeneral && indexPath.row >= 3) || indexPath.section == RCSettingsSectionTiming; // Banners, Logging, the timings
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
            cell.textLabel.text = @"NFC Scanning";
            _nfcSwitch = [[UISwitch alloc] init];
            _nfcSwitch.on = cm.nfcEnabled;
            [_nfcSwitch addTarget:self action:@selector(nfcToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _nfcSwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Web UI";
            _webUISwitch = [[UISwitch alloc] init];
            _webUISwitch.on = cm.webUIEnabled;
            [_webUISwitch addTarget:self action:@selector(webUIToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _webUISwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"Banners";
            NSUInteger count = [RCBannersViewController checkedCount];
            cell.detailTextLabel.text = count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : @"Off";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"Logging";
            cell.detailTextLabel.text = [cm.logLevel capitalizedString];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == RCSettingsSectionTiming) {
        NSDictionary *row = [self timingRows][indexPath.row];
        double (^get)(void) = row[@"get"];
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2f s", get()];
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
    } else if (indexPath.section == RCSettingsSectionDiagnostics) {
        cell.textLabel.text = @"Test Kit";
        cell.imageView.image = [UIImage systemImageNamed:@"checklist"] ?: [UIImage systemImageNamed:@"list.bullet.rectangle"]; // checklist: iOS 15+
        cell.imageView.tintColor = [UIColor systemTealColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Export Configuration";
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
            cell.imageView.tintColor = [UIColor systemBlueColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"Import Configuration";
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
            cell.imageView.tintColor = [UIColor systemGreenColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == RCSettingsSectionGeneral && indexPath.row == 3) {
        [self.navigationController pushViewController:[[RCBannersViewController alloc] init] animated:YES];
    } else if (indexPath.section == RCSettingsSectionGeneral && indexPath.row == 4) {
        [self chooseLogLevelFromView:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == RCSettingsSectionTiming) {
        NSDictionary *row = [self timingRows][indexPath.row];
        double (^get)(void) = row[@"get"];
        void (^set)(double) = row[@"set"];
        [self chooseTimingNamed:row[@"title"] message:row[@"message"] values:row[@"values"] defaultValue:[row[@"default"] doubleValue]
                        current:get() from:[tableView cellForRowAtIndexPath:indexPath] apply:set];
    } else if (indexPath.section == RCSettingsSectionIntegrations) {
        RCIntegrationsViewController *integrationsVC = [[RCIntegrationsViewController alloc] init];
        [self.navigationController pushViewController:integrationsVC animated:YES];
    } else if (indexPath.section == RCSettingsSectionDiagnostics) {
        [self.navigationController pushViewController:[[RCTestKitViewController alloc] init] animated:YES];
    } else if (indexPath.section == RCSettingsSectionBackup) {
        if (indexPath.row == 0) {
            [self exportConfig];
        } else {
            [self importConfig];
        }
    }
}

#pragma mark - Actions

- (void)masterToggleChanged:(UISwitch *)sender {
    [RCConfigManager sharedManager].masterEnabled = sender.on;
}

- (void)nfcToggleChanged:(UISwitch *)sender {
    [RCConfigManager sharedManager].nfcEnabled = sender.on;
}

- (void)webUIToggleChanged:(UISwitch *)sender {
    [RCConfigManager sharedManager].webUIEnabled = sender.on;
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

- (void)exportConfig {
    NSData *jsonData = [[RCConfigManager sharedManager] exportConfigAsJSON];
    if (!jsonData) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export Failed" message:@"Could not export configuration" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyyMMdd_HHmm"];
    NSString *dateStr = [df stringFromDate:[NSDate date]];
    if (!dateStr) dateStr = @"backup";
    
    NSString *filename = [NSString stringWithFormat:@"rc_config_%@.json", dateStr];
    
    // Use system /tmp directly to avoid sandbox confusion for system app
    NSString *exportPath = [@"/tmp" stringByAppendingPathComponent:filename];
    
    NSError *writeError = nil;
    BOOL written = [jsonData writeToFile:exportPath options:NSDataWritingAtomic error:&writeError];
    
    if (!written || writeError) {
        NSLog(@"[RemoteCompanion] Error writing export file: %@", writeError);
        // Show exact path in alert for debugging
        NSString *debugMsg = [NSString stringWithFormat:@"Failed to write to:\n%@\n\nError: %@", exportPath, writeError.localizedDescription];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export Error" message:debugMsg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy Path" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [UIPasteboard generalPasteboard].string = exportPath;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSURL *fileURL = [NSURL fileURLWithPath:exportPath];
    if (!fileURL) {
         NSLog(@"[RemoteCompanion] Error: fileURL is nil");
         return;
    }
    
    // Use share sheet instead of document picker to avoid glitchy loading indicator
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
    activityVC.modalPresentationStyle = UIModalPresentationFormSheet;
    
    // Success callback when user saves the file
    activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *error) {
        if (completed) {
            NSLog(@"[RemoteCompanion] Export successful via: %@", activityType);
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export Successful" message:@"Configuration file has been saved." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    };
    
    [self presentViewController:activityVC animated:YES completion:nil];
}

- (void)importConfig {
    // iOS 14+ supported
    NSArray *types = @[[UTType typeWithIdentifier:@"public.json"], [UTType typeWithIdentifier:@"public.plain-text"]];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openGitHub {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/saihgupr/RemoteCompanion"] options:@{} completionHandler:nil];
}

#pragma mark - UIDocumentPickerDelegate (Import only)

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    
    NSLog(@"[RemoteCompanion] Import selected URL: %@", url);
    
    // Security scoped access is mandatory for 'Opening' mode
    BOOL accessing = [url startAccessingSecurityScopedResource];
    
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    
    if (accessing) {
        [url stopAccessingSecurityScopedResource];
    }
    
    if (!data) {
        NSLog(@"[RemoteCompanion] Failed to read file: %@", readError);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Failed" message:[NSString stringWithFormat:@"Could not read file: %@", readError.localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSError *error = nil;
    BOOL success = [[RCConfigManager sharedManager] importConfigFromJSON:data error:&error];
    
    if (success) {
        _masterSwitch.on = [RCConfigManager sharedManager].masterEnabled;
        _nfcSwitch.on = [RCConfigManager sharedManager].nfcEnabled;
        _webUISwitch.on = [RCConfigManager sharedManager].webUIEnabled;
        [self.tableView reloadData];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Successful" message:@"Configuration restored. Return to Triggers to see changes." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        NSLog(@"[RemoteCompanion] Import Parsing Failed: %@", error);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Failed" message:error.localizedDescription ?: @"Invalid configuration file" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    NSLog(@"[RemoteCompanion] Import cancelled by user");
}

@end
