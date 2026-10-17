#import "RCAddOnsViewController.h"
#import "RCConfigManager.h"
#import "RCServerClient.h"
#import "RCAddOnCatalog.h"

static NSString *s_summary;

@interface RCAddOnsViewController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *loaded;   // {name, detail}
@property (nonatomic, copy) NSArray<NSString *> *absent;
@property (nonatomic, copy) NSArray<NSString *> *problems;
@property (nonatomic, assign) BOOL didLoad;
@end

@implementation RCAddOnsViewController

+ (NSString *)cachedSummary {
    return s_summary;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Add-ons";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.tintColor = [UIColor labelColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Reload" style:UIBarButtonItemStylePlain target:self action:@selector(reload)];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 10;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    RCConfigManager *cm = [RCConfigManager sharedManager];
    CGFloat mainBG = [cm tweakValueForKey:@"mainBackground" defaultVal:0.09];
    UIColor *settingsBG = [cm tweakColorForKey:@"settingsBackground" defaultVal:mainBG];
    self.view.backgroundColor = settingsBG;
    self.tableView.backgroundColor = settingsBG;
    self.tableView.separatorColor = [cm tweakColorForKey:@"separators" defaultVal:0.30];
    [self reload];
}

#pragma mark - Loading

// "add-ons reload" lines: "Name (id): N actions", "Name: not installed", "Problem: file: reason"
- (void)reload {
    [[RCServerClient sharedClient] executeCommand:@"addons reload" completion:^(NSString *output, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *loaded = [NSMutableArray array], *absent = [NSMutableArray array], *problems = [NSMutableArray array];
            for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@"Problem: "]) {
                    [problems addObject:[line substringFromIndex:9]];
                } else if ([line hasSuffix:@": not installed"]) {
                    [absent addObject:[line substringToIndex:line.length - 15]];
                } else if ([line containsString:@" ("] && [line containsString:@"): "]) {
                    NSRange open = [line rangeOfString:@" (" options:NSBackwardsSearch];
                    NSRange close = [line rangeOfString:@"): " options:NSBackwardsSearch];
                    if (open.location == NSNotFound || close.location == NSNotFound || close.location < open.location) continue;
                    NSString *name = [line substringToIndex:open.location];
                    NSString *identifier = [line substringWithRange:NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))];
                    NSString *actions = [line substringFromIndex:NSMaxRange(close)];
                    [loaded addObject:@[name, [NSString stringWithFormat:@"%@ · %@", identifier, actions]]];
                }
            }
            self.didLoad = !error && output.length;
            self.loaded = loaded;
            self.absent = absent;
            self.problems = problems;
            s_summary = !self.didLoad ? nil : problems.count ? [NSString stringWithFormat:@"%lu problem%@", (unsigned long)problems.count, problems.count == 1 ? @"" : @"s"]
                      : loaded.count ? [NSString stringWithFormat:@"%lu loaded", (unsigned long)loaded.count] : @"None";
            [self.tableView reloadData];
        });
    }];
}

#pragma mark - Table view

- (NSArray<NSDictionary *> *)sections {
    NSMutableArray *sections = [NSMutableArray array];
    if (self.loaded.count) [sections addObject:@{@"title": @"Loaded", @"kind": @"loaded"}];
    if (self.absent.count) [sections addObject:@{@"title": @"Not Installed", @"kind": @"absent"}];
    if (self.problems.count) [sections addObject:@{@"title": @"Problems", @"kind": @"problems"}];
    return sections;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return MAX(1, (NSInteger)[self sections].count);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *sections = [self sections];
    if (!sections.count) return 1;
    NSString *kind = sections[section][@"kind"];
    return [kind isEqualToString:@"loaded"] ? self.loaded.count : [kind isEqualToString:@"absent"] ? self.absent.count : self.problems.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSArray *sections = [self sections];
    return sections.count ? sections[section][@"title"] : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [self sections].count ? nil : (self.didLoad ? @"JSON files in /var/jb/Library/RemoteCompanion/AddOns add actions, conditions and banners." : nil);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [cm tweakColorForKey:@"blockBackground" defaultVal:0.12];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.numberOfLines = 0;

    NSArray *sections = [self sections];
    if (!sections.count) {
        cell.textLabel.text = self.didLoad ? @"None" : @"Unavailable";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }
    NSString *kind = sections[indexPath.section][@"kind"];
    if ([kind isEqualToString:@"loaded"]) {
        cell.textLabel.text = self.loaded[indexPath.row][0];
        cell.detailTextLabel.text = self.loaded[indexPath.row][1];
        cell.imageView.image = [RCAddOnCatalog iconImageForAddOnNamed:self.loaded[indexPath.row][0]] ?: [UIImage systemImageNamed:[RCAddOnCatalog iconForAddOnNamed:self.loaded[indexPath.row][0]]] ?: [UIImage systemImageNamed:@"puzzlepiece.extension"];
        cell.imageView.tintColor = [UIColor systemGreenColor];
    } else if ([kind isEqualToString:@"absent"]) {
        cell.textLabel.text = self.absent[indexPath.row];
        cell.imageView.image = [UIImage systemImageNamed:@"puzzlepiece.extension"];
        cell.imageView.tintColor = [UIColor secondaryLabelColor];
    } else {
        // "file.json: reason"
        NSString *problem = self.problems[indexPath.row];
        NSRange colon = [problem rangeOfString:@": "];
        cell.textLabel.text = colon.location == NSNotFound ? problem : [problem substringToIndex:colon.location];
        cell.detailTextLabel.text = colon.location == NSNotFound ? nil : [problem substringFromIndex:NSMaxRange(colon)];
        cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        cell.imageView.tintColor = [UIColor systemOrangeColor];
    }
    return cell;
}

@end
