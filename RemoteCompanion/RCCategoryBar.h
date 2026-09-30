#import <UIKit/UIKit.h>

// Horizontally scrolling category chips: "All" followed by one chip per title.
// Used as a table header to filter a sectioned list by section.
@interface RCCategoryBar : UIScrollView

// -1 = All, otherwise an index into titles
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, copy) void (^onSelect)(NSInteger index);

+ (CGFloat)barHeight;
- (instancetype)initWithWidth:(CGFloat)width;
// Rebuilds the chips; chipTitles are what the chips show (same count as the sections)
- (void)setChipTitles:(NSArray<NSString *> *)chipTitles;

@end
