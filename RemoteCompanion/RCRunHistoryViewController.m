#import "RCRunHistoryViewController.h"
#import "RCConfigManager.h"
#import "RCServerClient.h"

// One run's details: each action it traced, with what happened there
@interface RCRunDetailViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *rows; // @[icon, title, detail]
@property (nonatomic, copy) NSString *footer;
@end

@implementation RCRunDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UIColor *bg = [cm tweakColorForKey:@"mainBackground" defaultVal:0.09];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(self.rows.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [cm tweakColorForKey:@"blockBackground" defaultVal:0.12];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (!self.rows.count) {
        cell.textLabel.text = @"No conditions or loops ran";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }
    NSArray *row = self.rows[indexPath.row];
    cell.imageView.image = [UIImage systemImageNamed:row[0]];
    cell.imageView.tintColor = [UIColor systemGrayColor];
    cell.textLabel.text = row[1];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = row[2];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

@end

@interface RCRunHistoryViewController ()
@property (nonatomic, copy) NSString *triggerKey;
@property (nonatomic, strong) NSArray<NSDictionary *> *runs;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation RCRunHistoryViewController

- (instancetype)initWithTriggerKey:(NSString *)triggerKey {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _triggerKey = [triggerKey copy];
        _runs = @[];
        self.title = @"Run History";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UIColor *bg = [cm tweakColorForKey:@"mainBackground" defaultVal:0.09];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    self.tableView.separatorColor = [cm tweakColorForKey:@"separators" defaultVal:0.30];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self updateMenu];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

// Keep (how many runs each trigger keeps) and Clear
- (void)updateMenu {
    __weak typeof(self) weakSelf = self;
    NSInteger keep = [RCConfigManager sharedManager].runHistoryCount;
    NSMutableArray *choices = [NSMutableArray array];
    for (NSNumber *count in @[@0, @5, @10, @25, @50]) {
        NSString *title = count.integerValue ? [NSString stringWithFormat:@"%@ Runs", count] : @"Off";
        UIAction *choice = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *a) {
            [RCConfigManager sharedManager].runHistoryCount = count.integerValue;
            [weakSelf updateMenu];
        }];
        choice.state = keep == count.integerValue ? UIMenuElementStateOn : UIMenuElementStateOff;
        [choices addObject:choice];
    }
    UIMenu *keepMenu = [UIMenu menuWithTitle:@"Keep" image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil options:0 children:choices];
    UIAction *clear = [UIAction actionWithTitle:@"Clear History" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *a) {
        [[RCServerClient sharedClient] executeCommand:[@"clear run history " stringByAppendingString:weakSelf.triggerKey] completion:^(NSString *output, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reload]; });
        }];
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"" children:@[keepMenu, clear]]];
}

- (void)reload {
    __weak typeof(self) weakSelf = self;
    [[RCServerClient sharedClient] executeCommand:[@"run history " stringByAppendingString:self.triggerKey] completion:^(NSString *output, NSError *error) {
        NSData *data = [output dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *runs = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.loaded = YES;
            strongSelf.runs = [runs isKindOfClass:[NSArray class]] ? runs : @[];
            [strongSelf.refreshControl endRefreshing];
            [strongSelf.tableView reloadData];
        });
    }];
}

#pragma mark - Describing a run

- (NSString *)durationText:(double)seconds {
    if (seconds < 10) return [NSString stringWithFormat:@"%.1f s", seconds];
    NSInteger s = (NSInteger)round(seconds);
    if (s < 60) return [NSString stringWithFormat:@"%ld s", (long)s];
    if (s < 3600) return [NSString stringWithFormat:@"%ld:%02ld", (long)(s / 60), (long)(s % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(s / 3600), (long)(s / 60 % 60), (long)(s % 60)];
}

- (NSString *)whenText:(double)started {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:started];
    NSString *time = [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    if ([[NSCalendar currentCalendar] isDateInToday:date]) return [NSString stringWithFormat:@"Today %@", time];
    if ([[NSCalendar currentCalendar] isDateInYesterday:date]) return [NSString stringWithFormat:@"Yesterday %@", time];
    return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
}

// The traced actions, in order: @[icon, the action's name, what happened]
- (NSArray<NSArray<NSString *> *> *)rowsForRun:(NSDictionary *)run {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    NSArray *actions = [cm actionsForTrigger:self.triggerKey];
    NSDictionary *trace = [run[@"trace"] isKindOfClass:[NSDictionary class]] ? run[@"trace"] : @{};
    NSArray *indexes = [trace.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [@(a.integerValue) compare:@(b.integerValue)]; }];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *index in indexes) {
        NSDictionary *entry = trace[index];
        NSInteger i = index.integerValue;
        id action = i < (NSInteger)actions.count ? actions[i] : nil;
        NSString *name = action ? [cm nameForCommand:action truncate:YES] : [NSString stringWithFormat:@"Action %ld (since removed)", (long)i + 1];
        NSString *icon = action ? [cm iconForCommand:action] : @"questionmark.circle";
        if ([icon hasPrefix:@"USER_APP:"]) icon = @"app";
        NSMutableArray *parts = [NSMutableArray array];
        NSInteger yes = [entry[@"true"] integerValue], no = [entry[@"false"] integerValue];
        if (yes + no == 1) [parts addObject:yes ? @"True" : @"False"];
        else if (yes + no > 1) [parts addObject:[NSString stringWithFormat:@"True %ld×, False %ld×", (long)yes, (long)no]];
        if (entry[@"rounds"]) {
            NSInteger rounds = [entry[@"rounds"] integerValue];
            [parts addObject:rounds == 0 ? @"Didn't run" : [NSString stringWithFormat:@"%ld round%@", (long)rounds, rounds == 1 ? @"" : @"s"]];
        }
        if ([entry[@"cap"] boolValue]) [parts addObject:@"Stopped at the 1,000-round limit"];
        if (entry[@"exit"]) [parts addObject:[entry[@"exit"] integerValue] == 1 ? @"Left the loop" : [NSString stringWithFormat:@"Left the loop %@×", entry[@"exit"]]];
        if (entry[@"met"]) [parts addObject:[NSString stringWithFormat:@"%@ after %@", [entry[@"met"] boolValue] ? @"Met" : @"Time limit reached", [self durationText:[entry[@"seconds"] doubleValue]]]];
        [rows addObject:@[icon ?: @"circle", name ?: @"", [parts componentsJoinedByString:@" · "]]];
    }
    return rows;
}

- (NSString *)summaryForRun:(NSDictionary *)run {
    NSString *outcome = [run[@"outcome"] isEqual:@"stopped"] ? @"Stopped" : @"Finished";
    if ([run[@"test"] boolValue]) outcome = [@"Test · " stringByAppendingString:outcome];
    NSArray *rows = [self rowsForRun:run];
    if (!rows.count) return outcome;
    NSMutableArray *bits = [NSMutableArray arrayWithObject:outcome];
    for (NSArray *row in rows) if ([row[2] length]) [bits addObject:row[2]];
    return [bits componentsJoinedByString:@" · "];
}

#pragma mark - Rows

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(self.runs.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSInteger keep = [RCConfigManager sharedManager].runHistoryCount;
    if (keep == 0) return @"Run History is off. Turn it on with Keep in the ••• menu.";
    return [NSString stringWithFormat:@"The last %ld runs are kept. Tap a run to see the conditions and loops it ran.", (long)keep];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [cm tweakColorForKey:@"blockBackground" defaultVal:0.12];
    UIView *selBg = [[UIView alloc] init];
    selBg.backgroundColor = [cm tweakColorForKey:@"selectionHighlight" defaultVal:0.15];
    cell.selectedBackgroundView = selBg;
    if (!self.runs.count) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = self.loaded ? @"No runs yet" : @"Loading…";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }
    NSDictionary *run = self.runs[indexPath.row];
    BOOL stopped = [run[@"outcome"] isEqual:@"stopped"];
    cell.imageView.image = [UIImage systemImageNamed:stopped ? @"stop.circle" : @"checkmark.circle"];
    cell.imageView.tintColor = stopped ? [UIColor systemOrangeColor] : [UIColor systemGreenColor];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", [self whenText:[run[@"started"] doubleValue]], [self durationText:[run[@"seconds"] doubleValue]]];
    cell.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = [self summaryForRun:run];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.runs.count > 0;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.runs.count) return;
    NSDictionary *run = self.runs[indexPath.row];
    RCRunDetailViewController *detail = [[RCRunDetailViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    detail.title = [self whenText:[run[@"started"] doubleValue]];
    detail.rows = [self rowsForRun:run];
    detail.footer = [NSString stringWithFormat:@"%@ after %@.%@", [run[@"outcome"] isEqual:@"stopped"] ? @"Stopped" : @"Finished",
                     [self durationText:[run[@"seconds"] doubleValue]],
                     [run[@"test"] boolValue] ? @" A test run from the actions page." : @""];
    [self.navigationController pushViewController:detail animated:YES];
}

@end
