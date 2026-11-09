// Stage 1: walk views and the accessibility tree once, deciding per candidate what it is, whether a finger
// can reach it, and where to tap. Everything that needs several elements at once is left to SFRefine.
#import "SFModel.h"

typedef struct { BOOL reachable; CGPoint tap; } SFProbe;

// Reachable = a hit test at the middle or a quarter point lands on the owner (not on something covering it).
static SFProbe Probe(id obj, UIView *owner, CGRect vis, NSArray<UIWindow *> *windows) {
  SFProbe r = {NO, CGPointZero};
  if (CGRectIsEmpty(vis) || vis.size.width < kSFMinProbeSide || vis.size.height < kSFMinProbeSide) return r;
  CGFloat w = vis.size.width, h = vis.size.height;
  CGPoint pts[5] = {SFMid(vis),
    {CGRectGetMinX(vis) + w * .25, CGRectGetMinY(vis) + h * .25}, {CGRectGetMaxX(vis) - w * .25, CGRectGetMinY(vis) + h * .25},
    {CGRectGetMinX(vis) + w * .25, CGRectGetMaxY(vis) - h * .25}, {CGRectGetMaxX(vis) - w * .25, CGRectGetMaxY(vis) - h * .25}};
  for (int i = 0; i < 5 && !r.reachable; i++)
    if (SFHitBelongsTo(SFHitView(pts[i], windows), owner)) { r.reachable = YES; r.tap = pts[i]; }
  if (!r.reachable) return r;
  // Tap where iOS says the element activates (VoiceOver's point), e.g. the switch of a SwiftUI Toggle row.
  CGPoint ap = [obj accessibilityActivationPoint];
  if (CGRectContainsPoint(CGRectInset(vis, 1, 1), ap) && SFHitBelongsTo(SFHitView(ap, windows), owner)) r.tap = ap;
  return r;
}

// What a finger would touch instead: the nearest labelled view at that spot ("Add … to a reading list?").
static NSString *Describe(UIView *hit) {
  for (UIView *v = hit; v; v = v.superview) {
    if (v.accessibilityLabel.length) return v.accessibilityLabel;
    for (UIView *sub in v.subviews) if (SFIsTextView(sub) && sub.accessibilityLabel.length) return sub.accessibilityLabel;
  }
  return hit ? NSStringFromClass(hit.class) : @"something";
}

// Under a third showing and too thin to tap reliably.
static BOOL IsSliver(CGRect frame, CGRect vis) {
  CGFloat area = frame.size.width * frame.size.height;
  CGFloat frac = area > 0 ? (vis.size.width * vis.size.height) / area : 0;
  return frac < kSFSliverFraction && (vis.size.height < kSFSliverSide || vis.size.width < kSFSliverSide);
}

// Which way to scroll to bring `frame` into the scroll area.
static NSString *DirectionTo(CGRect frame, SFScrollArea *area) {
  CGRect sv = area.visibleFrame;
  CGFloat dx = (CGRectGetMidX(frame) - CGRectGetMidX(sv)) / MAX(sv.size.width, 1);
  CGFloat dy = (CGRectGetMidY(frame) - CGRectGetMidY(sv)) / MAX(sv.size.height, 1);
  return fabs(dx) > fabs(dy) ? (dx > 0 ? @"right" : @"left") : (dy > 0 ? @"down" : @"up");
}

static void DebugReject(SFSnapshot *s, id obj, UIView *owner, CGRect frame, CGRect vis) {
  UIView *hit = CGRectIsEmpty(vis) ? nil : SFHitView(SFMid(vis), s.windows);
  [s.debug addObject:@{@"label": [obj accessibilityLabel] ?: @"", @"frame": SFRectJSON(frame), @"vis": SFRectJSON(vis),
    @"owner": NSStringFromClass(owner.class), @"hit": hit ? NSStringFromClass(hit.class) : @"-",
    @"hitInOwner": @(hit && [hit isDescendantOfView:owner]), @"ownerInHit": @(hit && [owner isDescendantOfView:hit])}];
}

// One candidate: a UIView, or a non-view accessibility element owned by `owner` (SwiftUI).
static void Consider(SFSnapshot *s, id obj, UIView *owner, CGRect frame, CGRect vis, SFScrollArea *scroll, NSString *axContext) {
  BOOL isView = [obj isKindOfClass:UIView.class];
  UIView *v = isView ? obj : nil;
  NSString *label = [obj accessibilityLabel] ?: @"";
  SFProbe probe = Probe(obj, owner, vis, s.windows);
  if (s.debug && !probe.reachable && !isView) DebugReject(s, obj, owner, frame, vis);
  BOOL shown = probe.reachable && !IsSliver(frame, vis);
  SFRole role = SFRoleOf(obj);
  // Chart data points and progress indicators are information, not controls: read them as "label: value".
  BOOL readout = SFIsChartPoint(obj) || SFIsStatus(obj);
  if (readout && [[obj accessibilityValue] length]) label = [NSString stringWithFormat:@"%@: %@", label, [obj accessibilityValue]];

  // Text and headers (UILabel, SwiftUI Text) are page text and context sources, not things to act on.
  if (role == SFRoleText || role == SFRoleHeader || readout) {
    if (label.length && (shown || scroll)) {  // covered text in a list still serves as context
      SFText *t = [SFText new];
      t.label = label; t.frame = SFRound(frame); t.visibleFrame = vis; t.scrollRef = scroll.ref;
      t.shown = shown; t.header = role == SFRoleHeader;
      id owner = isView ? nil : SFOwningButton(obj);
      if (owner) { t.owner = owner; t.ownerLabel = [owner accessibilityLabel] ?: @""; }
      if (!shown && [scroll.more containsObject:DirectionTo(frame, scroll)]) t.direction = DirectionTo(frame, scroll);
      [s.texts addObject:t];
    }
    return;
  }

  SFNode *n = [SFNode new];
  n.role = role; n.label = label; n.frame = SFRound(frame); n.scrollRef = scroll.ref; n.source = obj;
  n.identifier = isView ? SFNearestId(v) : ([obj respondsToSelector:@selector(accessibilityIdentifier)] ? ([obj accessibilityIdentifier] ?: @"") : @"");
  if (shown) {
    n.tap = probe.tap;
    n.clipped = !CGRectEqualToRect(CGRectIntegral(vis), CGRectIntegral(frame));
    NSString *val = [obj accessibilityValue];
    // Switches (UISwitch, SwiftUI Toggle) report "1"/"0"; spell it out so a model can tell the state.
    BOOL toggle = NO;
    if (@available(iOS 17.0, *)) toggle = ([obj accessibilityTraits] & UIAccessibilityTraitToggleButton) != 0;
    if ([obj isKindOfClass:UISwitch.class] || (toggle && ([val isEqualToString:@"1"] || [val isEqualToString:@"0"]))) {
      n.role = SFRoleSwitch; val = [val isEqualToString:@"1"] ? @"on" : @"off";
    }
    n.value = val;
    // Context only where it disambiguates (list/carousel items, nested buttons); tabs and headers get none.
    BOOL nested = NO;
    for (UIView *p = v.superview; p && !nested; p = p.superview) nested = p.isAccessibilityElement;
    n.context = isView ? ((scroll || nested) ? SFContextFor(v, label, NO) : @"") : (scroll ? axContext : @"");
    n.selected = ([obj accessibilityTraits] & UIAccessibilityTraitSelected) != 0;
    [s.nodes addObject:n];
  } else if ([scroll.more containsObject:DirectionTo(frame, scroll)]) {
    // Scrolling that way can bring it into view (also from under a tab bar). Otherwise it's covered or truncated: dropped.
    n.direction = DirectionTo(frame, scroll);
    n.context = isView ? SFContextFor(v, label, YES) : axContext;
    if (s.hidden.count < kSFMaxHiddenCollected) [s.hidden addObject:n];
  } else if (!probe.reachable && !IsSliver(frame, vis) && vis.size.width >= kSFMinProbeSide && vis.size.height >= kSFMinProbeSide) {
    // On screen but under something (a toast over a just-tapped button): not tappable, but its state is evidence.
    n.coveredBy = Describe(SFHitView(SFMid(vis), s.windows));
    n.value = [obj accessibilityValue];
    [s.covered addObject:n];
  }
}

static void WalkAX(SFSnapshot *s, id el, UIView *owner, CGRect clip, SFScrollArea *scroll, int depth, NSArray *siblings) {
  if (depth > kSFMaxAXDepth || ([el respondsToSelector:@selector(accessibilityElementsHidden)] && [el accessibilityElementsHidden])) return;
  if ([el isAccessibilityElement]) {
    CGRect frame = [el accessibilityFrame];  // already in screen coordinates
    Consider(s, el, owner, frame, CGRectIntersection(frame, clip), scroll, siblings.count < kSFMaxSiblingsForContext ? SFSiblingText(siblings, el) : @"");
  }
  NSArray *kids = SFAXChildren(el);
  // A non-element container with several children (e.g. one post: header, text, buttons) may be an "open item" row.
  if (![el isAccessibilityElement] && kids.count >= 2) {
    CGRect f = [el respondsToSelector:@selector(accessibilityFrame)] ? [el accessibilityFrame] : CGRectNull;
    if (s.debug) [s.debug addObject:@{@"container": NSStringFromClass([el class]), @"kids": @(kids.count), @"frame": SFRectJSON(f), @"inScroll": @(scroll != nil)}];
    CGRect gf = CGRectIntersection(f, clip), screen = SFAppBounds();
    if (scroll && !CGRectIsNull(f) && !CGRectIsEmpty(gf) && gf.size.height >= kSFGroupMinHeight && gf.size.height < screen.size.height * kSFGroupMaxScreenHeight && gf.size.width >= screen.size.width * kSFGroupMinScreenWidth) {
      SFRowCandidate *rc = [SFRowCandidate new];
      rc.frame = gf; rc.scrollRef = scroll.ref; rc.axGroup = YES;
      [s.rowCandidates addObject:rc];
    }
  }
  for (id k in kids) if (![k isKindOfClass:UIView.class]) WalkAX(s, k, owner, clip, scroll, depth + 1, kids);
}

// A scroll view the user can reach (not under a sheet, not text-input internals) becomes a scroll area.
static SFScrollArea *ScrollAreaFor(SFSnapshot *s, UIView *v, CGRect vis) {
  if (![v isKindOfClass:UIScrollView.class] || [v conformsToProtocol:@protocol(UITextInput)] || CGRectIsEmpty(vis)) return nil;
  UIView *centerHit = SFHitView(SFMid(vis), s.windows);
  if (!centerHit || ![centerHit isDescendantOfView:v]) return nil;
  UIScrollView *sv = (UIScrollView *)v;
  CGPoint o = sv.contentOffset; CGSize cs = sv.contentSize, b = sv.bounds.size; UIEdgeInsets in = sv.adjustedContentInset;
  NSMutableArray *more = [NSMutableArray array];
  if (o.y > -in.top + 1) [more addObject:@"up"];
  if (o.y + b.height < cs.height + in.bottom - 1) [more addObject:@"down"];
  if (o.x > -in.left + 1) [more addObject:@"left"];
  if (o.x + b.width < cs.width + in.right - 1) [more addObject:@"right"];
  SFScrollArea *a = [SFScrollArea new];
  a.ref = [NSString stringWithFormat:@"S%lu", (unsigned long)s.scrolls.count];
  a.identifier = SFNearestId(v); a.view = v; a.visibleFrame = vis; a.offset = o; a.contentSize = cs; a.more = more; a.paging = sv.isPagingEnabled;
  [s.scrolls addObject:a];
  return a;
}

// Animations that never end (caret blink, shimmer, spinners) don't mean the screen is still changing.
static BOOL IsTransitioning(CALayer *layer) {
  for (NSString *key in layer.animationKeys) {
    CAAnimation *a = [layer animationForKey:key];
    if (a.repeatCount < 1e6 && a.repeatDuration < 1e6) return YES;
  }
  return NO;
}

static void Walk(SFSnapshot *s, UIView *v, CGRect clip, SFScrollArea *scroll) {
  // A layer not yet committed has no presentation layer; that's not "transparent".
  CALayer *shown = v.layer.presentationLayer;
  if (v.hidden || v.alpha < kSFInvisibleAlpha || (shown && shown.opacity < kSFInvisibleAlpha)) return;
  CGRect frame = SFFrameOnScreen(v);
  CGRect vis = CGRectIntersection(frame, clip);
  BOOL onScreen = !CGRectIsEmpty(vis);
  if (v.isFirstResponder) s.focused = v;
  // Core Animation moves layers while views already report final frames; flag it so callers keep waiting.
  if (onScreen && IsTransitioning(v.layer)) s.animating = YES;
  if (onScreen && SFIsLoadingIndicator(v)) s.loading = YES;

  // Content drawn by another process (Safari sheets, web sign-in, some system UI) is opaque to us and to axe.
  // _UIRemoteView (older) and _UISceneHostingView (share sheet, iOS 17+) host another process's UI.
  static Class remoteView, sceneHost;
  if (!remoteView) { remoteView = NSClassFromString(@"_UIRemoteView"); sceneHost = NSClassFromString(@"_UISceneHostingView"); }
  BOOL remote = (remoteView && [v isKindOfClass:remoteView]) || (sceneHost && [v isKindOfClass:sceneHost]);
  if (remote && onScreen) {
    NSString *host = SFNearestId(v);
    for (UIView *p = v.superview; p && !host.length; p = p.superview) if (![NSStringFromClass(p.class) hasPrefix:@"_"]) host = NSStringFromClass(p.class);
    // A host can span the screen while only part of it (a sheet) takes touches: any of 5 points will do.
    BOOL reachable = NO;
    for (int i = 1; i <= 5 && !reachable; i++) {
      CGPoint p = CGPointMake(CGRectGetMidX(vis), CGRectGetMinY(vis) + vis.size.height * i / 6);
      UIView *hit = SFHitView(p, s.windows);
      reachable = hit && [hit isDescendantOfView:v];
    }
    if (reachable) [s.remote addObject:@{@"frame": SFRectJSON(vis), @"host": host}];
  }
  if (([v isKindOfClass:UICollectionViewCell.class] || [v isKindOfClass:UITableViewCell.class]) && vis.size.height >= kSFCellMinHeight && scroll) {
    SFRowCandidate *rc = [SFRowCandidate new];
    rc.frame = vis; rc.scrollRef = scroll.ref;
    [s.rowCandidates addObject:rc];
  }
  SFScrollArea *mine = ScrollAreaFor(s, v, vis) ?: scroll;
  if (v.clipsToBounds || [v isKindOfClass:UIScrollView.class]) clip = vis;

  // Visible RN text becomes page text whether or not it's an accessibility element (inside a button it isn't).
  // No scroll ref: RN controls get context from the view tree (SFContextFor), not from the nearest text.
  if (SFIsRNText(v)) {
    if (onScreen && vis.size.height >= 4 && v.accessibilityLabel.length && SFHitBelongsTo(SFHitView(SFMid(vis), s.windows), v)) {
      SFText *t = [SFText new];
      t.label = v.accessibilityLabel; t.frame = SFRound(frame); t.visibleFrame = vis; t.shown = YES; t.reactNative = YES;
      [s.texts addObject:t];
    }
  } else if (v.isAccessibilityElement || [v conformsToProtocol:@protocol(UITextInput)]) Consider(s, v, v, frame, vis, mine, nil);
  // SwiftUI (and some UIKit containers) describe content as accessibility elements that are not views.
  // RN views are fully covered by the view walk (text included); skipping their AX children keeps reads fast.
  NSArray *axKids = [NSStringFromClass(v.class) hasPrefix:@"RCT"] ? @[] : SFAXChildren(v);
  for (id el in axKids) if (![el isKindOfClass:UIView.class]) WalkAX(s, el, v, clip, mine, 0, axKids);
  for (UIView *sub in v.subviews) Walk(s, sub, clip, mine);
}

SFSnapshot *SFCollect(BOOL debug) {
  SFSnapshot *s = [SFSnapshot new];
  s.windows = SFWindows();
  if (debug) s.debug = [NSMutableArray array];
  CGRect kb = SFKeyboardFrame();
  for (UIWindow *w in s.windows) {
    CGRect clip = [w convertRect:w.bounds toWindow:nil];
    // The keyboard is another process's window; whatever it covers can't be tapped.
    if (!CGRectIsEmpty(CGRectIntersection(kb, clip))) clip.size.height = MAX(0, CGRectGetMinY(kb) - clip.origin.y);
    Walk(s, w, clip, nil);
  }
  return s;
}
