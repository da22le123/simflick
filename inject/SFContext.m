// Text around an element that says which card/row it belongs to, and accessibility-tree traversal.
#import "SFModel.h"
#import <objc/message.h>

// Skips text owned by other tappable elements (e.g. a neighbouring tab), which would mislabel this one.
static void CollectText(UIView *v, UIView *me, NSMutableArray *out, int depth, BOOL offscreenOK) {
  CALayer *shown = v.layer.presentationLayer;
  if (depth > kSFContextDepth || out.count > kSFContextMaxTexts || v.hidden || v.alpha < kSFInvisibleAlpha || (shown && shown.opacity < kSFInvisibleAlpha)) return;
  BOOL text = SFIsTextView(v);
  if (v != me && v.isAccessibilityElement && !text) return;
  if (v != me && text) {
    // Closed sheets park their text off screen; only count text that is on screen.
    CGRect f = [v convertRect:v.bounds toView:nil];
    if (v.accessibilityLabel.length && v.window && (offscreenOK || CGRectIntersectsRect(f, v.window.bounds))) [out addObject:v.accessibilityLabel];
    return;
  }
  for (UIView *sub in v.subviews) CollectText(sub, me, out, depth + 1, offscreenOK);
}

// Text of the card/row a view belongs to: climb until other text appears, stop before list-wide levels.
// offscreenOK: describing a scrolled-away item, whose own text is off screen too.
NSString *SFContextFor(UIView *v, NSString *own, BOOL offscreenOK) {
  // Nested inside an accessible card (e.g. a "⋯" menu): the card's label is the best context.
  for (UIView *p = v.superview; p && ![p isKindOfClass:UIScrollView.class]; p = p.superview)
    if (p.isAccessibilityElement && p.accessibilityLabel.length) return p.accessibilityLabel;
  UIView *a = v.superview;
  for (int i = 0; a && i < kSFContextClimb; i++, a = a.superview) {
    if ([a isKindOfClass:UIScrollView.class] || [a isKindOfClass:UIWindow.class]) break;
    NSMutableArray *t = [NSMutableArray array];
    CollectText(a, v, t, 0, offscreenOK);
    if (t.count > kSFContextMaxTexts) break;
    [t removeObject:own ?: @""];
    if (t.count) { NSString *j = [t componentsJoinedByString:@" · "]; return j.length > kSFContextMaxChars ? [j substringToIndex:kSFContextMaxChars] : j; }
  }
  return @"";
}

// Context for a SwiftUI element: the static text next to it in the same container (e.g. a card's title).
NSString *SFSiblingText(NSArray *siblings, id me) {
  NSMutableArray *t = [NSMutableArray array];
  for (id s in siblings) {
    if (s == me || [s isKindOfClass:UIView.class] || ![s isAccessibilityElement]) continue;
    if (([s accessibilityTraits] & UIAccessibilityTraitStaticText) && [[s accessibilityLabel] length]) [t addObject:[s accessibilityLabel]];
    if (t.count == 3) break;
  }
  return [t componentsJoinedByString:@" · "];
}

// Prefer what UI-testing clients (XCUITest, axe) traverse; SwiftUI exposes more there than in accessibilityElements.
NSArray *SFAXChildren(id o) {
  SEL userTesting = NSSelectorFromString(@"_accessibilityUserTestingChildren");
  if ([o respondsToSelector:userTesting]) {
    NSArray *u = ((NSArray *(*)(id, SEL))objc_msgSend)(o, userTesting);
    if ([u isKindOfClass:NSArray.class] && u.count) return u;
  }
  NSArray *a = nil;
  if (@available(iOS 17.0, *)) a = [o respondsToSelector:@selector(automationElements)] ? [o automationElements] : nil;
  if (a.count) return a;
  a = [o respondsToSelector:@selector(accessibilityElements)] ? [o accessibilityElements] : nil;
  if (a.count) return a;
  NSInteger n = [o respondsToSelector:@selector(accessibilityElementCount)] ? [o accessibilityElementCount] : 0;
  if (n <= 0 || n == NSNotFound) return @[];
  NSMutableArray *m = [NSMutableArray array];
  for (NSInteger i = 0; i < n; i++) { id e = [o accessibilityElementAtIndex:i]; if (e) [m addObject:e]; }
  return m;
}
