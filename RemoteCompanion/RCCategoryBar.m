#import "RCCategoryBar.h"

@interface RCCategoryBar ()
@property (nonatomic, strong) NSMutableArray<UIButton *> *chips;
@end

@implementation RCCategoryBar

+ (CGFloat)barHeight {
    return 48;
}

- (instancetype)initWithWidth:(CGFloat)width {
    self = [super initWithFrame:CGRectMake(0, 0, width, [RCCategoryBar barHeight])];
    if (self) {
        _selectedIndex = -1;
        _chips = [NSMutableArray array];
        self.showsHorizontalScrollIndicator = NO;
        self.alwaysBounceHorizontal = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    }
    return self;
}

- (void)setChipTitles:(NSArray<NSString *> *)chipTitles {
    for (UIButton *chip in self.chips) [chip removeFromSuperview];
    [self.chips removeAllObjects];

    NSMutableArray *titles = [NSMutableArray arrayWithObject:@"All"];
    [titles addObjectsFromArray:chipTitles];
    CGFloat height = [RCCategoryBar barHeight];
    CGFloat x = 16;
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        [chip setTitle:titles[i] forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        chip.contentEdgeInsets = UIEdgeInsetsMake(7, 14, 7, 14); // UIButtonConfiguration is iOS 15+
#pragma clang diagnostic pop
        [chip sizeToFit];
        chip.frame = CGRectMake(x, (height - chip.bounds.size.height) / 2.0, chip.bounds.size.width, chip.bounds.size.height);
        chip.layer.cornerRadius = chip.bounds.size.height / 2.0;
        chip.tag = (NSInteger)i - 1; // -1 = All
        [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:chip];
        [self.chips addObject:chip];
        x += chip.bounds.size.width + 8;
    }
    self.contentSize = CGSizeMake(x + 8, height);
    if (self.selectedIndex >= (NSInteger)chipTitles.count) _selectedIndex = -1;
    [self updateChips];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    [self updateChips];
}

- (void)updateChips {
    for (UIButton *chip in self.chips) {
        BOOL selected = (chip.tag == self.selectedIndex);
        chip.backgroundColor = selected ? [UIColor labelColor] : [UIColor tertiarySystemFillColor];
        [chip setTitleColor:selected ? [UIColor systemBackgroundColor] : [UIColor labelColor] forState:UIControlStateNormal];
    }
}

- (void)chipTapped:(UIButton *)chip {
    self.selectedIndex = chip.tag;
    [self scrollRectToVisible:CGRectInset(chip.frame, -24, 0) animated:YES];
    if (self.onSelect) self.onSelect(chip.tag);
}

@end
