// Injected into a simulator app: GET /screen = what is actually on screen; /tap, /swipe act on it.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <pthread.h>

static NSArray<NSNumber *> *R(CGRect r) {
  return @[@(round(r.origin.x)), @(round(r.origin.y)), @(round(r.size.width)), @(round(r.size.height))];
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

static NSString *Kind(id v) {
  if ([v conformsToProtocol:@protocol(UITextInput)]) return @"input";
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

typedef struct { NSMutableArray *els, *scrolls, *texts; NSArray *windows; NSMutableDictionary *hiddenIn, *ahead; NSMutableArray *hidden, *axTexts, *remote; UIView *focused; BOOL animating; } Ctx;

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
  // Drop slivers: under a third showing and too thin to tap reliably.
  CGFloat frac = frame.size.width * frame.size.height > 0 ? (vis.size.width * vis.size.height) / (frame.size.width * frame.size.height) : 0;
  if (shown && frac < 0.33 && (vis.size.height < 24 || vis.size.width < 24)) shown = NO;
  NSString *kind = Kind(obj);
  // Non-view text/headers (SwiftUI) are page text and context sources, not things to act on.
  if (!isView && ([kind isEqualToString:@"text"] || [kind isEqualToString:@"header"])) {
    if (shown && label.length) [c->texts addObject:label];
    if (label.length && myScroll) [c->axTexts addObject:@{@"label": label, @"frame": R(frame), @"in": myScroll[@"ref"]}];
    return;
  }
  if (shown) {
    NSMutableDictionary *e = [@{@"kind": kind, @"id": ident, @"label": label,
                                @"frame": R(frame), @"tap": @[@(round(tap.x)), @(round(tap.y))]} mutableCopy];
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
  NSArray *a = [o respondsToSelector:@selector(accessibilityElements)] ? [o accessibilityElements] : nil;
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

  // Content drawn by another process (Safari sheets, web sign-in, some system UI) is opaque to us and to axe.
  if ([NSStringFromClass(v.class) isEqualToString:@"_UIRemoteView"] && !CGRectIsEmpty(vis)) {
    UIView *hit = HitAt(CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis)), c->windows);
    NSString *host = @"";
    for (UIView *p = v.superview; p && !host.length; p = p.superview) if (![NSStringFromClass(p.class) hasPrefix:@"_"]) host = NSStringFromClass(p.class);
    if (hit && ([hit isDescendantOfView:v] || hit == v)) [c->remote addObject:@{@"frame": R(vis), @"host": host}];
  }
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
                             @"offset": @[@(round(o.x)), @(round(o.y))], @"content": @[@(round(cs.width)), @(round(cs.height))], @"paging": @(s.isPagingEnabled)} mutableCopy]];
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
  Ctx c = {[NSMutableArray array], [NSMutableArray array], [NSMutableArray array], Windows(), [NSMutableDictionary dictionary], [NSMutableDictionary dictionary], [NSMutableArray array], [NSMutableArray array], [NSMutableArray array]};
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
  [c.els setArray:merged];
  for (NSMutableDictionary *s in c.scrolls) {
    NSMutableArray *ahead = [NSMutableArray array];
    for (NSDictionary *h in c.hidden) if ([h[@"in"] isEqualToString:s[@"ref"]] && ahead.count < 20)
      [ahead addObject:@{@"dir": h[@"dir"], @"what": [@[h[@"label"], h[@"context"] ?: @""] componentsJoinedByString:@" — "]}];
    c.ahead[s[@"ref"]] = ahead;
  }
  for (NSMutableDictionary *s in c.scrolls) { s[@"hiddenItems"] = c.hiddenIn[s[@"ref"]] ?: @0; s[@"ahead"] = c.ahead[s[@"ref"]] ?: @[]; }
  CGRect sb = UIScreen.mainScreen.bounds;
  NSMutableDictionary *kb = [@{@"open": @(!CGRectIsEmpty(CGRectIntersection(gKeyboard, sb)))} mutableCopy];
  if ([kb[@"open"] boolValue]) kb[@"frame"] = R(CGRectIntersection(gKeyboard, sb));
  if (c.focused) {
    kb[@"focused"] = NearestId(c.focused);
    if ([c.focused conformsToProtocol:@protocol(UITextInputTraits)] && [c.focused respondsToSelector:@selector(returnKeyType)])
      kb[@"returnKey"] = @[@"default", @"go", @"google", @"join", @"next", @"route", @"search", @"send", @"yahoo", @"done", @"emergencyCall", @"continue"][MIN((NSInteger)[(id<UITextInputTraits>)c.focused returnKeyType], 11)];
  }
  NSDictionary *out = @{@"screen": @[@(sb.size.width), @(sb.size.height)], @"windows": wnames,
                        @"keyboard": kb, @"active": @(UIApplication.sharedApplication.applicationState == UIApplicationStateActive), @"animating": @(c.animating), @"elements": c.els, @"hidden": c.hidden, @"remote": c.remote, @"text": c.texts, @"scrolls": c.scrolls, @"ms": @((CACurrentMediaTime() - t0) * 1000)};
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
    if ([u.path isEqualToString:@"/screen"]) dispatch_sync(dispatch_get_main_queue(), ^{ @autoreleasepool { body = Screen(); } });
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
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserverForName:UIKeyboardWillChangeFrameNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    gKeyboard = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue]; }];
  [nc addObserverForName:UIKeyboardWillHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    gKeyboard = CGRectZero; }];
  pthread_t t; pthread_create(&t, NULL, Serve, NULL); pthread_detach(t);
}
