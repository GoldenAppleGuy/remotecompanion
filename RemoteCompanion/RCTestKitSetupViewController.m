#import "RCTestKitSetupViewController.h"
#import "RCTestKitViewController.h"
#import "RCConfigManager.h"

static const NSInteger kRCMaxStepCount = 5;

@interface RCTestKitSetupViewController ()
@property (nonatomic, copy) NSString *suite;
@property (nonatomic, strong) NSArray<NSString *> *groupNames;
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *groups; // steps: id, prompt, group, optional
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *counts; // only steps not done once
@end

@implementation RCTestKitSetupViewController

// Only counts other than 1 are kept, so steps added later start out once
- (NSString *)countsKey { return [@"RCTestKitStepCounts." stringByAppendingString:self.suite]; }

- (instancetype)initWithSuite:(NSString *)suite {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _suite = [suite copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [RCTestKitViewController displayNameForSuite:self.suite];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UIColor *bg = [cm tweakColorForKey:@"settingsBackground" defaultVal:[cm tweakValueForKey:@"mainBackground" defaultVal:0.09]];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    self.tableView.separatorColor = [cm tweakColorForKey:@"separators" defaultVal:0.30];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Start" style:UIBarButtonItemStyleDone target:self action:@selector(start)];
    self.navigationItem.rightBarButtonItem.enabled = NO;

    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:[self countsKey]];
    self.counts = [saved isKindOfClass:[NSDictionary class]] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    self.groupNames = @[];
    self.groups = @[];

    [RCTestKitViewController sendRequest:[@"suite/steps name=" stringByAppendingString:self.suite] completion:^(NSDictionary *json, NSError *error) {
        NSArray *steps = [json[@"steps"] isKindOfClass:[NSArray class]] ? json[@"steps"] : nil;
        if (!steps.count) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Load Steps"
                                                                           message:json[@"error"] ?: error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        // Groups in the order their first step comes
        NSMutableArray *names = [NSMutableArray array];
        NSMutableDictionary *byGroup = [NSMutableDictionary dictionary];
        for (NSDictionary *step in steps) {
            NSString *group = step[@"group"] ?: @"Other";
            if (!byGroup[group]) { byGroup[group] = [NSMutableArray array]; [names addObject:group]; }
            [byGroup[group] addObject:step];
        }
        NSMutableArray *groups = [NSMutableArray array];
        for (NSString *name in names) [groups addObject:byGroup[name]];
        self.groupNames = names;
        self.groups = groups;
        [self.tableView reloadData];
        [self updateStart];
    }];
}

#pragma mark - Counts

- (NSArray<NSDictionary *> *)allSteps {
    NSMutableArray *all = [NSMutableArray array];
    for (NSArray *group in self.groups) [all addObjectsFromArray:group];
    return all;
}

- (NSInteger)countFor:(NSString *)stepId {
    NSNumber *count = self.counts[stepId];
    return count ? MAX(0, MIN(kRCMaxStepCount, count.integerValue)) : 1;
}

- (void)setCount:(NSInteger)count for:(NSString *)stepId {
    if (count == 1) [self.counts removeObjectForKey:stepId];
    else self.counts[stepId] = @(count);
    [[NSUserDefaults standardUserDefaults] setObject:self.counts forKey:[self countsKey]];
}

static NSString *RCCountText(NSInteger count) {
    if (count == 0) return @"Off";
    return count == 1 ? @"Once" : [NSString stringWithFormat:@"%ld times", (long)count];
}

// The totals row and Start reflect the counts; only that row is reloaded, never the steps
- (void)updateStart {
    NSInteger steps = 0, runs = 0;
    for (NSDictionary *step in [self allSteps]) {
        NSInteger count = [self countFor:step[@"id"]];
        if (count) steps++;
        runs += count;
    }
    self.navigationItem.rightBarButtonItem.enabled = runs > 0;
    UITableViewCell *totals = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    totals.textLabel.text = [self totalsTextSteps:steps runs:runs];
}

- (NSString *)totalsTextSteps:(NSInteger)steps runs:(NSInteger)runs {
    if (runs == steps) return [NSString stringWithFormat:@"%ld of %lu Steps", (long)steps, (unsigned long)[self allSteps].count];
    return [NSString stringWithFormat:@"%ld Steps, %ld Runs", (long)steps, (long)runs];
}

- (void)allOrNone:(UISegmentedControl *)control {
    NSInteger count = control.selectedSegmentIndex == 0 ? 1 : 0;
    for (NSDictionary *step in [self allSteps]) [self setCount:count for:step[@"id"]];
    [self.tableView reloadData];
    [self updateStart];
}

- (void)stepperChanged:(UIStepper *)stepper {
    NSDictionary *step = [self stepForView:stepper];
    if (!step) return;
    [self setCount:(NSInteger)stepper.value for:step[@"id"]];
    [self showCount:(NSInteger)stepper.value forStep:step inCell:[self cellForView:stepper]];
    [self updateStart];
}

- (UITableViewCell *)cellForView:(UIView *)view {
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    return (UITableViewCell *)view;
}

- (NSDictionary *)stepForView:(UIView *)view {
    NSIndexPath *path = [self.tableView indexPathForCell:[self cellForView:view]];
    if (!path || path.section == 0) return nil;
    return self.groups[path.section - 1][path.row];
}

- (void)showCount:(NSInteger)count forStep:(NSDictionary *)step inCell:(UITableViewCell *)cell {
    // The count, then what sets the step apart (two steps can share a prompt)
    NSString *text = RCCountText(count);
    if ([step[@"optional"] boolValue]) text = [text stringByAppendingString:@" - optional, skipped after 15 s"];
    if ([step[@"note"] length]) text = [text stringByAppendingFormat:@"\n%@", step[@"note"]];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.text = text;
    cell.textLabel.textColor = count ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    [cell setNeedsLayout];
}

- (void)start {
    NSMutableArray *items = [NSMutableArray array];
    BOOL everyOnce = YES;
    for (NSDictionary *step in [self allSteps]) {
        NSInteger count = [self countFor:step[@"id"]];
        if (count != 1) everyOnce = NO;
        if (count == 1) [items addObject:step[@"id"]];
        else if (count > 1) [items addObject:[NSString stringWithFormat:@"%@:%ld", step[@"id"], (long)count]];
    }
    NSString *options = everyOnce ? @"" : [@"&steps=" stringByAppendingString:[items componentsJoinedByString:@","]];
    if (self.onStart) self.onStart(options);
}

#pragma mark - Table

- (UITableViewCell *)styledCellWithStyle:(UITableViewCellStyle)style {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];
    cell.backgroundColor = [cm tweakColorForKey:@"blockBackground" defaultVal:0.12];
    UIView *selection = [[UIView alloc] init];
    selection.backgroundColor = [cm tweakColorForKey:@"selectionHighlight" defaultVal:0.15];
    cell.selectedBackgroundView = selection;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1 + self.groups.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? nil : self.groupNames[section - 1];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    if ([self.suite isEqualToString:@"replay"]) {
        return @"The presses are sent by the tweak - leave the phone alone while it runs. A step's first run is exact; repeats move each gap by up to 25 ms. Your triggers are swapped for test ones - their actions don't run - and put back after. The volume may change and is put back. Power is limited so it can't start Emergency SOS, Siri or the power-off screen; Power steps run last and may lock the phone or take a screenshot.";
    }
    NSString *how = [self.suite isEqualToString:@"guided"]
        ? @"Steps done more than once come round again after the rest. Your triggers are swapped for test ones during the run - their actions don't run - and put back after."
        : @"Each input is done twice per run: stock (triggers off), then with the tweak; repeats come in a row. Presses may put the phone to sleep or take real screenshots.";
    return [how stringByAppendingString:@" To begin, go to the home screen and press Volume Up."];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : self.groups[section - 1].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [self styledCellWithStyle:UITableViewCellStyleDefault];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSInteger steps = 0, runs = 0;
        for (NSDictionary *step in [self allSteps]) {
            NSInteger count = [self countFor:step[@"id"]];
            if (count) steps++;
            runs += count;
        }
        cell.textLabel.text = [self totalsTextSteps:steps runs:runs];
        UISegmentedControl *all = [[UISegmentedControl alloc] initWithItems:@[@"All", @"None"]];
        all.momentary = YES;
        [all addTarget:self action:@selector(allOrNone:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = all;
        return cell;
    }
    NSDictionary *step = self.groups[indexPath.section - 1][indexPath.row];
    NSInteger count = [self countFor:step[@"id"]];
    UITableViewCell *cell = [self styledCellWithStyle:UITableViewCellStyleSubtitle];
    cell.textLabel.text = step[@"prompt"];
    [self showCount:count forStep:step inCell:cell];
    // Each row its own stepper: one view can't be the accessory of two cells
    UIStepper *stepper = [[UIStepper alloc] init];
    stepper.minimumValue = 0;
    stepper.maximumValue = kRCMaxStepCount;
    stepper.value = count;
    [stepper addTarget:self action:@selector(stepperChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = stepper;
    return cell;
}

// Tapping a step turns it off, or on once
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) return;
    NSDictionary *step = self.groups[indexPath.section - 1][indexPath.row];
    NSInteger count = [self countFor:step[@"id"]] ? 0 : 1;
    [self setCount:count for:step[@"id"]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    ((UIStepper *)cell.accessoryView).value = count;
    [self showCount:count forStep:step inCell:cell];
    [self updateStart];
}

@end
