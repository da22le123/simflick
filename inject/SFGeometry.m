#import "SFModel.h"

// NSJSONSerialization throws (crashing the host app) on NaN/inf, which empty or broken frames contain.
NSNumber *SFNum(CGFloat v) { return @(isfinite(v) ? round(v) : 0); }
NSArray<NSNumber *> *SFRectJSON(CGRect r) { return @[SFNum(r.origin.x), SFNum(r.origin.y), SFNum(r.size.width), SFNum(r.size.height)]; }
NSArray<NSNumber *> *SFPointJSON(CGPoint p) { return @[SFNum(p.x), SFNum(p.y)]; }
CGRect SFRound(CGRect r) {
  return CGRectMake(SFNum(r.origin.x).doubleValue, SFNum(r.origin.y).doubleValue, SFNum(r.size.width).doubleValue, SFNum(r.size.height).doubleValue);
}
CGPoint SFMid(CGRect r) { return CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)); }

// Visible windows, lowest level first.
NSArray<UIWindow *> *SFWindows(void) {
  NSMutableArray *ws = [NSMutableArray array];
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
    if ([s isKindOfClass:UIWindowScene.class])
      for (UIWindow *w in ((UIWindowScene *)s).windows)
        if (!w.hidden && w.alpha > 0.01) [ws addObject:w];
  return [ws sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
    return a.windowLevel < b.windowLevel ? NSOrderedAscending : a.windowLevel > b.windowLevel ? NSOrderedDescending : NSOrderedSame;
  }];
}

// Everything here is in screen coordinates (like AXe and screenshots). The app's area: the whole screen on iPhone,
// only the app's part in iPad Split View / Stage Manager.
CGRect SFAppBounds(void) {
  for (UIWindow *w in SFWindows()) if (w.rootViewController) return [w convertRect:w.bounds toWindow:nil];
  return UIScreen.mainScreen.bounds;
}

// The view a real tap at screen point p would land on (topmost window first).
UIView *SFHitView(CGPoint p, NSArray<UIWindow *> *windows) {
  for (UIWindow *w in windows.reverseObjectEnumerator) {
    UIView *hit = [w hitTest:[w convertPoint:p fromWindow:nil] withEvent:nil];
    if (hit) return hit;
  }
  return nil;
}

// A hit inside the owner reaches it; a hit on an ancestor means it just isn't touchable itself. Anything else covers it.
BOOL SFHitBelongsTo(UIView *hit, UIView *owner) {
  return hit && ([hit isDescendantOfView:owner] || [owner isDescendantOfView:hit]);
}

NSString *SFNearestId(UIView *v) {
  for (UIView *a = v; a; a = a.superview) if (a.accessibilityIdentifier.length) return a.accessibilityIdentifier;
  return @"";
}

CGRect SFFrameOnScreen(UIView *v) { return [v.window convertRect:[v convertRect:v.bounds toView:nil] toWindow:nil]; }
