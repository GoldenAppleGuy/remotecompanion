#import <UIKit/UIKit.h>

// Horizontally scrolling category chips: "All" followed by one chip per title.
// Floats at the top of a table to filter it by section: it hides as you scroll
// down and reappears as soon as you scroll up.
@interface RCCategoryBar : UIScrollView

// -1 = All, otherwise an index into titles
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, copy) void (^onSelect)(NSInteger index);

+ (CGFloat)barHeight;
- (instancetype)initWithWidth:(CGFloat)width;
// Rebuilds the chips; chipTitles are what the chips show (same count as the sections)
- (void)setChipTitles:(NSArray<NSString *> *)chipTitles;

// Floats the bar over the top of the table (insetting its content by the bar's height).
// The table's scrollViewDidScroll: must forward to -scrollViewDidScroll:.
- (void)attachToTableView:(UITableView *)tableView;
- (void)scrollViewDidScroll:(UIScrollView *)scrollView;

@end
