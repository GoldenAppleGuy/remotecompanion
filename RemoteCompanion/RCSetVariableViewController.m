#import "RCSetVariableViewController.h"
#import "RCConfigManager.h"
#import "RCServerClient.h"

typedef NS_ENUM(NSInteger, RCSetVariableSection) {
    RCSetVariableSectionName = 0,
    RCSetVariableSectionKind,
    RCSetVariableSectionFields,
    RCSetVariableSectionScope,
    RCSetVariableSectionCount
};

// The kinds of change: code, tile title, icon, footer, and fields (label, key in the action, placeholder)
static NSArray<NSDictionary *> *RCSetVariableKindList(void) {
    static NSArray *kinds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *numberHint = @"Number or {variable}";
        kinds = @[
            @{ @"op": @"set", @"title": @"Set", @"icon": @"equal",
               @"message": @"Text or a number. It can include {variable} and {round}.",
               @"fields": @[@[@"Value", @"value", @"Text, number or {variable}"]] },
            @{ @"op": @"add", @"title": @"Add", @"icon": @"plus",
               @"message": @"Adds to the number. A variable without a value counts as 0.",
               @"fields": @[@[@"Amount", @"value", numberHint]] },
            @{ @"op": @"subtract", @"title": @"Subtract", @"icon": @"minus",
               @"message": @"Subtracts from the number. A variable without a value counts as 0.",
               @"fields": @[@[@"Amount", @"value", numberHint]] },
            @{ @"op": @"multiply", @"title": @"Multiply", @"icon": @"multiply",
               @"message": @"Multiplies the number.",
               @"fields": @[@[@"By", @"value", numberHint]] },
            @{ @"op": @"divide", @"title": @"Divide", @"icon": @"divide",
               @"message": @"Divides the number. Dividing by 0 leaves it unchanged.",
               @"fields": @[@[@"By", @"value", numberHint]] },
            @{ @"op": @"round", @"title": @"Round", @"icon": @"number",
               @"message": @"Rounds the number to the given decimals.",
               @"fields": @[@[@"Decimals", @"value", @"0"]] },
            @{ @"op": @"random", @"title": @"Random", @"icon": @"dice", @"fallbackIcon": @"shuffle",
               @"message": @"A whole number in the range, both ends included.",
               @"fields": @[@[@"From", @"min", numberHint], @[@"To", @"max", numberHint]] },
            @{ @"op": @"command", @"title": @"Command Text", @"icon": @"terminal",
               @"message": @"The text an RC command returns.",
               @"fields": @[@[@"Command", @"value", @"wifi status"]] },
            @{ @"op": @"command_number", @"title": @"Command Number", @"icon": @"number.square",
               @"message": @"The first number an RC command returns.",
               @"fields": @[@[@"Command", @"value", @"volume"]] },
        ];
    });
    return kinds;
}

static BOOL RCSetVariableNameValid(NSString *name) {
    if (name.length == 0 || name.length > 40 || [name isEqualToString:@"round"]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    if ([name rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    return ![[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[name characterAtIndex:0]];
}

// A footer whose text can change while a field in its section is being typed in
@interface RCSetVariableFooter : UITableViewHeaderFooterView
@property (nonatomic, strong) UILabel *label;
@end

@implementation RCSetVariableFooter
- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithReuseIdentifier:reuseIdentifier];
    if (self) {
        _label = [[UILabel alloc] init];
        _label.numberOfLines = 0;
        _label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _label.textColor = [UIColor secondaryLabelColor];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_label];
        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_label.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [_label.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [_label.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        ]];
    }
    return self;
}
@end

// One tile of the kind grid
@interface RCSetVariableTile : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, copy) NSString *op;
@end

@implementation RCSetVariableTile
- (instancetype)initWithKind:(NSDictionary *)kind {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _op = kind[@"op"];
        self.layer.cornerRadius = 12;
        self.layer.borderWidth = 2;
        self.accessibilityLabel = kind[@"title"];
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.isAccessibilityElement = YES;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        UIImage *icon = [UIImage systemImageNamed:kind[@"icon"] withConfiguration:config];
        if (!icon && kind[@"fallbackIcon"]) icon = [UIImage systemImageNamed:kind[@"fallbackIcon"] withConfiguration:config];
        _iconView = [[UIImageView alloc] initWithImage:icon];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = kind[@"title"];
        _titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 2;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.8;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_iconView];
        [self addSubview:_titleLabel];
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:72],
            [_iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_iconView.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [_iconView.heightAnchor constraintEqualToConstant:24],
            [_titleLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:6],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        ]];
    }
    return self;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UIColor *accent = self.tintColor ?: [UIColor systemBlueColor];
    self.backgroundColor = selected ? [accent colorWithAlphaComponent:0.18] : [cm tweakColorForKey:@"blockBackground" defaultVal:0.12];
    self.layer.borderColor = (selected ? accent : [UIColor clearColor]).CGColor;
    self.iconView.tintColor = selected ? accent : [UIColor labelColor];
    self.titleLabel.textColor = selected ? accent : [UIColor labelColor];
    if (selected) self.accessibilityTraits |= UIAccessibilityTraitSelected;
    else self.accessibilityTraits &= ~UIAccessibilityTraitSelected;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 1.0;
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    self.selected = self.selected;
}
@end

@interface RCSetVariableViewController () <UITextFieldDelegate>
@property (nonatomic, copy) NSDictionary *original;
@property (nonatomic, copy) NSString *op;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *typed; // op -> key -> text
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) NSArray<UITextField *> *valueFields; // up to two, reused by every kind
@property (nonatomic, strong) UISwitch *runOnlySwitch;
@property (nonatomic, strong) NSArray<RCSetVariableTile *> *tiles;
@property (nonatomic, strong) UIStackView *grid;
@property (nonatomic, strong) RCSetVariableFooter *nameFooter;
@property (nonatomic, strong) RCSetVariableFooter *kindFooter;
@property (nonatomic, strong) NSArray<NSString *> *savedNames;
@end

@implementation RCSetVariableViewController

- (instancetype)initWithAction:(NSDictionary *)action {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _original = action;
        NSString *op = [[action[@"op"] description] lowercaseString];
        BOOL known = NO;
        for (NSDictionary *kind in RCSetVariableKindList()) if ([kind[@"op"] isEqualToString:op]) known = YES;
        _op = known ? op : @"set";
        _typed = [NSMutableDictionary dictionary];
        NSMutableDictionary *mine = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"value", @"min", @"max"]) {
            if (action[key]) mine[key] = [action[key] description];
        }
        _typed[_op] = mine;
        _savedNames = @[];
        self.title = @"Set Variable";
    }
    return self;
}

- (instancetype)init {
    return [self initWithAction:nil];
}

- (NSDictionary *)currentKind {
    for (NSDictionary *kind in RCSetVariableKindList()) if ([kind[@"op"] isEqualToString:self.op]) return kind;
    return RCSetVariableKindList().firstObject;
}

- (UITextField *)makeField {
    UITextField *field = [[UITextField alloc] init];
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.delegate = self;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
    return field;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UIColor *bg = [cm tweakColorForKey:@"mainBackground" defaultVal:0.09];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    self.tableView.separatorColor = [cm tweakColorForKey:@"separators" defaultVal:0.30];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 50;
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedSectionFooterHeight = 30;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];

    self.nameField = [self makeField];
    self.nameField.placeholder = @"count";
    self.nameField.text = [self.original[@"name"] description];
    self.nameField.font = [UIFont monospacedSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightRegular];
    self.nameField.returnKeyType = UIReturnKeyNext;
    self.valueFields = @[[self makeField], [self makeField]];

    self.runOnlySwitch = [[UISwitch alloc] init];
    self.runOnlySwitch.on = [[self.original[@"scope"] description] isEqualToString:@"run"];

    self.nameFooter = [[RCSetVariableFooter alloc] initWithReuseIdentifier:nil];
    self.kindFooter = [[RCSetVariableFooter alloc] initWithReuseIdentifier:nil];

    NSMutableArray *tiles = [NSMutableArray array];
    UIStackView *grid = [[UIStackView alloc] init];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 10;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *kinds = RCSetVariableKindList();
    for (NSUInteger start = 0; start < kinds.count; start += 3) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 10;
        for (NSUInteger i = start; i < MIN(start + 3, kinds.count); i++) {
            RCSetVariableTile *tile = [[RCSetVariableTile alloc] initWithKind:kinds[i]];
            [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:tile];
            [tiles addObject:tile];
        }
        [grid addArrangedSubview:row];
    }
    self.tiles = tiles;
    self.grid = grid;

    [self applyKind];
    [self updateState];
    [self loadSavedNames];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.original) [self.nameField becomeFirstResponder];
}

// The saved variables' names, offered under the name field
- (void)loadSavedNames {
    __weak typeof(self) weakSelf = self;
    [[RCServerClient sharedClient] executeCommand:@"var list" completion:^(NSString *output, NSError *error) {
        NSData *data = [output dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![parsed isKindOfClass:[NSDictionary class]] || ![parsed count]) return;
        NSArray *names = [[parsed allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isViewLoaded) return;
            BOOL hadRow = strongSelf.savedNames.count > 0;
            strongSelf.savedNames = names;
            if (hadRow) return;
            [strongSelf.tableView insertRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:RCSetVariableSectionName]] withRowAnimation:UITableViewRowAnimationFade];
        });
    }];
}

#pragma mark - State

// Shows the current kind: tile selection, footer, field labels and keyboards
- (void)applyKind {
    NSDictionary *kind = [self currentKind];
    for (RCSetVariableTile *tile in self.tiles) tile.selected = [tile.op isEqualToString:self.op];
    self.kindFooter.label.text = kind[@"message"];
    NSArray *fields = kind[@"fields"];
    NSDictionary *mine = self.typed[self.op];
    BOOL numeric = ![self.op isEqualToString:@"set"] && ![self.op hasPrefix:@"command"];
    [self.valueFields enumerateObjectsUsingBlock:^(UITextField *field, NSUInteger i, __unused BOOL *stop) {
        if (i >= fields.count) { field.text = nil; return; }
        NSArray *spec = fields[i];
        field.text = mine[spec[1]];
        field.placeholder = spec[2];
        field.keyboardType = numeric ? UIKeyboardTypeNumbersAndPunctuation : UIKeyboardTypeDefault;
        field.returnKeyType = i + 1 < fields.count ? UIReturnKeyNext : UIReturnKeyDone;
    }];
}

// Remembers what's typed for the current kind, so switching kinds and back keeps it
- (void)storeTyped {
    NSArray *fields = [self currentKind][@"fields"];
    NSMutableDictionary *mine = self.typed[self.op] ?: [NSMutableDictionary dictionary];
    [fields enumerateObjectsUsingBlock:^(NSArray *spec, NSUInteger i, __unused BOOL *stop) {
        mine[spec[1]] = self.valueFields[i].text ?: @"";
    }];
    self.typed[self.op] = mine;
}

- (NSString *)trimmed:(NSString *)text {
    return [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Save is on only when the action is complete; a name that can't be used says why under it
- (void)updateState {
    NSString *name = [self trimmed:self.nameField.text];
    BOOL nameOK = RCSetVariableNameValid(name);
    NSString *nameText = @"In an action's text, {name} becomes the value.";
    UIColor *nameColor = [UIColor secondaryLabelColor];
    if (name.length && !nameOK) {
        nameText = [name isEqualToString:@"round"] ? @"\"round\" is reserved." : @"Letters, digits and _ only, not starting with a digit.";
        nameColor = [UIColor systemRedColor];
    }
    BOOL footerChanged = ![self.nameFooter.label.text isEqualToString:nameText];
    self.nameFooter.label.text = nameText;
    self.nameFooter.label.textColor = nameColor;
    if (footerChanged && self.tableView.window) {
        [UIView performWithoutAnimation:^{
            [self.tableView beginUpdates];
            [self.tableView endUpdates];
        }];
    }

    BOOL fieldsOK = YES;
    NSArray *fields = [self currentKind][@"fields"];
    if (![self.op isEqualToString:@"set"] && ![self.op isEqualToString:@"round"]) {
        for (NSUInteger i = 0; i < fields.count; i++) {
            if (![self trimmed:self.valueFields[i].text].length) fieldsOK = NO;
        }
    }
    self.navigationItem.rightBarButtonItem.enabled = nameOK && fieldsOK;
}

#pragma mark - Actions

- (void)tileTapped:(RCSetVariableTile *)tile {
    if ([tile.op isEqualToString:self.op]) return;
    NSUInteger oldCount = [[self currentKind][@"fields"] count];
    [self storeTyped];
    self.op = tile.op;
    [self applyKind];
    NSUInteger newCount = [[self currentKind][@"fields"] count];
    [UIView performWithoutAnimation:^{
        [self.tableView beginUpdates];
        if (newCount > oldCount) {
            [self.tableView insertRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:RCSetVariableSectionFields]] withRowAnimation:UITableViewRowAnimationNone];
        } else if (newCount < oldCount) {
            [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:RCSetVariableSectionFields]] withRowAnimation:UITableViewRowAnimationNone];
        }
        [self.tableView endUpdates];
    }];
    // Labels of the rows that stayed
    for (NSUInteger i = 0; i < newCount; i++) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:RCSetVariableSectionFields]];
        UILabel *label = [cell.contentView viewWithTag:100];
        label.text = [self currentKind][@"fields"][i][0];
    }
    [self updateState];
    if (@available(iOS 13.0, *)) {
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    }
}

- (void)nameChipTapped:(UIButton *)chip {
    self.nameField.text = [chip titleForState:UIControlStateNormal];
    [self updateState];
}

- (void)fieldChanged:(UITextField *)field {
    [self updateState];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSUInteger count = [[self currentKind][@"fields"] count];
    if (textField == self.nameField) {
        [self.valueFields[0] becomeFirstResponder];
    } else if (textField == self.valueFields[0] && count > 1) {
        [self.valueFields[1] becomeFirstResponder];
    } else {
        [textField resignFirstResponder];
    }
    return NO;
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)save {
    [self storeTyped];
    NSString *name = [self trimmed:self.nameField.text];
    if (!RCSetVariableNameValid(name)) return;
    NSMutableDictionary *item = [@{ @"type": @"set_variable", @"name": name, @"value": @"" } mutableCopy];
    if (![self.op isEqualToString:@"set"]) item[@"op"] = self.op;
    for (NSArray *spec in [self currentKind][@"fields"]) {
        NSString *text = self.typed[self.op][spec[1]] ?: @"";
        // A Set value is kept as typed (spaces may matter); the rest are trimmed
        item[spec[1]] = [self.op isEqualToString:@"set"] ? text : [self trimmed:text];
    }
    if (self.runOnlySwitch.isOn) item[@"scope"] = @"run";
    if (self.original[@"disabled"]) item[@"disabled"] = self.original[@"disabled"];
    void (^onSave)(NSDictionary *) = self.onSave;
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:^{
        if (onSave) onSave(item);
    }];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return RCSetVariableSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case RCSetVariableSectionName: return self.savedNames.count ? 2 : 1;
        case RCSetVariableSectionKind: return 1;
        case RCSetVariableSectionFields: return [[self currentKind][@"fields"] count];
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case RCSetVariableSectionName: return @"Variable";
        case RCSetVariableSectionKind: return @"Change";
        default: return nil;
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section == RCSetVariableSectionName) return self.nameFooter;
    if (section == RCSetVariableSectionKind) return self.kindFooter;
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == RCSetVariableSectionScope) return @"Forgets the value when the run ends.";
    return nil;
}

- (UITableViewCell *)plainCell {
    RCConfigManager *cm = [RCConfigManager sharedManager];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = [cm tweakColorForKey:@"blockBackground" defaultVal:0.12];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

// A row with a label on the left and a text field filling the rest
- (UITableViewCell *)cellWithLabel:(NSString *)labelText field:(UITextField *)field {
    UITableViewCell *cell = [self plainCell];
    [field removeFromSuperview];
    UILabel *label = [[UILabel alloc] init];
    label.tag = 100;
    label.text = labelText;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [cell.contentView addSubview:label];
    [cell.contentView addSubview:field];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [label.widthAnchor constraintGreaterThanOrEqualToConstant:90],
        [field.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:12],
        [field.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
        [field.heightAnchor constraintGreaterThanOrEqualToConstant:48],
    ]];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case RCSetVariableSectionName:
            if (indexPath.row == 0) return [self cellWithLabel:@"Name" field:self.nameField];
            return [self savedNamesCell];
        case RCSetVariableSectionKind: {
            UITableViewCell *cell = [self plainCell];
            cell.backgroundColor = [UIColor clearColor];
            [self.grid removeFromSuperview];
            [cell.contentView addSubview:self.grid];
            [NSLayoutConstraint activateConstraints:@[
                [self.grid.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
                [self.grid.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
                [self.grid.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
                [self.grid.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
            ]];
            return cell;
        }
        case RCSetVariableSectionFields: {
            NSArray *spec = [self currentKind][@"fields"][indexPath.row];
            return [self cellWithLabel:spec[0] field:self.valueFields[indexPath.row]];
        }
        default: {
            UITableViewCell *cell = [self plainCell];
            cell.textLabel.text = @"This Run Only";
            cell.accessoryView = self.runOnlySwitch;
            return cell;
        }
    }
}

// The saved variables as chips; tapping one fills in the name
- (UITableViewCell *)savedNamesCell {
    UITableViewCell *cell = [self plainCell];
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    RCConfigManager *cm = [RCConfigManager sharedManager];
    for (NSString *name in self.savedNames) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
        [chip setTitle:name forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
        chip.backgroundColor = [cm tweakColorForKey:@"selectionHighlight" defaultVal:0.15];
        chip.layer.cornerRadius = 15;
        chip.translatesAutoresizingMaskIntoConstraints = NO;
        CGFloat width = [name sizeWithAttributes:@{ NSFontAttributeName: chip.titleLabel.font }].width + 24;
        [NSLayoutConstraint activateConstraints:@[
            [chip.heightAnchor constraintEqualToConstant:30],
            [chip.widthAnchor constraintEqualToConstant:ceil(width)],
        ]];
        [chip addTarget:self action:@selector(nameChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:chip];
    }
    [scroll addSubview:row];
    [cell.contentView addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
        [scroll.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [scroll.heightAnchor constraintEqualToConstant:30],
        [row.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [row.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [row.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    ]];
    return cell;
}

@end
