#import "RCSettingsViewController.h"
#import "RCConfigManager.h"
#import "RCUITweaker.h"
#import "RCIntegrationsViewController.h"
#import "RCAdvancedSettingsViewController.h"
#import "RCBackupDiagnosticsViewController.h"
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <netinet/in.h>

@interface RCSettingsViewController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) UISwitch *webUISwitch;
@end

// Sections of the Settings table, in order
typedef NS_ENUM(NSInteger, RCSettingsSection) {
    RCSettingsSectionGeneral,
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

    // Footer lives at the bottom of the table content (tableFooterView) so it
    // only appears once you scroll to the bottom, instead of floating over content.
    [self setupFooterView];

    // Constraints - table fills the view, footer scrolls with content
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

- (void)setupFooterView {
    UIView *footerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 60)];
    footerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *appTitleLabel = [[UILabel alloc] init];
    appTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    appTitleLabel.textAlignment = NSTextAlignmentCenter;
    appTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    appTitleLabel.textColor = [UIColor secondaryLabelColor];
    appTitleLabel.text = @"RemoteCompanion";

    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.font = [UIFont systemFontOfSize:13];
    versionLabel.textColor = [UIColor secondaryLabelColor];

    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString *version = [infoDict objectForKey:@"CFBundleShortVersionString"];
    versionLabel.text = [NSString stringWithFormat:@"v%@", version];

    [footerView addSubview:appTitleLabel];
    [footerView addSubview:versionLabel];

    appTitleLabel.userInteractionEnabled = YES;
    versionLabel.userInteractionEnabled = YES;

    UITapGestureRecognizer *titleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openGitHub)];
    [appTitleLabel addGestureRecognizer:titleTap];

    UITapGestureRecognizer *versionTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openGitHub)];
    [versionLabel addGestureRecognizer:versionTap];

    [NSLayoutConstraint activateConstraints:@[
        [appTitleLabel.centerXAnchor constraintEqualToAnchor:footerView.centerXAnchor],
        [appTitleLabel.topAnchor constraintEqualToAnchor:footerView.topAnchor constant:10],
        [appTitleLabel.heightAnchor constraintEqualToConstant:20],

        [versionLabel.centerXAnchor constraintEqualToAnchor:footerView.centerXAnchor],
        [versionLabel.topAnchor constraintEqualToAnchor:appTitleLabel.bottomAnchor constant:0],
        [versionLabel.heightAnchor constraintEqualToConstant:16]
    ]];

    self.tableView.tableFooterView = footerView;
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

- (void)dismissSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Web UI URL

- (NSString *)deviceIPAddress {
    NSString *address = nil;
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([name isEqualToString:@"en0"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    break;
                }
                if (!address && [name isEqualToString:@"pdp_ip0"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    if (interfaces) freeifaddrs(interfaces);
    return address;
}

- (NSString *)webUIUrlString {
    NSString *ip = [self deviceIPAddress];
    if (ip.length) {
        return [NSString stringWithFormat:@"http://%@:8080", ip];
    }
    return @"http://localhost:8080";
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title;
    if (section == RCSettingsSectionGeneral) title = @"General";
    else if (section == RCSettingsSectionIntegrations) title = @"Integrations";
    else if (section == RCSettingsSectionAdvanced) title = @"Advanced Settings";
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
        return @"Enable the built-in Web UI to configure RemoteCompanion from a browser.";
    } else if (section == RCSettingsSectionIntegrations) {
        return @"Configure connections to external services and automations.";
    } else if (section == RCSettingsSectionAdvanced) {
        return @"NFC, banners, logging, and display options.";
    } else if (section == RCSettingsSectionBackupDiagnostics) {
        return @"Export or import your configuration, and run on-device diagnostics.";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == RCSettingsSectionGeneral) {
        return [RCConfigManager sharedManager].webUIEnabled ? 3 : 2;
    }
    return 1; // Integrations, Advanced Settings, Backup & Diagnostics
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    
    BOOL isLinkRow = (indexPath.section == RCSettingsSectionGeneral && indexPath.row == 2);
    UITableViewCellStyle style = isLinkRow ? UITableViewCellStyleValue1 : UITableViewCellStyleDefault;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];
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
            cell.textLabel.text = @"Web UI";
            _webUISwitch = [[UISwitch alloc] init];
            _webUISwitch.on = cm.webUIEnabled;
            [_webUISwitch addTarget:self action:@selector(webUIToggleChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = _webUISwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Open Web UI";
            cell.detailTextLabel.text = [self webUIUrlString];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
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
        cell.textLabel.text = @"Advanced Settings";
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

    if (indexPath.section == RCSettingsSectionGeneral && indexPath.row == 2) {
        [self openWebUI];
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

- (void)webUIToggleChanged:(UISwitch *)sender {
    [RCConfigManager sharedManager].webUIEnabled = sender.on;
    [self.tableView reloadData];
}

- (void)openWebUI {
    NSURL *url = [NSURL URLWithString:[self webUIUrlString]];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)openGitHub {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/saihgupr/RemoteCompanion"] options:@{} completionHandler:nil];
}

@end
