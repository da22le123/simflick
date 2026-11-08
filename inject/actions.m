// In-process touch synthesis (KIF recipe): UITouch + IOHIDEvent via UIApplication sendEvent:.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

@interface UITouch (Private)
- (void)setWindow:(UIWindow *)w;
- (void)setView:(UIView *)v;
- (void)setPhase:(UITouchPhase)p;
- (void)setTapCount:(NSUInteger)n;
- (void)setTimestamp:(NSTimeInterval)t;
- (void)setIsTap:(BOOL)b;
- (void)_setIsFirstTouchForView:(BOOL)b;
- (void)_setLocationInWindow:(CGPoint)p resetPrevious:(BOOL)r;
- (void)_setHidEvent:(void *)e;
- (void)_setIsTapToClick:(BOOL)b;
@end
@interface UIEvent (Private)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)t forDelayedDelivery:(BOOL)d;
- (void)_setHIDEvent:(void *)e;
@end
@interface UIApplication (Private)
- (UIEvent *)_touchesEvent;
@end

typedef void *HIDRef;
typedef HIDRef (*HandFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
typedef HIDRef (*FingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, double, double, double, double, double, Boolean, Boolean, uint32_t);
typedef void (*SetIntFn)(HIDRef, uint32_t, long);
typedef void (*AppendFn)(HIDRef, HIDRef, uint32_t);
static HandFn sHand; static FingerFn sFinger; static SetIntFn sSetInt; static AppendFn sAppend;
enum { kHand = 3, kRange = 1, kTouch = 2, kPosition = 4, kDisplayIntegrated = (11 << 16) | 25 };

static void LoadHID(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    sHand = (HandFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    sFinger = (FingerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEventWithQuality");
    sSetInt = (SetIntFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
    sAppend = (AppendFn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
  });
}

static HIDRef HIDFor(UITouch *t) {
  uint64_t now = mach_absolute_time();
  HIDRef hand = sHand(kCFAllocatorDefault, now, kHand, 0, 0, kTouch, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  sSetInt(hand, kDisplayIntegrated, 1);
  BOOL down = t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled;
  uint32_t mask = t.phase == UITouchPhaseMoved ? kPosition : (kRange | kTouch);
  CGPoint p = [t locationInView:t.window];
  HIDRef finger = sFinger(kCFAllocatorDefault, now, 1, 2, mask, p.x, p.y, 0, 0, 0, 0, 0, 0, 0, 0, down, down, 0);
  sSetInt(finger, kDisplayIntegrated, 1);
  sAppend(hand, finger, 0);
  CFRelease(finger);
  return hand;
}

static void Send(UITouch *t, UITouchPhase phase) {
  [t setPhase:phase];
  [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
  HIDRef h = HIDFor(t);
  [t _setHidEvent:h];
  UIEvent *e = [UIApplication.sharedApplication _touchesEvent];
  [e _clearTouches];
  [e _setHIDEvent:h];
  [e _addTouch:t forDelayedDelivery:NO];
  CFRelease(h);
  [UIApplication.sharedApplication sendEvent:e];
}

static NSMutableSet *gMissing;
static NSDictionary *gLastHit;
static void Missing(NSString *sel) { if (!gMissing) gMissing = [NSMutableSet set]; [gMissing addObject:sel]; }

// Topmost visible window whose hit-test claims the point, like a real finger.
static UITouch *TouchAt(CGPoint screenPt, UIView **hitOut) {
  NSMutableArray *ws = [NSMutableArray array];
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
    if ([s isKindOfClass:UIWindowScene.class]) [ws addObjectsFromArray:((UIWindowScene *)s).windows];
  [ws sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) { return a.windowLevel > b.windowLevel ? NSOrderedAscending : a.windowLevel < b.windowLevel ? NSOrderedDescending : NSOrderedSame; }];
  for (UIWindow *w in ws) {
    if (w.hidden) continue;
    CGPoint p = [w convertPoint:screenPt fromWindow:nil];
    UIView *hit = [w hitTest:p withEvent:nil];
    if (!hit) continue;
    UITouch *t = [UITouch new];
    if ([t respondsToSelector:@selector(setTapCount:)]) [t setTapCount:1]; else Missing(@"setTapCount:");
    if ([t respondsToSelector:@selector(setIsTap:)]) [t setIsTap:YES]; else Missing(@"setIsTap:");
    [t _setLocationInWindow:p resetPrevious:YES];
    [t setWindow:w];
    [t setView:hit];
    if ([t respondsToSelector:@selector(_setIsFirstTouchForView:)]) [t _setIsFirstTouchForView:YES]; else Missing(@"_setIsFirstTouchForView:");
    if ([t respondsToSelector:@selector(_setIsTapToClick:)]) [t _setIsTapToClick:NO];
    if (hitOut) *hitOut = hit;
    NSMutableArray *grs = [NSMutableArray array];
    for (UIView *a = hit; a; a = a.superview) for (UIGestureRecognizer *g in a.gestureRecognizers) if (g.enabled) [grs addObject:[NSString stringWithFormat:@"%@@%@", NSStringFromClass(g.class), NSStringFromClass(a.class)]];
    gLastHit = @{@"class": NSStringFromClass(hit.class), @"recognizers": grs};
    return t;
  }
  return nil;
}

// Path of points (screen coords) with per-step delay; the last few points repeat to kill momentum.
static void RunPath(NSArray<NSValue *> *pts, double stepSec, void (^done)(NSString *hitId)) {
  LoadHID();
  UIView *hit = nil;
  UITouch *t = TouchAt(pts.firstObject.CGPointValue, &hit);
  if (!t) { done(nil); return; }
  NSString *hid = hit.accessibilityIdentifier ?: @"";
  for (UIView *a = hit; !hid.length && a; a = a.superview) hid = a.accessibilityIdentifier ?: @"";
  Send(t, UITouchPhaseBegan);
  __block NSUInteger i = 1;
  __block void (^step)(void);
  __weak __block void (^weakStep)(void);
  weakStep = step = ^{
    if (i < pts.count) {
      CGPoint p = [t.window convertPoint:pts[i].CGPointValue fromWindow:nil];
      [t _setLocationInWindow:p resetPrevious:NO];
      Send(t, UITouchPhaseMoved);
      i++;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stepSec * NSEC_PER_SEC)), dispatch_get_main_queue(), weakStep);
    } else {
      Send(t, UITouchPhaseEnded);
      done(hid);
    }
  };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stepSec * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
}

static double Q(NSDictionary *q, NSString *k, double dflt) { return q[k] ? [q[k] doubleValue] : dflt; }

// Called from the server thread; blocks until the gesture finished on the main thread.
NSData *SRHandleAction(NSString *path, NSDictionary<NSString *, NSString *> *q) {
  CFTimeInterval t0 = CACurrentMediaTime();
  NSMutableArray<NSValue *> *pts = [NSMutableArray array];
  double step = 1.0 / 60;
  if ([path isEqualToString:@"/tap"]) {
    CGPoint p = CGPointMake(Q(q, @"x", 0), Q(q, @"y", 0));
    for (int i = 0; i < 4; i++) [pts addObject:[NSValue valueWithCGPoint:p]];  // ~50 ms press, no movement
  } else if ([path isEqualToString:@"/swipe"]) {
    CGPoint a = CGPointMake(Q(q, @"x1", 0), Q(q, @"y1", 0)), b = CGPointMake(Q(q, @"x2", 0), Q(q, @"y2", 0));
    int n = MAX(2, (int)(Q(q, @"ms", 300) / 1000.0 / step));
    for (int i = 0; i <= n; i++) [pts addObject:[NSValue valueWithCGPoint:CGPointMake(a.x + (b.x - a.x) * i / n, a.y + (b.y - a.y) * i / n)]];
    if (!q[@"fling"]) for (int i = 0; i < 6; i++) [pts addObject:pts.lastObject];  // hold ~100 ms before lifting
  } else {
    return nil;
  }
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSString *hitId = nil;
  dispatch_async(dispatch_get_main_queue(), ^{ RunPath(pts, step, ^(NSString *h) { hitId = h; dispatch_semaphore_signal(sem); }); });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  NSDictionary *out = @{@"ok": @(hitId != nil), @"hit": hitId ?: [NSNull null], @"ms": @((CACurrentMediaTime() - t0) * 1000), @"missingSelectors": gMissing.allObjects ?: @[], @"debug": gLastHit ?: @{}};
  return [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
}
