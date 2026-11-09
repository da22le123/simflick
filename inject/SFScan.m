// Lazy lists (UIKit/SwiftUI collection and table views) only build the rows on screen. To show the model what's
// further on, scroll the list a screen at a time, read it, and scroll back, all within one main-thread turn, so
// nothing is ever drawn at the intermediate offsets. Opt-in (/screen?scan=1): ~25 ms per screen scanned.
#import "SFModel.h"

static BOOL IsLazyList(UIView *v) { return [v isKindOfClass:UICollectionView.class] || [v isKindOfClass:UITableView.class]; }

// Read the list at content offset y; add what's there as scrolled-away nodes/texts, frames as seen from `origin`.
static void ReadAt(SFSnapshot *s, SFScrollArea *area, UIScrollView *sv, CGPoint origin, CGFloat y, NSString *dir) {
  [sv setContentOffset:CGPointMake(origin.x, y) animated:NO];
  [sv layoutIfNeeded];
  SFSnapshot *t = SFCollect(NO);
  NSString *ref = nil;
  for (SFScrollArea *a in t.scrolls) if (a.view == sv) ref = a.ref;
  if (!ref) return;
  CGFloat dy = y - origin.y;  // content moved up by dy: its real position is dy further down
  for (SFNode *n in t.nodes) {
    if (![n.scrollRef isEqualToString:ref]) continue;
    CGRect f = CGRectOffset(n.frame, 0, dy);
    BOOL known = NO;  // already listed (visible now, or built off screen)
    for (SFNode *o in [s.nodes arrayByAddingObjectsFromArray:s.hidden])
      if ([o.label isEqualToString:n.label] && fabs(CGRectGetMidY(o.frame) - CGRectGetMidY(f)) < kSFSamePlaceCenter) { known = YES; break; }
    if (known || s.hidden.count >= kSFMaxHiddenCollected) continue;
    n.frame = f; n.scrollRef = area.ref; n.direction = dir; n.tap = CGPointZero; n.source = nil;
    [s.hidden addObject:n];
  }
  for (SFText *x in t.texts) {
    if (!x.shown || ![x.scrollRef isEqualToString:ref]) continue;
    BOOL known = NO;
    for (SFText *o in s.texts)
      if ([o.label isEqualToString:x.label] && fabs(CGRectGetMidY(o.frame) - (CGRectGetMidY(x.frame) + dy)) < kSFSamePlaceCenter) { known = YES; break; }
    if (known) continue;
    x.frame = CGRectOffset(x.frame, 0, dy); x.scrollRef = area.ref; x.shown = NO; x.direction = dir;
    [s.texts addObject:x];
  }
}

void SFScanLists(SFSnapshot *s) {
  for (SFScrollArea *area in [s.scrolls copy]) {
    UIScrollView *sv = (UIScrollView *)area.view;
    if (!IsLazyList(sv)) continue;
    BOOL down = [area.more containsObject:@"down"], up = [area.more containsObject:@"up"];
    if (!down && !up) continue;
    CGPoint origin = sv.contentOffset;
    CGFloat page = sv.bounds.size.height * 0.9, top = -sv.adjustedContentInset.top;
    CGFloat bottom = sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.size.height;
    for (int k = 1; down && k <= kSFScanScreens; k++) {
      CGFloat y = MIN(origin.y + k * page, bottom);
      ReadAt(s, area, sv, origin, y, @"down");
      if (y >= bottom) break;
    }
    for (int k = 1; up && k <= kSFScanScreens; k++) {
      CGFloat y = MAX(origin.y - k * page, top);
      ReadAt(s, area, sv, origin, y, @"up");
      if (y <= top) break;
    }
    [sv setContentOffset:origin animated:NO];
    [sv layoutIfNeeded];
  }
}
