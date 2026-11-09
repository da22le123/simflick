// Injected into a simulator app: GET /screen = what is actually on screen; /tap, /swipe act on it.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <pthread.h>
#import <dlfcn.h>
#import <objc/message.h>

// NSJSONSerialization throws (crashing the host app) on NaN/inf, which empty or broken frames contain.
static NSNumber *N(CGFloat v) { return @(isfinite(v) ? round(v) : 0); }
static NSArray<NSNumber *> *R(CGRect r) {
  return @[N(r.origin.x), N(r.origin.y), N(r.size.width), N(r.size.height)];
}

static NSArray<UIWindow *> *Windows(void) {
  NSMutableArray *ws = [NSMutableArray array];
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
    if ([s isKindOfClass:UIWindowScene.class])
      for (UIWindow *w in ((UIWindowScene *)s).windows)
        if (!w.hidden && w.alpha > 0.01) [ws addObject:w];
  return [ws sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
    return a.windowLevel < b.windowLevel ? NSOrderedAscending : a.windowLevel > b.windowLevel ? NSOrderedDescending : NSOrderedSame;
  }];
}

// The view a real tap at screen point p would land on (topmost window first).
static UIView *HitAt(CGPoint p, NSArray<UIWindow *> *windows) {
  for (UIWindow *w in windows.reverseObjectEnumerator) {
    UIView *hit = [w hitTest:[w convertPoint:p fromWindow:nil] withEvent:nil];
    if (hit) return hit;
  }
  return nil;
}

// The visible navigation bar's title ("Trending"), so a list isn't mistaken for the item it shows.
static NSString *NavTitle(UIView *v) {
  if (v.hidden || v.alpha < 0.01) return nil;
  if ([v isKindOfClass:UINavigationBar.class]) {
    UINavigationItem *it = ((UINavigationBar *)v).topItem;
    NSString *t = it.title.length ? it.title : ([it.titleView accessibilityLabel] ?: nil);
    if (t.length && v.window && CGRectIntersectsRect([v convertRect:v.bounds toView:nil], UIScreen.mainScreen.bounds)) return t;
  }
  for (UIView *sub in v.subviews.reverseObjectEnumerator) { NSString *t = NavTitle(sub); if (t) return t; }
  return nil;
}

static NSString *Kind(id v) {
  // Web views and read-only text views adopt UITextInput too, but you can't type into them.
  BOOL editable = !([v isKindOfClass:UITextView.class] && !((UITextView *)v).editable) && ![NSStringFromClass([v class]) hasPrefix:@"WK"];
  if (editable && [v conformsToProtocol:@protocol(UITextInput)]) return @"input";
  UIAccessibilityTraits t = [v accessibilityTraits];
  if (t & UIAccessibilityTraitButton) return @"button";
  if (t & UIAccessibilityTraitLink) return @"link";
  if (t & UIAccessibilityTraitAdjustable) return @"adjustable";
  if (t & UIAccessibilityTraitHeader) return @"header";
  if (t & UIAccessibilityTraitStaticText) return @"text";
  return @"element";
}

static NSString *NearestId(UIView *v) {
  for (UIView *a = v; a; a = a.superview) if (a.accessibilityIdentifier.length) return a.accessibilityIdentifier;
  return @"";
}

NSData *SRHandleAction(NSString *path, NSDictionary<NSString *, NSString *> *q);
static NSMutableArray *gRejects;  // filled only for /screen?debug=1

typedef struct { NSMutableArray *els, *scrolls, *texts; NSArray *windows; NSMutableDictionary *hiddenIn, *ahead; NSMutableArray *hidden, *axTexts, *remote, *cells, *shownTexts; UIView *focused; BOOL animating, loading; } Ctx;

// Skips text owned by other tappable elements (e.g. a neighbouring tab), which would mislabel this one.
static void CollectText(UIView *v, UIView *self_, NSMutableArray *out, int depth, BOOL offscreenOK) {
  if (depth > 10 || out.count > 6 || v.hidden || v.alpha < 0.01 || v.layer.presentationLayer.opacity < 0.01) return;
  if (v != self_ && v.isAccessibilityElement && ![NSStringFromClass(v.class) containsString:@"Paragraph"]) return;
  if ([NSStringFromClass(v.class) containsString:@"Paragraph"]) {
    // Closed sheets park their text off screen; only count text that is on screen.
    CGRect f = [v convertRect:v.bounds toView:nil];
    if (v.accessibilityLabel.length && v.window && (offscreenOK || CGRectIntersectsRect(f, v.window.bounds))) [out addObject:v.accessibilityLabel];
    return;
  }
  for (UIView *sub in v.subviews) CollectText(sub, self_, out, depth + 1, offscreenOK);
}

// Text of the card/row an element belongs to: climb until other text appears, stop before list-wide levels.
// offscreenOK: describing a scrolled-away item, whose own text is off screen too.
static NSString *ContextFor(UIView *v, NSString *own, BOOL offscreenOK) {
  // Nested inside an accessible card (e.g. a "⋯" menu): the card's label is the best context.
  for (UIView *p = v.superview; p && ![p isKindOfClass:UIScrollView.class]; p = p.superview)
    if (p.isAccessibilityElement && p.accessibilityLabel.length) return p.accessibilityLabel;
  UIView *a = v.superview;
  for (int i = 0; a && i < 5; i++, a = a.superview) {
    if ([a isKindOfClass:UIScrollView.class] || [a isKindOfClass:UIWindow.class]) break;
    NSMutableArray *t = [NSMutableArray array];
    CollectText(a, v, t, 0, offscreenOK);
    if (t.count > 6) break;
    [t removeObject:own ?: @""];
    if (t.count) { NSString *j = [t componentsJoinedByString:@" · "]; return j.length > 100 ? [j substringToIndex:100] : j; }
  }
  return @"";
}
// One on-screen candidate: a UIView, or a non-view accessibility element owned by `owner` (SwiftUI).
static void Consider(id obj, UIView *owner, CGRect frame, CGRect vis, NSDictionary *myScroll, Ctx *c, NSString *axCtx) {
  BOOL isView = [obj isKindOfClass:UIView.class];
  UIView *v = isView ? obj : nil;
  NSString *label = [obj accessibilityLabel] ?: @"";
  NSString *ident = isView ? NearestId(v) : ([obj respondsToSelector:@selector(accessibilityIdentifier)] ? ([obj accessibilityIdentifier] ?: @"") : @"");
  BOOL shown = NO; CGPoint tap = CGPointZero;
  if (!CGRectIsEmpty(vis) && vis.size.width >= 2 && vis.size.height >= 2) {
    CGPoint pts[5] = {{CGRectGetMidX(vis), CGRectGetMidY(vis)},
      {CGRectGetMinX(vis) + vis.size.width * .25, CGRectGetMinY(vis) + vis.size.height * .25},
      {CGRectGetMaxX(vis) - vis.size.width * .25, CGRectGetMinY(vis) + vis.size.height * .25},
      {CGRectGetMinX(vis) + vis.size.width * .25, CGRectGetMaxY(vis) - vis.size.height * .25},
      {CGRectGetMaxX(vis) - vis.size.width * .25, CGRectGetMaxY(vis) - vis.size.height * .25}};
    for (int i = 0; i < 5 && !shown; i++) {
      UIView *hit = HitAt(pts[i], c->windows);
      // Covered = the hit lands on an unrelated view; a hit on an ancestor means it just isn't touchable.
      if (hit && ([hit isDescendantOfView:owner] || [owner isDescendantOfView:hit])) { shown = YES; tap = pts[i]; }
    }
  }
  // Tap where iOS says the element activates (VoiceOver's point), e.g. the switch of a SwiftUI Toggle row.
  if (shown) {
    CGPoint ap = [obj accessibilityActivationPoint];
    if (CGRectContainsPoint(CGRectInset(vis, 1, 1), ap)) {
      UIView *hit = HitAt(ap, c->windows);
      if (hit && ([hit isDescendantOfView:owner] || [owner isDescendantOfView:hit])) tap = ap;
    }
  }
  if (gRejects && !shown && !isView) {
    UIView *hit = CGRectIsEmpty(vis) ? nil : HitAt(CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis)), c->windows);
    [gRejects addObject:@{@"label": label, @"frame": R(frame), @"vis": R(vis), @"owner": NSStringFromClass(owner.class),
      @"hit": hit ? NSStringFromClass(hit.class) : @"-", @"hitInOwner": @(hit && [hit isDescendantOfView:owner]), @"ownerInHit": @(hit && [owner isDescendantOfView:hit])}];
  }
  // Drop slivers: under a third showing and too thin to tap reliably.
  CGFloat frac = frame.size.width * frame.size.height > 0 ? (vis.size.width * vis.size.height) / (frame.size.width * frame.size.height) : 0;
  if (shown && frac < 0.33 && (vis.size.height < 24 || vis.size.width < 24)) shown = NO;
  NSString *kind = Kind(obj);
  // Non-view text/headers (SwiftUI) are page text and context sources, not things to act on.
  // Swift Charts exposes every bar as an element ("0 to 0,5", value "20"): data points, not controls.
  if (!isView && !([obj accessibilityTraits] & (UIAccessibilityTraitButton | UIAccessibilityTraitLink)) &&
      [[obj accessibilityLabel] rangeOfString:@"^-?[0-9.,]+ to -?[0-9.,]+$" options:NSRegularExpressionSearch].location != NSNotFound) return;
  if (!isView && shown && ([[obj accessibilityLabel] isEqualToString:@"In progress"] || [[obj accessibilityLabel] isEqualToString:@"Loading"])) c->loading = YES;
  if (!isView && ([kind isEqualToString:@"text"] || [kind isEqualToString:@"header"])) {
    if (shown && label.length) {
      [c->texts addObject:label];
      if ([kind isEqualToString:@"text"]) [c->shownTexts addObject:@{@"label": label, @"frame": [NSValue valueWithCGRect:vis]}];  // headers don't make rows
    }
    if (label.length && myScroll) [c->axTexts addObject:@{@"label": label, @"frame": R(frame), @"in": myScroll[@"ref"]}];
    return;
  }
  if (shown) {
    NSMutableDictionary *e = [@{@"kind": kind, @"id": ident, @"label": label,
                                @"frame": R(frame), @"tap": @[N(tap.x), N(tap.y)]} mutableCopy];
    if (!CGRectEqualToRect(CGRectIntegral(vis), CGRectIntegral(frame))) e[@"clipped"] = @YES;
    NSString *val = [obj accessibilityValue];
    // Switches (UISwitch, SwiftUI Toggle) report "1"/"0"; spell it out so a model can tell the state.
    BOOL toggle = NO;
    if (@available(iOS 17.0, *)) toggle = ([obj accessibilityTraits] & UIAccessibilityTraitToggleButton) != 0;
    if ([obj isKindOfClass:UISwitch.class] || (toggle && ([val isEqualToString:@"1"] || [val isEqualToString:@"0"]))) {
      e[@"kind"] = @"switch"; val = [val isEqualToString:@"1"] ? @"on" : @"off";
    }
    if (val.length) e[@"value"] = val;
    if (myScroll) e[@"in"] = myScroll[@"ref"];
    // Context only where it disambiguates (list/carousel items, nested buttons); tabs and headers get none.
    BOOL nested = NO;
    for (UIView *p = v.superview; p && !nested; p = p.superview) nested = p.isAccessibilityElement;
    NSString *ctx = isView ? ((myScroll || nested) ? ContextFor(v, label, NO) : @"") : (myScroll ? axCtx : @"");
    if (ctx.length) e[@"context"] = ctx;
    if ([obj accessibilityTraits] & UIAccessibilityTraitSelected) e[@"selected"] = @YES;
    [c->els addObject:e];
  } else if (myScroll) {
    c->hiddenIn[myScroll[@"ref"]] = @([c->hiddenIn[myScroll[@"ref"]] intValue] + 1);
    CGRect sv = [myScroll[@"vis"] CGRectValue];
    CGFloat dx = (CGRectGetMidX(frame) - CGRectGetMidX(sv)) / MAX(sv.size.width, 1), dy = (CGRectGetMidY(frame) - CGRectGetMidY(sv)) / MAX(sv.size.height, 1);
    NSString *dir = fabs(dx) > fabs(dy) ? (dx > 0 ? @"right" : @"left") : (dy > 0 ? @"down" : @"up");
    NSString *ctx = isView ? ContextFor(v, label, YES) : axCtx;
    NSMutableArray *list = c->ahead[myScroll[@"ref"]] ?: (c->ahead[myScroll[@"ref"]] = [NSMutableArray array]);
    if (list.count < 20) [list addObject:@{@"dir": dir, @"what": [@[label, ctx] componentsJoinedByString:@" — "]}];
    if (c->hidden.count < 200) [c->hidden addObject:@{@"kind": kind, @"id": ident, @"label": label,
      @"context": ctx, @"frame": R(frame), @"in": myScroll[@"ref"], @"dir": dir}];
  }
}

static NSArray *AXChildren(id o) {
  // Prefer what UI-testing clients (XCUITest, axe) traverse; SwiftUI exposes more there than in accessibilityElements.
  SEL userTesting = NSSelectorFromString(@"_accessibilityUserTestingChildren");
  if ([o respondsToSelector:userTesting]) {
    NSArray *(*msg)(id, SEL) = (void *)objc_msgSend;
    NSArray *u = msg(o, userTesting);
    if ([u isKindOfClass:NSArray.class] && u.count) return u;
  }
  NSArray *a = [o respondsToSelector:@selector(automationElements)] ? [o automationElements] : nil;
  if (a.count) return a;
  a = [o respondsToSelector:@selector(accessibilityElements)] ? [o accessibilityElements] : nil;
  if (a.count) return a;
  NSInteger n = [o respondsToSelector:@selector(accessibilityElementCount)] ? [o accessibilityElementCount] : 0;
  if (n <= 0 || n == NSNotFound) return @[];
  NSMutableArray *m = [NSMutableArray array];
  for (NSInteger i = 0; i < n; i++) { id e = [o accessibilityElementAtIndex:i]; if (e) [m addObject:e]; }
  return m;
}

// Context for a SwiftUI element: the static text next to it in the same container (e.g. a card's title).
static NSString *SiblingText(NSArray *siblings, id self_) {
  NSMutableArray *t = [NSMutableArray array];
  for (id s in siblings) {
    if (s == self_ || [s isKindOfClass:UIView.class] || ![s isAccessibilityElement]) continue;
    if (([s accessibilityTraits] & UIAccessibilityTraitStaticText) && [[s accessibilityLabel] length]) [t addObject:[s accessibilityLabel]];
    if (t.count == 3) break;
  }
  return [t componentsJoinedByString:@" · "];
}

static void WalkAX(id el, UIView *owner, CGRect clip, NSDictionary *myScroll, Ctx *c, int depth, NSArray *siblings) {
  if (depth > 40 || ([el respondsToSelector:@selector(accessibilityElementsHidden)] && [el accessibilityElementsHidden])) return;
  if ([el isAccessibilityElement]) {
    CGRect frame = [el accessibilityFrame];  // already in screen coordinates
    Consider(el, owner, frame, CGRectIntersection(frame, clip), myScroll, c, siblings.count < 8 ? SiblingText(siblings, el) : @"");
  }
  NSArray *kids = AXChildren(el);
  // A non-element container with several children (e.g. one post: header, text, buttons) is a candidate
  // "open item" row; rows are only kept later if they hold several elements and a free spot to tap.
  if (gRejects && ![el isAccessibilityElement] && kids.count >= 2)
    [gRejects addObject:@{@"container": NSStringFromClass([el class]), @"kids": @(kids.count), @"frame": R([el respondsToSelector:@selector(accessibilityFrame)] ? [el accessibilityFrame] : CGRectNull), @"inScroll": @(myScroll != nil)}];
  if (![el isAccessibilityElement] && kids.count >= 2 && myScroll && [el respondsToSelector:@selector(accessibilityFrame)]) {
    CGRect gf = CGRectIntersection([el accessibilityFrame], clip);
    CGRect screen = UIScreen.mainScreen.bounds;
    if (!CGRectIsEmpty(gf) && gf.size.height >= 50 && gf.size.height < screen.size.height * 0.7 && gf.size.width >= screen.size.width * 0.6)
      [c->cells addObject:@{@"frame": [NSValue valueWithCGRect:gf], @"in": myScroll[@"ref"], @"group": @YES}];
  }
  for (id k in kids) if (![k isKindOfClass:UIView.class]) WalkAX(k, owner, clip, myScroll, c, depth + 1, kids);
}

// The keyboard is drawn by another process; the app only learns its frame from these notifications.
static CGRect gKeyboard;

static void Walk(UIView *v, CGRect clip, NSDictionary *scroll, Ctx *c) {
  if (v.hidden || v.layer.presentationLayer.opacity < 0.01 || v.alpha < 0.01) return;
  CGRect frame = [v convertRect:v.bounds toView:nil];
  frame = [v.window convertRect:frame toWindow:nil];
  CGRect vis = CGRectIntersection(frame, clip);
  if (v.isFirstResponder) c->focused = v;
  // Core Animation moves layers while views already report final frames; flag it so callers keep waiting.
  if (v.layer.animationKeys.count && !CGRectIsEmpty(vis)) c->animating = YES;
  // A visible spinner means content is still arriving (network); settle should keep waiting.
  if (!CGRectIsEmpty(vis) && [v isKindOfClass:UIActivityIndicatorView.class] && ((UIActivityIndicatorView *)v).isAnimating) c->loading = YES;
  if (!CGRectIsEmpty(vis) && [NSStringFromClass(v.class) isEqualToString:@"WKWebView"] && [v respondsToSelector:@selector(isLoading)] && ((BOOL (*)(id, SEL))objc_msgSend)(v, @selector(isLoading))) c->loading = YES;

  // Content drawn by another process (Safari sheets, web sign-in, some system UI) is opaque to us and to axe.
  if ([NSStringFromClass(v.class) isEqualToString:@"_UIRemoteView"] && !CGRectIsEmpty(vis)) {
    UIView *hit = HitAt(CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis)), c->windows);
    NSString *host = @"";
    for (UIView *p = v.superview; p && !host.length; p = p.superview) if (![NSStringFromClass(p.class) hasPrefix:@"_"]) host = NSStringFromClass(p.class);
    if (hit && ([hit isDescendantOfView:v] || hit == v)) [c->remote addObject:@{@"frame": R(vis), @"host": host}];
  }
  if (([v isKindOfClass:UICollectionViewCell.class] || [v isKindOfClass:UITableViewCell.class]) && vis.size.height >= 30 && scroll)
    [c->cells addObject:@{@"frame": [NSValue valueWithCGRect:vis], @"in": scroll[@"ref"]}];
  NSDictionary *myScroll = scroll;
  UIView *centerHit = CGRectIsEmpty(vis) ? nil : HitAt(CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis)), c->windows);
  // Only report scroll areas the user can actually reach (not ones under a sheet, not text-input internals).
  if ([v isKindOfClass:UIScrollView.class] && ![v conformsToProtocol:@protocol(UITextInput)] && centerHit && [centerHit isDescendantOfView:v]) {
    UIScrollView *s = (UIScrollView *)v;
    CGPoint o = s.contentOffset; CGSize cs = s.contentSize, b = s.bounds.size; UIEdgeInsets in = s.adjustedContentInset;
    NSMutableArray *more = [NSMutableArray array];
    if (o.y > -in.top + 1) [more addObject:@"up"];
    if (o.y + b.height < cs.height + in.bottom - 1) [more addObject:@"down"];
    if (o.x > -in.left + 1) [more addObject:@"left"];
    if (o.x + b.width < cs.width + in.right - 1) [more addObject:@"right"];
    NSString *sid = [NSString stringWithFormat:@"S%lu", (unsigned long)c->scrolls.count];
    [c->scrolls addObject:[@{@"ref": sid, @"id": NearestId(v), @"frame": R(vis), @"more": more,
                             @"offset": @[N(o.x), N(o.y)], @"content": @[N(cs.width), N(cs.height)], @"paging": @(s.isPagingEnabled)} mutableCopy]];
    myScroll = @{@"ref": sid, @"vis": [NSValue valueWithCGRect:vis]};
  }
  if (v.clipsToBounds || [v isKindOfClass:UIScrollView.class]) clip = vis;

  // Visible RN text (Fabric paragraphs) becomes page text, like Jev's visible-text block.
  if ([NSStringFromClass(v.class) containsString:@"Paragraph"] && !CGRectIsEmpty(vis) && vis.size.height >= 4) {
    UIView *hit = HitAt(CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis)), c->windows);
    NSString *txt = v.accessibilityLabel;
    if (txt.length && hit && ([hit isDescendantOfView:v] || [v isDescendantOfView:hit])) [c->texts addObject:txt];
  }
  if (v.isAccessibilityElement || [v conformsToProtocol:@protocol(UITextInput)]) Consider(v, v, frame, vis, myScroll, c, nil);
  // SwiftUI (and some UIKit containers) describe content as accessibility elements that are not views.
  // RN views are fully covered by the view walk (text included); skipping their AX children keeps reads fast.
  NSArray *axKids = [NSStringFromClass(v.class) hasPrefix:@"RCT"] ? @[] : AXChildren(v);
  for (id el in axKids) if (![el isKindOfClass:UIView.class]) WalkAX(el, v, clip, myScroll, c, 0, axKids);
  for (UIView *sub in v.subviews) Walk(sub, clip, myScroll, c);
}

static NSData *Screen(void) {
  CFTimeInterval t0 = CACurrentMediaTime();
  Ctx c = {[NSMutableArray array], [NSMutableArray array], [NSMutableArray array], Windows(), [NSMutableDictionary dictionary], [NSMutableDictionary dictionary], [NSMutableArray array], [NSMutableArray array], [NSMutableArray array], [NSMutableArray array], [NSMutableArray array]};
  NSMutableArray *wnames = [NSMutableArray array];
  for (UIWindow *w in c.windows) {
    [wnames addObject:NSStringFromClass(w.class)];
    CGRect clip = w.screen.bounds;
    if (!CGRectIsEmpty(CGRectIntersection(gKeyboard, clip))) clip.size.height = MAX(0, CGRectGetMinY(gKeyboard) - clip.origin.y);
    Walk(w, clip, nil, &c);
  }
  // Flat SwiftUI stacks give no grouping: label context-less items with the nearest text in the same scroll area.
  NSMutableArray *all = [NSMutableArray arrayWithArray:c.els];
  [all addObjectsFromArray:c.hidden];
  for (NSUInteger i = 0; i < all.count; i++) {
    NSDictionary *e = all[i];
    if ([e[@"kind"] isEqualToString:@"text"] || [e[@"context"] length] || !e[@"in"]) continue;
    NSArray *f = e[@"frame"]; double ex = [f[0] doubleValue] + [f[2] doubleValue] / 2, ey = [f[1] doubleValue] + [f[3] doubleValue] / 2, best = 100;
    NSString *ctx = nil;
    for (NSDictionary *t in c.axTexts) {
      if (![t[@"in"] isEqualToString:e[@"in"]]) continue;
      NSArray *g = t[@"frame"];
      double d = hypot([g[0] doubleValue] + [g[2] doubleValue] / 2 - ex, [g[1] doubleValue] + [g[3] doubleValue] / 2 - ey);
      if (d < best) { best = d; ctx = t[@"label"]; }
    }
    if (!ctx) continue;
    NSMutableDictionary *m = [e mutableCopy]; m[@"context"] = ctx;
    NSMutableArray *arr = i < c.els.count ? c.els : c.hidden;
    arr[i < c.els.count ? i : i - c.els.count] = m;
  }
  // SwiftUI controls appear both as a view and as an accessibility object: merge same-place, same-size entries.
  NSMutableArray *merged = [NSMutableArray array];
  for (NSDictionary *e in c.els) {
    NSArray *f = e[@"frame"]; NSInteger dup = NSNotFound;
    for (NSUInteger j = 0; j < merged.count && dup == NSNotFound; j++) {
      NSArray *g = merged[j][@"frame"];
      if (fabs([f[0] doubleValue] + [f[2] doubleValue] / 2 - [g[0] doubleValue] - [g[2] doubleValue] / 2) < 6 &&
          fabs([f[1] doubleValue] + [f[3] doubleValue] / 2 - [g[1] doubleValue] - [g[3] doubleValue] / 2) < 6 &&
          fabs([f[2] doubleValue] - [g[2] doubleValue]) < 12 && fabs([f[3] doubleValue] - [g[3] doubleValue]) < 12) dup = j;
    }
    if (dup == NSNotFound) { [merged addObject:e]; continue; }
    // Keep the richer one: inputs over text, labelled over unlabelled, with an id over without.
    NSDictionary *o = merged[dup];
    int (^score)(NSDictionary *) = ^int(NSDictionary *x) {
      return ([x[@"kind"] isEqualToString:@"input"] ? 8 : 0) + ([x[@"kind"] isEqualToString:@"text"] ? -4 : 0) +
             ([x[@"label"] length] ? 2 : 0) + ([x[@"id"] length] ? 1 : 0) + (x[@"value"] ? 1 : 0);
    };
    if (score(e) > score(o)) merged[dup] = e;
  }
  NSMutableArray *kept = [NSMutableArray array];
  for (NSDictionary *e in merged) {
    BOOL inside = NO;
    if ([e[@"kind"] isEqualToString:@"text"]) for (NSDictionary *o in merged) {
      if (o == e || [o[@"kind"] isEqualToString:@"text"] || ![o[@"label"] isEqualToString:e[@"label"]]) continue;
      CGRect a = CGRectMake([o[@"frame"][0] doubleValue], [o[@"frame"][1] doubleValue], [o[@"frame"][2] doubleValue], [o[@"frame"][3] doubleValue]);
      CGRect b = CGRectMake([e[@"frame"][0] doubleValue], [e[@"frame"][1] doubleValue], [e[@"frame"][2] doubleValue], [e[@"frame"][3] doubleValue]);
      if (CGRectContainsPoint(CGRectInset(a, -2, -2), CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b)))) inside = YES;
    }
    if (!inside) [kept addObject:e];
  }
  [c.els setArray:kept];
  // A list cell that opens something when tapped (e.g. a post) has no element of its own in SwiftUI;
  // add one, tapped on its text (away from the buttons inside it), as a person would.
  for (NSDictionary *cell in c.cells) {
    CGRect cf = [cell[@"frame"] CGRectValue];
    NSMutableArray *words = [NSMutableArray array], *inside = [NSMutableArray array];
    for (NSDictionary *t in c.shownTexts) {
      CGRect tf = [t[@"frame"] CGRectValue];
      if (CGRectContainsPoint(cf, CGPointMake(CGRectGetMidX(tf), CGRectGetMidY(tf)))) [words addObject:t[@"label"]];
    }
    for (NSDictionary *e in c.els) {
      CGRect ef = CGRectMake([e[@"frame"][0] doubleValue], [e[@"frame"][1] doubleValue], [e[@"frame"][2] doubleValue], [e[@"frame"][3] doubleValue]);
      if (!CGRectContainsPoint(cf, CGPointMake(CGRectGetMidX(ef), CGRectGetMidY(ef)))) continue;
      if (![e[@"in"] isEqualToString:cell[@"in"]]) continue;  // e.g. the tab bar over a cell's lower edge
      [inside addObject:[NSValue valueWithCGRect:ef]];
      // Skip counters ("491", "5 · 238"): they don't say what the row is.
      if (words.count < 3) for (NSString *w in @[e[@"label"] ?: @"", e[@"context"] ?: @""])
        if (w.length > 2 && [w rangeOfString:@"[A-Za-z\\p{L}]{2}" options:NSRegularExpressionSearch].location != NSNotFound && ![words containsObject:w]) [words addObject:w];
    }
    if (!words.count) continue;
    if (cell[@"group"] && inside.count < 2) continue;
    // Redundant rows: a cell that is basically one control, or that hosts its own scroll area (a carousel).
    BOOL oneControl = NO, hostsScroll = NO;
    for (NSValue *ev in inside) {
      CGRect ef = [ev CGRectValue];
      if (ef.size.width * ef.size.height >= 0.7 * cf.size.width * cf.size.height) oneControl = YES;
    }
    for (NSDictionary *sc in c.scrolls) {
      CGRect sf = CGRectMake([sc[@"frame"][0] doubleValue], [sc[@"frame"][1] doubleValue], [sc[@"frame"][2] doubleValue], [sc[@"frame"][3] doubleValue]);
      if (![sc[@"ref"] isEqualToString:cell[@"in"]] && CGRectContainsPoint(cf, CGPointMake(CGRectGetMidX(sf), CGRectGetMidY(sf)))) hostsScroll = YES;
    }
    if (oneControl || hostsScroll || inside.count == 1) continue;  // a single inner control already is the row
    BOOL dupRow = NO;
    for (NSDictionary *e in c.els) if ([e[@"kind"] isEqualToString:@"row"]) {
      CGRect rf = CGRectMake([e[@"frame"][0] doubleValue], [e[@"frame"][1] doubleValue], [e[@"frame"][2] doubleValue], [e[@"frame"][3] doubleValue]);
      CGRect ov = CGRectIntersection(rf, cf);
      if (!CGRectIsEmpty(ov) && ov.size.width * ov.size.height > 0.8 * MIN(rf.size.width * rf.size.height, cf.size.width * cf.size.height)) dupRow = YES;
    }
    if (dupRow) continue;
    // Tap a free spot (on no element) nearest the cell's middle: where a person taps to open the row.
    CGPoint best = CGPointZero; double bestD = 1e9;
    for (int gx = 1; gx < 8; gx++) for (int gy = 1; gy < 6; gy++) {
      CGPoint p = CGPointMake(CGRectGetMinX(cf) + cf.size.width * gx / 8, CGRectGetMinY(cf) + cf.size.height * gy / 6);
      BOOL onEl = NO;
      for (NSValue *ev in inside) if (CGRectContainsPoint(CGRectInset([ev CGRectValue], -4, -4), p)) { onEl = YES; break; }
      if (onEl) continue;
      UIView *hit = HitAt(p, c.windows);
      if (!hit) continue;
      double d = hypot(p.x - CGRectGetMidX(cf), p.y - CGRectGetMidY(cf));
      if (d < bestD) { bestD = d; best = p; }
    }
    if (bestD >= 1e9) continue;
    NSString *label = [words componentsJoinedByString:@" · "];
    if (label.length > 160) label = [label substringToIndex:160];
    [c.els addObject:@{@"kind": @"row", @"id": @"", @"label": label, @"frame": R(cf), @"tap": @[N(best.x), N(best.y)], @"in": cell[@"in"]}];
  }
  // An element whose area contains other elements is a container (e.g. a whole post as one button). Its own
  // activation point often sits on an inner control (the avatar), so: label it from its contents, tap a free spot.
  NSMutableArray *rebuilt = [NSMutableArray array];
  for (NSDictionary *e in c.els) {
    if ([e[@"kind"] isEqualToString:@"row"] || [e[@"kind"] isEqualToString:@"input"]) { [rebuilt addObject:e]; continue; }
    CGRect cf = CGRectMake([e[@"frame"][0] doubleValue], [e[@"frame"][1] doubleValue], [e[@"frame"][2] doubleValue], [e[@"frame"][3] doubleValue]);
    NSMutableArray *inside = [NSMutableArray array], *words = [NSMutableArray array];
    for (NSDictionary *o in c.els) {
      if (o == e) continue;
      CGRect of = CGRectMake([o[@"frame"][0] doubleValue], [o[@"frame"][1] doubleValue], [o[@"frame"][2] doubleValue], [o[@"frame"][3] doubleValue]);
      if (!CGRectContainsRect(CGRectInset(cf, -1, -1), of) || CGRectEqualToRect(of, cf)) continue;
      if (![(o[@"in"] ?: @"") isEqualToString:(e[@"in"] ?: @"")]) continue;  // not from another area (tab bar)
      [inside addObject:[NSValue valueWithCGRect:of]];
      for (NSString *w in @[o[@"context"] ?: @"", o[@"label"] ?: @""])
        if (words.count < 3 && w.length > 2 && [w rangeOfString:@"[A-Za-z\\p{L}]{2}" options:NSRegularExpressionSearch].location != NSNotFound && ![words containsObject:w]) [words addObject:w];
    }
    if (inside.count < 2) { [rebuilt addObject:e]; continue; }
    // Aim just below the top inner element (a post's header): that's where its text is. The middle tends to be
    // media, which opens a viewer or nothing.
    CGRect top = CGRectNull;
    for (NSValue *ev in inside) if (CGRectIsNull(top) || CGRectGetMinY([ev CGRectValue]) < CGRectGetMinY(top)) top = [ev CGRectValue];
    CGPoint aim = CGPointMake(CGRectGetMidX(top), CGRectGetMaxY(top) + 18);
    CGPoint best = CGPointZero; double bestD = 1e9;
    for (int gx = 1; gx < 10; gx++) for (int gy = 1; gy < 16; gy++) {
      CGPoint p = CGPointMake(CGRectGetMinX(cf) + cf.size.width * gx / 10, CGRectGetMinY(cf) + cf.size.height * gy / 16);
      BOOL onEl = NO;
      for (NSValue *ev in inside) if (CGRectContainsPoint(CGRectInset([ev CGRectValue], -4, -4), p)) { onEl = YES; break; }
      if (onEl || !HitAt(p, c.windows)) continue;
      double d = hypot(p.x - aim.x, p.y - aim.y);
      if (d < bestD) { bestD = d; best = p; }
    }
    if (bestD >= 1e9) { [rebuilt addObject:e]; continue; }
    NSMutableDictionary *m = [e mutableCopy];
    m[@"kind"] = @"row";
    if (![e[@"label"] length]) { NSString *l = [words componentsJoinedByString:@" · "]; m[@"label"] = l.length > 160 ? [l substringToIndex:160] : l; }
    m[@"tap"] = @[N(best.x), N(best.y)];
    [rebuilt addObject:m];
  }
  [c.els setArray:rebuilt];
  // SwiftUI views with only a tap gesture have no element; their visible text is the best handle.
  NSMutableArray *textItems = [NSMutableArray array];
  for (NSDictionary *t in c.shownTexts) {
    CGRect tf = [t[@"frame"] CGRectValue]; CGPoint mid = CGPointMake(CGRectGetMidX(tf), CGRectGetMidY(tf)); BOOL covered = NO;
    for (NSDictionary *e in c.els) {
      CGRect ef = CGRectMake([e[@"frame"][0] doubleValue], [e[@"frame"][1] doubleValue], [e[@"frame"][2] doubleValue], [e[@"frame"][3] doubleValue]);
      if (![e[@"kind"] isEqualToString:@"row"] && CGRectContainsPoint(ef, mid)) { covered = YES; break; }
    }
    if (!covered && textItems.count < 40) [textItems addObject:@{@"label": t[@"label"], @"tap": @[N(mid.x), N(mid.y)]}];
  }
  for (NSMutableDictionary *s in c.scrolls) {
    NSMutableArray *ahead = [NSMutableArray array];
    for (NSDictionary *h in c.hidden) if ([h[@"in"] isEqualToString:s[@"ref"]] && ahead.count < 20)
      [ahead addObject:@{@"dir": h[@"dir"], @"what": [@[h[@"label"], h[@"context"] ?: @""] componentsJoinedByString:@" — "]}];
    c.ahead[s[@"ref"]] = ahead;
  }
  for (NSMutableDictionary *s in c.scrolls) { s[@"hiddenItems"] = c.hiddenIn[s[@"ref"]] ?: @0; s[@"ahead"] = c.ahead[s[@"ref"]] ?: @[]; }
  // A pushed screen often hides the tab bar; say where its tabs went, or "Saved tab" looks unreachable.
  for (UIWindow *w in c.windows) {
    NSMutableArray *q = [NSMutableArray arrayWithObjects:w.rootViewController, nil];
    for (NSUInteger i = 0; i < q.count && i < 50; i++) {
      UIViewController *vc = q[i];
      [q addObjectsFromArray:vc.childViewControllers];
      if (vc.presentedViewController) [q addObject:vc.presentedViewController];
      if (![vc isKindOfClass:UITabBarController.class]) continue;
      UITabBar *bar = ((UITabBarController *)vc).tabBar;
      CGRect f = bar.window ? [bar convertRect:bar.bounds toView:nil] : CGRectNull;
      BOOL shown = bar.window && !bar.hidden && bar.alpha > 0.01 && CGRectIntersectsRect(f, UIScreen.mainScreen.bounds);
      if (shown) continue;
      NSMutableArray *names = [NSMutableArray array];
      for (UITabBarItem *it in bar.items) if (it.title.length) [names addObject:it.title];
      if (names.count) [c.texts addObject:[NSString stringWithFormat:@"(Tab bar with %@ is hidden on this screen; go Back to reach it.)", [names componentsJoinedByString:@", "]]];
      break;
    }
  }
  // One control often shows up as its view, an inner AX element and a row: same id + overlapping frames = one entry.
  NSMutableArray *uniq = [NSMutableArray array];
  int (^rank)(NSDictionary *) = ^int(NSDictionary *x) {
    return ([x[@"kind"] isEqualToString:@"row"] ? 0 : 4) + ([x[@"kind"] isEqualToString:@"button"] ? 2 : 0) + ([x[@"label"] length] ? 1 : 0);
  };
  for (NSDictionary *e in c.els) {
    NSUInteger dup = NSNotFound;
    if ([e[@"id"] length]) for (NSUInteger j = 0; j < uniq.count && dup == NSNotFound; j++) {
      NSArray *f = e[@"frame"], *g = uniq[j][@"frame"];
      CGRect a = CGRectMake([f[0] doubleValue], [f[1] doubleValue], [f[2] doubleValue], [f[3] doubleValue]);
      CGRect b = CGRectMake([g[0] doubleValue], [g[1] doubleValue], [g[2] doubleValue], [g[3] doubleValue]);
      if ([uniq[j][@"id"] isEqualToString:e[@"id"]] && CGRectIntersectsRect(a, b)) dup = j;
    }
    if (dup == NSNotFound) [uniq addObject:e];
    else if (rank(e) > rank(uniq[dup])) uniq[dup] = e;
  }
  c.els = uniq;
  CGRect sb = UIScreen.mainScreen.bounds;
  NSMutableDictionary *kb = [@{@"open": @(!CGRectIsEmpty(CGRectIntersection(gKeyboard, sb)))} mutableCopy];
  if ([kb[@"open"] boolValue]) kb[@"frame"] = R(CGRectIntersection(gKeyboard, sb));
  if (c.focused) {
    kb[@"focused"] = NearestId(c.focused);
    if ([c.focused conformsToProtocol:@protocol(UITextInputTraits)] && [c.focused respondsToSelector:@selector(returnKeyType)])
      kb[@"returnKey"] = @[@"default", @"go", @"google", @"join", @"next", @"route", @"search", @"send", @"yahoo", @"done", @"emergencyCall", @"continue"][MIN((NSInteger)[(id<UITextInputTraits>)c.focused returnKeyType], 11)];
  }
  NSString *title = nil;
  for (UIWindow *w in c.windows.reverseObjectEnumerator) if ((title = NavTitle(w))) break;
  NSDictionary *out = @{@"title": title ?: @"", @"screen": @[@(sb.size.width), @(sb.size.height)], @"windows": wnames,
                        @"keyboard": kb, @"active": @(UIApplication.sharedApplication.applicationState == UIApplicationStateActive), @"animating": @(c.animating), @"loading": @(c.loading), @"elements": c.els, @"textItems": textItems, @"hidden": c.hidden, @"remote": c.remote, @"text": c.texts, @"scrolls": c.scrolls, @"ms": @((CACurrentMediaTime() - t0) * 1000)};
  return [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
}

// Top of the view tree with visibility facts, for diagnosing empty reads.
static void Dump(UIView *v, int depth, NSMutableArray *out) {
  if (depth > 9 || out.count > 400) return;
  CGRect f = [v.window convertRect:[v convertRect:v.bounds toView:nil] toWindow:nil];
  [out addObject:[NSString stringWithFormat:@"%*s%@ hidden=%d alpha=%.2f pres=%.2f clip=%d ax=%d id=%@ %@", depth * 2, "", NSStringFromClass(v.class),
    v.hidden, v.alpha, v.layer.presentationLayer ? v.layer.presentationLayer.opacity : -1, v.clipsToBounds, v.isAccessibilityElement, v.accessibilityIdentifier ?: @"", NSStringFromCGRect(f)]];
  if (!v.hidden) for (UIView *sub in v.subviews) Dump(sub, depth + 1, out);
}

static NSString *gToken;

static void *Serve(void *arg) {
  gToken = getenv("SIMFLICK_TOKEN") ? @(getenv("SIMFLICK_TOKEN")) : nil;
  if (!gToken.length) NSLog(@"[simflick] no SIMFLICK_TOKEN set; any local process can drive this app");
  int port = getenv("SIMFLICK_PORT") ? atoi(getenv("SIMFLICK_PORT")) : 8765;
  int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 8)) { NSLog(@"[simflick] bind %d failed", port); return NULL; }
  NSLog(@"[simflick] listening on 127.0.0.1:%d", port);
  for (;;) {
    int cl = accept(fd, NULL, NULL); if (cl < 0) continue;
    char buf[2048]; ssize_t n = recv(cl, buf, sizeof buf - 1, 0); buf[n > 0 ? n : 0] = 0;
    __block NSData *body = nil;
    NSString *req = [NSString stringWithUTF8String:buf] ?: @"";
    NSArray *line = [[req componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    NSString *method = line.firstObject;
    NSURLComponents *u = line.count > 1 ? [NSURLComponents componentsWithString:line[1]] : nil;
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *it in u.queryItems) if (it.value) q[it.name] = it.value;
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    for (NSString *l in [req componentsSeparatedByString:@"\r\n"]) {
      NSRange c = [l rangeOfString:@":"];
      if (c.location != NSNotFound) h[[l substringToIndex:c.location].lowercaseString] = [[l substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    // Browsers can reach 127.0.0.1 too: require the launch token, a local Host (DNS rebinding), no Origin
    // (any web page), and POST for anything that acts.
    NSString *host = [h[@"host"] componentsSeparatedByString:@":"].firstObject ?: @"";
    int status = 0;
    if (h[@"origin"] || !([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"])) status = 403;
    else if (gToken.length && ![h[@"x-simflick-token"] isEqualToString:gToken]) status = 401;
    else if (![u.path isEqualToString:@"/screen"] && ![u.path isEqualToString:@"/debug"] && ![method isEqualToString:@"POST"]) status = 405;
    if (status) {
      NSString *r = [NSString stringWithFormat:@"HTTP/1.1 %d Rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status];
      send(cl, r.UTF8String, strlen(r.UTF8String), 0); close(cl); continue;
    }
    if ([u.path isEqualToString:@"/screen"]) dispatch_sync(dispatch_get_main_queue(), ^{ @autoreleasepool {
      gRejects = q[@"debug"] ? [NSMutableArray array] : nil;
      body = Screen();
      if (gRejects) body = [NSJSONSerialization dataWithJSONObject:gRejects options:0 error:nil];
      gRejects = nil;
    } });
    else if ([u.path isEqualToString:@"/debug"]) dispatch_sync(dispatch_get_main_queue(), ^{
      NSMutableArray *lines = [NSMutableArray array];
      for (UIWindow *w in Windows()) Dump(w, 0, lines);
      body = [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    });
    else if (u.path) body = SRHandleAction(u.path, q);
    NSString *head = body ? [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)body.length]
                          : @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    send(cl, head.UTF8String, strlen(head.UTF8String), 0);
    if (body) send(cl, body.bytes, body.length, 0);
    close(cl);
  }
}

__attribute__((constructor)) static void Start(void) {
  // SwiftUI builds its full accessibility tree only for an attached AX client; turn on automation mode
  // like KIF does (private libAccessibility call), so buttons inside rows and cells are exposed.
  void *ax = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
  void (*setAutomation)(int) = ax ? (void (*)(int))dlsym(ax, "_AXSSetAutomationEnabled") : NULL;
  if (setAutomation) setAutomation(1); else NSLog(@"[simflick] _AXSSetAutomationEnabled unavailable");
  // What an AX client (VoiceOver, axe) triggers: load the UIKit and SwiftUI accessibility bundles once UIKit is up.
  dispatch_async(dispatch_get_main_queue(), ^{
    for (NSString *b in @[@"UIKit", @"SwiftUI"]) {
      // Simulator processes see iOS system files under IPHONE_SIMULATOR_ROOT, not under the Mac's /System.
      NSString *root = NSProcessInfo.processInfo.environment[@"IPHONE_SIMULATOR_ROOT"] ?: @"";
      NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/System/Library/AccessibilityBundles/%@.axbundle", root, b]];
      NSError *err = nil;
      if (!bundle || ![bundle loadAndReturnError:&err]) NSLog(@"[simflick] could not load %@.axbundle: %@", b, err ?: @"bundle not found");
      else NSLog(@"[simflick] loaded %@.axbundle", b);
    }
  });
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserverForName:UIKeyboardWillChangeFrameNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    gKeyboard = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue]; }];
  [nc addObserverForName:UIKeyboardWillHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    gKeyboard = CGRectZero; }];
  pthread_t t; pthread_create(&t, NULL, Serve, NULL); pthread_detach(t);
}
