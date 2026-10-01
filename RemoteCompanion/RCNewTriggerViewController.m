#import "RCNewTriggerViewController.h"
#import "RCConfigManager.h"
#import "RCActionsViewController.h"

@interface RCNewTriggerViewController ()
@property (nonatomic, strong) NSArray<NSString *> *sectionTitles;
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
@property (nonatomic, copy) NSString *expandedTitle; // the group showing its children
@end

@implementation RCNewTriggerViewController

- (instancetype)initWithItems:(NSArray<NSDictionary *> *)items {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"New Trigger";
        NSMutableArray *titles = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
        for (NSDictionary *item in items) {
            NSString *section = item[@"section"] ?: @"Other";
            if (!groups[section]) { groups[section] = [NSMutableArray array]; [titles addObject:section]; }
            [groups[section] addObject:item];
        }
        NSMutableArray *sections = [NSMutableArray array];
        for (NSString *section in titles) [sections addObject:groups[section]];
        _sectionTitles = titles;
        _sections = sections;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = 52;
    RCConfigManager *cm = [RCConfigManager sharedManager];
    CGFloat mainBG = [cm tweakValueForKey:@"mainBackground" defaultVal:0.09];
    UIColor *bg = [cm tweakColorForKey:@"actionPickerBackground" defaultVal:mainBG];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    self.tableView.separatorColor = [cm tweakColorForKey:@"separators" defaultVal:0.30];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.delegate = self;
}

#pragma mark - Navigation

// The new trigger's action editor is showing (its setup screen finished, or it opened
// directly): this picker's job is done, so drop it from beneath the editor
- (void)navigationController:(UINavigationController *)nav didShowViewController:(UIViewController *)vc animated:(BOOL)animated {
    if (![nav.viewControllers containsObject:self]) {
        if (nav.delegate == self) nav.delegate = nil;
        return;
    }
    if (![vc isKindOfClass:[RCActionsViewController class]]) return;
    NSMutableArray *vcs = [nav.viewControllers mutableCopy];
    [vcs removeObject:self];
    nav.delegate = nil;
    [nav setViewControllers:vcs animated:NO];
}

#pragma mark - Rows

// A section's rows: each item, followed by its children when it's the expanded group
- (NSArray<NSDictionary *> *)rowsInSection:(NSInteger)section {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *item in self.sections[section]) {
        [rows addObject:@{ @"item": item, @"child": @NO }];
        if ([item[@"children"] isKindOfClass:[NSArray class]] && [item[@"title"] isEqualToString:self.expandedTitle]) {
            for (NSDictionary *child in item[@"children"]) [rows addObject:@{ @"item": child, @"child": @YES }];
        }
    }
    return rows;
}

- (NSIndexPath *)indexPathOfItemTitled:(NSString *)title {
    if (!title) return nil;
    for (NSInteger section = 0; section < (NSInteger)self.sections.count; section++) {
        NSArray *rows = [self rowsInSection:section];
        for (NSUInteger i = 0; i < rows.count; i++) {
            if (![rows[i][@"child"] boolValue] && [rows[i][@"item"][@"title"] isEqualToString:title]) return [NSIndexPath indexPathForRow:i inSection:section];
        }
    }
    return nil;
}

// Expands or collapses a group, inserting / deleting only the child rows so the rest of
// the list slides rather than reloading
- (void)setExpandedTitle:(NSString *)title animated:(BOOL)animated {
    NSMutableArray *before = [NSMutableArray array];
    for (NSInteger section = 0; section < (NSInteger)self.sections.count; section++) [before addObject:[self rowsInSection:section]];
    NSString *previous = self.expandedTitle;
    self.expandedTitle = title;
    NSMutableArray *deletes = [NSMutableArray array];
    NSMutableArray *inserts = [NSMutableArray array];
    for (NSInteger section = 0; section < (NSInteger)self.sections.count; section++) {
        NSArray *old = before[section];
        NSArray *now = [self rowsInSection:section];
        for (NSUInteger i = 0; i < old.count; i++) if ([old[i][@"child"] boolValue]) [deletes addObject:[NSIndexPath indexPathForRow:i inSection:section]];
        for (NSUInteger i = 0; i < now.count; i++) if ([now[i][@"child"] boolValue]) [inserts addObject:[NSIndexPath indexPathForRow:i inSection:section]];
    }
    [self.tableView performBatchUpdates:^{
        [self.tableView deleteRowsAtIndexPaths:deletes withRowAnimation:UITableViewRowAnimationTop];
        [self.tableView insertRowsAtIndexPaths:inserts withRowAnimation:UITableViewRowAnimationTop];
    } completion:nil];
    for (NSString *changed in @[previous ?: @"", title ?: @""]) {
        NSIndexPath *path = [self indexPathOfItemTitled:changed];
        UITableViewCell *cell = path ? [self.tableView cellForRowAtIndexPath:path] : nil;
        if ([cell.accessoryView isKindOfClass:[UIImageView class]]) {
            ((UIImageView *)cell.accessoryView).image = [UIImage systemImageNamed:[changed isEqualToString:self.expandedTitle] ? @"chevron.up" : @"chevron.down"];
        }
    }
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self rowsInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sectionTitles[section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    NSDictionary *row = [self rowsInSection:indexPath.section][indexPath.row];
    NSDictionary *item = row[@"item"];
    BOOL isChild = [row[@"child"] boolValue];

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = [cm tweakColorForKey:@"blockBackground" defaultVal:0.12];
    UIView *selBg = [[UIView alloc] init];
    selBg.backgroundColor = [cm tweakColorForKey:@"selectionHighlight" defaultVal:0.15];
    cell.selectedBackgroundView = selBg;
    cell.textLabel.text = item[@"title"];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.imageView.image = [UIImage systemImageNamed:item[@"icon"] ?: @"circle"];
    cell.imageView.tintColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = item[@"detail"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    if (isChild) {
        cell.indentationLevel = 1;
        cell.indentationWidth = 30;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (item[@"children"]) {
        BOOL expanded = [item[@"title"] isEqualToString:self.expandedTitle];
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:expanded ? @"chevron.up" : @"chevron.down"]];
        chevron.tintColor = [UIColor tertiaryLabelColor];
        cell.accessoryView = chevron;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = [self rowsInSection:indexPath.section][indexPath.row][@"item"];

    if (item[@"children"]) {
        BOOL collapsing = [item[@"title"] isEqualToString:self.expandedTitle];
        [self setExpandedTitle:collapsing ? nil : item[@"title"] animated:YES];
        if (!collapsing) {
            NSIndexPath *path = [self indexPathOfItemTitled:item[@"title"]];
            NSIndexPath *last = [NSIndexPath indexPathForRow:path.row + [item[@"children"] count] inSection:path.section];
            [tableView scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionNone animated:YES];
        }
        return;
    }

    void (^handler)(void) = item[@"handler"];
    if (handler) handler();
}

@end
