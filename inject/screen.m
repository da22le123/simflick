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

static NSString *Kind(UIView *v) {
  if ([v conformsToProtocol:@protocol(UITextInput)]) return @"input";
  UIAccessibilityTraits t = v.accessibilityTraits;
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

typedef struct { NSMutableArray *els, *scrolls, *texts; NSArray *windows; NSMutableDictionary *hiddenIn, *ahead; NSMutableArray *hidden; UIView *focused; BOOL animating; } Ctx;

// Skips text owned by other tappable elements (e.g. a neighbouring tab), which would mislabel this one.
static void CollectText(UIView *v, UIView *self_, NSMutableArray *out, int depth) {
  if (depth > 10 || out.count > 6 || v.hidden || v.alpha < 0.01 || v.layer.presentationLayer.opacity < 0.01) return;
  if (v != self_ && v.isAccessibilityElement && ![NSStringFromClass(v.class) containsString:@"Paragraph"]) return;
  if ([NSStringFromClass(v.class) containsString:@"Paragraph"]) {
    // Closed sheets park their text off screen; only count text that is on screen.
    CGRect f = [v convertRect:v.bounds toView:nil];
    if (v.accessibilityLabel.length && v.window && CGRectIntersectsRect(f, v.window.bounds)) [out addObject:v.accessibilityLabel];
    return;
  }
  for (UIView *sub in v.subviews) CollectText(sub, self_, out, depth + 1);
}

// Text of the card/row an element belongs to: climb until other text appears, stop before list-wide levels.
static NSString *ContextFor(UIView *v, NSString *own) {
  // Nested inside an accessible card (e.g. a "⋯" menu): the card's label is the best context.
  for (UIView *p = v.superview; p && ![p isKindOfClass:UIScrollView.class]; p = p.superview)
    if (p.isAccessibilityElement && p.accessibilityLabel.length) return p.accessibilityLabel;
  UIView *a = v.superview;
  for (int i = 0; a && i < 5; i++, a = a.superview) {
    if ([a isKindOfClass:UIScrollView.class] || [a isKindOfClass:UIWindow.class]) break;
    NSMutableArray *t = [NSMutableArray array];
    CollectText(a, v, t, 0);
    if (t.count > 6) break;
    [t removeObject:own ?: @""];
    if (t.count) { NSString *j = [t componentsJoinedByString:@" · "]; return j.length > 100 ? [j substringToIndex:100] : j; }
  }
  return @"";
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
  BOOL candidate = v.isAccessibilityElement || [v conformsToProtocol:@protocol(UITextInput)];
  if (candidate) {
    BOOL shown = NO; CGPoint tap = CGPointZero;
    if (!CGRectIsEmpty(vis) && vis.size.width >= 2 && vis.size.height >= 2) {
      CGPoint pts[5] = {{CGRectGetMidX(vis), CGRectGetMidY(vis)},
        {CGRectGetMinX(vis) + vis.size.width * .25, CGRectGetMinY(vis) + vis.size.height * .25},
        {CGRectGetMaxX(vis) - vis.size.width * .25, CGRectGetMinY(vis) + vis.size.height * .25},
        {CGRectGetMinX(vis) + vis.size.width * .25, CGRectGetMaxY(vis) - vis.size.height * .25},
        {CGRectGetMaxX(vis) - vis.size.width * .25, CGRectGetMaxY(vis) - vis.size.height * .25}};
      for (int i = 0; i < 5 && !shown; i++) {
        UIView *hit = HitAt(pts[i], c->windows);
        // Covered = the hit lands on an unrelated view; a hit on an ancestor means v just isn't touchable.
        if (hit && ([hit isDescendantOfView:v] || [v isDescendantOfView:hit])) { shown = YES; tap = pts[i]; }
      }
    }
    // Drop slivers: under a third showing and too thin to tap reliably.
    CGFloat frac = frame.size.width * frame.size.height > 0 ? (vis.size.width * vis.size.height) / (frame.size.width * frame.size.height) : 0;
    if (shown && frac < 0.33 && (vis.size.height < 24 || vis.size.width < 24)) shown = NO;
    if (shown) {
      NSMutableDictionary *e = [@{@"kind": Kind(v), @"id": NearestId(v), @"label": v.accessibilityLabel ?: @"",
                                  @"frame": R(frame), @"tap": @[@(round(tap.x)), @(round(tap.y))]} mutableCopy];
      if (!CGRectEqualToRect(CGRectIntegral(vis), CGRectIntegral(frame))) e[@"clipped"] = @YES;
      if (v.accessibilityValue.length) e[@"value"] = v.accessibilityValue;
      if (myScroll) e[@"in"] = myScroll[@"ref"];
      // Context only where it disambiguates (list/carousel items, nested buttons); tabs and headers get none.
      BOOL nested = NO;
      for (UIView *p = v.superview; p && !nested; p = p.superview) nested = p.isAccessibilityElement;
      NSString *ctx = (myScroll || nested) ? ContextFor(v, v.accessibilityLabel) : @"";
      if (ctx.length) e[@"context"] = ctx;
      if (v.accessibilityTraits & UIAccessibilityTraitSelected) e[@"selected"] = @YES;
      [c->els addObject:e];
    } else if (myScroll) {
      c->hiddenIn[myScroll[@"ref"]] = @([c->hiddenIn[myScroll[@"ref"]] intValue] + 1);
      CGRect sv = [myScroll[@"vis"] CGRectValue];
      CGFloat dx = (CGRectGetMidX(frame) - CGRectGetMidX(sv)) / MAX(sv.size.width, 1), dy = (CGRectGetMidY(frame) - CGRectGetMidY(sv)) / MAX(sv.size.height, 1);
      NSString *dir = fabs(dx) > fabs(dy) ? (dx > 0 ? @"right" : @"left") : (dy > 0 ? @"down" : @"up");
      NSMutableArray *list = c->ahead[myScroll[@"ref"]] ?: (c->ahead[myScroll[@"ref"]] = [NSMutableArray array]);
      NSString *what = [@[v.accessibilityLabel ?: @"", ContextFor(v, v.accessibilityLabel)] componentsJoinedByString:@" — "];
      if (list.count < 20) [list addObject:@{@"dir": dir, @"what": what}];
      if (c->hidden.count < 200) [c->hidden addObject:@{@"kind": Kind(v), @"id": NearestId(v), @"label": v.accessibilityLabel ?: @"",
        @"context": ContextFor(v, v.accessibilityLabel), @"frame": R(frame), @"in": myScroll[@"ref"], @"dir": dir}];
    }
    // Keep descending: an accessible card can contain its own buttons (e.g. a "⋯" menu) that iOS would merge away.
  }
  for (UIView *sub in v.subviews) Walk(sub, clip, myScroll, c);
}

static NSData *Screen(void) {
  CFTimeInterval t0 = CACurrentMediaTime();
  Ctx c = {[NSMutableArray array], [NSMutableArray array], [NSMutableArray array], Windows(), [NSMutableDictionary dictionary], [NSMutableDictionary dictionary], [NSMutableArray array]};
  NSMutableArray *wnames = [NSMutableArray array];
  for (UIWindow *w in c.windows) {
    [wnames addObject:NSStringFromClass(w.class)];
    CGRect clip = w.screen.bounds;
    if (!CGRectIsEmpty(CGRectIntersection(gKeyboard, clip))) clip.size.height = MAX(0, CGRectGetMinY(gKeyboard) - clip.origin.y);
    Walk(w, clip, nil, &c);
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
                        @"keyboard": kb, @"animating": @(c.animating), @"elements": c.els, @"hidden": c.hidden, @"text": c.texts, @"scrolls": c.scrolls, @"ms": @((CACurrentMediaTime() - t0) * 1000)};
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
