// Stage 3: page-level facts (title, keyboard, app state) and the JSON a client gets from GET /screen.
#import "SFModel.h"

// The keyboard is drawn by another process; the app only learns its frame from these notifications.
static CGRect gKeyboard;
CGRect SFKeyboardFrame(void) { return gKeyboard; }  // screen coordinates, like everything else
void SFKeyboardTrack(void) {
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserverForName:UIKeyboardWillChangeFrameNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    gKeyboard = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue]; }];
  [nc addObserverForName:UIKeyboardWillHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    gKeyboard = CGRectZero; }];
}

// The visible navigation bar's title ("Trending"), so a list isn't mistaken for the item it shows.
static NSString *NavTitle(UIView *v) {
  if (v.hidden || v.alpha < 0.01) return nil;
  if ([v isKindOfClass:UINavigationBar.class]) {
    UINavigationItem *it = ((UINavigationBar *)v).topItem;
    NSString *t = it.title.length ? it.title : ([it.titleView accessibilityLabel] ?: nil);
    if (t.length && v.window && CGRectIntersectsRect(SFFrameOnScreen(v), SFAppBounds())) return t;
  }
  for (UIView *sub in v.subviews.reverseObjectEnumerator) { NSString *t = NavTitle(sub); if (t) return t; }
  return nil;
}

static NSDictionary *KeyboardJSON(UIView *focused) {
  CGRect on = CGRectIntersection(SFKeyboardFrame(), SFAppBounds());
  NSMutableDictionary *kb = [@{@"open": @(!CGRectIsEmpty(on))} mutableCopy];
  if (!CGRectIsEmpty(on)) kb[@"frame"] = SFRectJSON(on);
  if (focused) {
    kb[@"focused"] = SFNearestId(focused);
    if ([focused conformsToProtocol:@protocol(UITextInputTraits)] && [focused respondsToSelector:@selector(returnKeyType)]) {
      NSArray *names = @[@"default", @"go", @"google", @"join", @"next", @"route", @"search", @"send", @"yahoo", @"done", @"emergencyCall", @"continue"];
      kb[@"returnKey"] = names[MIN((NSInteger)[(id<UITextInputTraits>)focused returnKeyType], (NSInteger)names.count - 1)];
    }
  }
  return kb;
}

NSData *SFScreenJSON(BOOL debug) {
  CFTimeInterval t0 = CACurrentMediaTime();
  SFSnapshot *s = SFCollect(debug);
  if (debug) return [NSJSONSerialization dataWithJSONObject:s.debug options:0 error:nil];
  SFRefine(s);
  NSString *title = nil;
  for (UIWindow *w in s.windows.reverseObjectEnumerator) if ((title = NavTitle(w))) break;
  NSMutableArray *windows = [NSMutableArray array], *nodes = [NSMutableArray array], *hidden = [NSMutableArray array], *scrolls = [NSMutableArray array];
  for (UIWindow *w in s.windows) [windows addObject:NSStringFromClass(w.class)];
  for (SFNode *n in s.nodes) [nodes addObject:n.json];
  for (SFNode *n in s.hidden) [hidden addObject:n.hiddenJSON];
  for (SFScrollArea *a in s.scrolls) [scrolls addObject:a.json];
  CGSize screen = SFAppBounds().size;
  NSDictionary *out = @{@"title": title ?: @"", @"screen": @[@(screen.width), @(screen.height)], @"windows": windows,
    @"keyboard": KeyboardJSON(s.focused), @"active": @(UIApplication.sharedApplication.applicationState == UIApplicationStateActive),
    @"animating": @(s.animating), @"loading": @(s.loading), @"elements": nodes, @"textItems": s.textItems, @"hidden": hidden,
    @"remote": s.remote, @"text": s.pageText, @"scrolls": scrolls, @"ms": @((CACurrentMediaTime() - t0) * 1000)};
  return [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
}

// Top of the view tree with visibility facts, for diagnosing empty reads (GET /debug).
static void Dump(UIView *v, int depth, NSMutableArray *out) {
  if (depth > 20 || out.count > 1500) return;
  [out addObject:[NSString stringWithFormat:@"%*s%@ hidden=%d alpha=%.2f pres=%.2f clip=%d ax=%d id=%@ %@", depth * 2, "", NSStringFromClass(v.class),
    v.hidden, v.alpha, v.layer.presentationLayer ? v.layer.presentationLayer.opacity : -1, v.clipsToBounds, v.isAccessibilityElement,
    v.accessibilityIdentifier ?: @"", NSStringFromCGRect(SFFrameOnScreen(v))]];
  if (!v.hidden) for (UIView *sub in v.subviews) Dump(sub, depth + 1, out);
}
NSData *SFViewDump(void) {
  NSMutableArray *lines = [NSMutableArray array];
  for (UIWindow *w in SFWindows()) Dump(w, 0, lines);
  return [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
}
