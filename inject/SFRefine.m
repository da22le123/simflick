// Stage 2: passes over the whole snapshot, in order. Each one is a rule about several elements at once.
#import "SFModel.h"

static BOOL SameScroll(NSString *a, NSString *b) { return [(a ?: @"") isEqualToString:(b ?: @"")]; }

// A spot inside `area` on no listed element and reachable by a tap, nearest to `aim`; NO if there is none.
static BOOL FreeSpot(CGRect area, NSArray<NSValue *> *avoid, int cols, int rows, CGPoint aim, NSArray<UIWindow *> *windows, CGPoint *out) {
  double bestD = 1e9;
  for (int gx = 1; gx < cols; gx++) for (int gy = 1; gy < rows; gy++) {
    CGPoint p = CGPointMake(CGRectGetMinX(area) + area.size.width * gx / cols, CGRectGetMinY(area) + area.size.height * gy / rows);
    BOOL onElement = NO;
    for (NSValue *ev in avoid) if (CGRectContainsPoint(CGRectInset(ev.CGRectValue, -4, -4), p)) { onElement = YES; break; }
    if (onElement || !SFHitView(p, windows)) continue;
    double d = hypot(p.x - aim.x, p.y - aim.y);
    if (d < bestD) { bestD = d; *out = p; }
  }
  return bestD < 1e9;
}

static NSString *Clip(NSString *s, NSUInteger max) { return s.length > max ? [s substringToIndex:max] : s; }

static void AddWord(NSMutableArray *words, NSString *w) {
  if (SFHasWords(w) && ![words containsObject:w]) [words addObject:w];
}

// Flat SwiftUI stacks give no grouping: label context-less items with the nearest text in the same scroll area.
static void NearestTextContext(SFSnapshot *s) {
  NSMutableArray<SFNode *> *all = [NSMutableArray arrayWithArray:s.nodes];
  [all addObjectsFromArray:s.hidden];
  for (SFNode *n in all) {
    if (n.role == SFRoleText || n.context.length || !n.scrollRef) continue;
    CGPoint m = SFMid(n.frame);
    double best = 100; NSString *ctx = nil;
    for (SFText *t in s.texts) {
      if (!t.fromAX || ![t.scrollRef isEqualToString:n.scrollRef]) continue;
      double d = hypot(SFMid(t.frame).x - m.x, SFMid(t.frame).y - m.y);
      if (d < best) { best = d; ctx = t.label; }
    }
    if (ctx) n.context = ctx;
  }
}

// SwiftUI controls appear both as a view and as an accessibility object: merge same-place, same-size entries,
// keeping the richer one (inputs over text, labelled over unlabelled, with an id over without).
static int Richness(SFNode *n) {
  return (n.role == SFRoleInput ? 8 : 0) + (n.role == SFRoleText ? -4 : 0) + (n.label.length ? 2 : 0) + (n.identifier.length ? 1 : 0) + (n.value.length ? 1 : 0);
}
static void MergeSamePlace(SFSnapshot *s) {
  NSMutableArray<SFNode *> *merged = [NSMutableArray array];
  for (SFNode *n in s.nodes) {
    NSInteger dup = NSNotFound;
    for (NSUInteger j = 0; j < merged.count && dup == NSNotFound; j++) {
      CGRect f = n.frame, g = merged[j].frame;
      if (fabs(CGRectGetMidX(f) - CGRectGetMidX(g)) < 6 && fabs(CGRectGetMidY(f) - CGRectGetMidY(g)) < 6 &&
          fabs(f.size.width - g.size.width) < 12 && fabs(f.size.height - g.size.height) < 12) dup = j;
    }
    if (dup == NSNotFound) [merged addObject:n];
    else if (Richness(n) > Richness(merged[dup])) merged[dup] = n;
  }
  [s.nodes setArray:merged];
}

// A caption inside a control with the same label is that control's text, not a second element.
static void DropCaptionsInsideControls(SFSnapshot *s) {
  NSMutableArray<SFNode *> *kept = [NSMutableArray array];
  for (SFNode *n in s.nodes) {
    BOOL inside = NO;
    if (n.role == SFRoleText) for (SFNode *o in s.nodes)
      if (o != n && o.role != SFRoleText && [o.label isEqualToString:n.label] && CGRectContainsPoint(CGRectInset(o.frame, -2, -2), SFMid(n.frame))) inside = YES;
    if (!inside) [kept addObject:n];
  }
  [s.nodes setArray:kept];
}

// A list cell that opens something when tapped (e.g. a post) has no element of its own in SwiftUI;
// add one, tapped on a free spot (away from the buttons inside it), as a person would.
static void RowsFromCells(SFSnapshot *s) {
  for (SFRowCandidate *cell in s.rowCandidates) {
    CGRect cf = cell.frame;
    NSMutableArray *words = [NSMutableArray array], *inside = [NSMutableArray array];
    for (SFText *t in s.texts)
      if (t.fromAX && t.shown && !t.header && CGRectContainsPoint(cf, SFMid(t.visibleFrame))) [words addObject:t.label];
    for (SFNode *n in s.nodes) {
      if (!CGRectContainsPoint(cf, SFMid(n.frame)) || ![n.scrollRef isEqualToString:cell.scrollRef]) continue;  // e.g. a tab bar over the cell's edge
      [inside addObject:[NSValue valueWithCGRect:n.frame]];
      if (words.count < 3) { AddWord(words, n.label ?: @""); AddWord(words, n.context ?: @""); }
    }
    if (!words.count) continue;
    if (cell.axGroup && inside.count < 2) continue;
    // Redundant rows: a cell that is basically one control, or that hosts its own scroll area (a carousel).
    BOOL oneControl = NO, hostsScroll = NO, dupRow = NO;
    for (NSValue *ev in inside)
      if (ev.CGRectValue.size.width * ev.CGRectValue.size.height >= 0.7 * cf.size.width * cf.size.height) oneControl = YES;
    for (SFScrollArea *a in s.scrolls)
      if (![a.ref isEqualToString:cell.scrollRef] && CGRectContainsPoint(cf, SFMid(SFRound(a.visibleFrame)))) hostsScroll = YES;
    if (oneControl || hostsScroll || inside.count == 1) continue;
    for (SFNode *n in s.nodes) if (n.role == SFRoleRow) {
      CGRect ov = CGRectIntersection(n.frame, cf);
      if (!CGRectIsEmpty(ov) && ov.size.width * ov.size.height > 0.8 * MIN(n.frame.size.width * n.frame.size.height, cf.size.width * cf.size.height)) dupRow = YES;
    }
    if (dupRow) continue;
    CGPoint tap;
    if (!FreeSpot(cf, inside, 8, 6, SFMid(cf), s.windows, &tap)) continue;
    SFNode *row = [SFNode new];
    row.role = SFRoleRow; row.identifier = @""; row.label = Clip([words componentsJoinedByString:@" · "], 160);
    row.frame = SFRound(cf); row.tap = tap; row.scrollRef = cell.scrollRef;
    [s.nodes addObject:row];
  }
}

// An element whose area contains other elements is a container (e.g. a whole post as one button). Its own
// activation point often sits on an inner control (the avatar), so: label it from its contents, tap a free spot.
static void ContainersToRows(SFSnapshot *s) {
  NSArray<SFNode *> *nodes = [s.nodes copy];
  NSMutableArray<void (^)(void)> *changes = [NSMutableArray array];  // applied after all decisions, so they don't feed each other
  for (SFNode *n in nodes) {
    if (n.role == SFRoleRow || n.role == SFRoleInput) continue;
    CGRect cf = n.frame;
    NSMutableArray *inside = [NSMutableArray array], *words = [NSMutableArray array];
    for (SFNode *o in nodes) {
      if (o == n || !CGRectContainsRect(CGRectInset(cf, -1, -1), o.frame) || CGRectEqualToRect(o.frame, cf)) continue;
      if (!SameScroll(o.scrollRef, n.scrollRef)) continue;  // not from another area (tab bar)
      [inside addObject:[NSValue valueWithCGRect:o.frame]];
      for (NSString *w in @[o.context ?: @"", o.label ?: @""]) if (words.count < 3) AddWord(words, w);
    }
    if (inside.count < 2) continue;
    // Aim just below the top inner element (a post's header), where its text is; the middle tends to be media.
    CGRect top = CGRectNull;
    for (NSValue *ev in inside) if (CGRectIsNull(top) || CGRectGetMinY(ev.CGRectValue) < CGRectGetMinY(top)) top = ev.CGRectValue;
    CGPoint tap;
    if (!FreeSpot(cf, inside, 10, 16, CGPointMake(CGRectGetMidX(top), CGRectGetMaxY(top) + 18), s.windows, &tap)) continue;
    NSString *label = n.label.length ? n.label : Clip([words componentsJoinedByString:@" · "], 160);
    [changes addObject:^{ n.role = SFRoleRow; n.label = label; n.tap = tap; }];
  }
  for (void (^apply)(void) in changes) apply();
}

// SwiftUI views with only a tap gesture have no element; their visible text is the best handle.
static void TextItems(SFSnapshot *s) {
  for (SFText *t in s.texts) {
    if (!t.fromAX || !t.shown || t.header) continue;
    CGPoint mid = SFMid(t.visibleFrame); BOOL covered = NO;
    for (SFNode *n in s.nodes) if (n.role != SFRoleRow && CGRectContainsPoint(n.frame, mid)) { covered = YES; break; }
    if (!covered && s.textItems.count < 40) [s.textItems addObject:@{@"label": t.label, @"tap": SFPointJSON(mid)}];
  }
}

// What each scroll area would reveal, so the model can scroll toward something it can't see yet.
static void ScrollPreviews(SFSnapshot *s) {
  for (SFScrollArea *a in s.scrolls) {
    NSMutableArray *ahead = [NSMutableArray array];
    for (SFNode *h in s.hidden) if ([h.scrollRef isEqualToString:a.ref] && ahead.count < 20)
      [ahead addObject:@{@"dir": h.direction, @"what": [@[h.label ?: @"", h.context ?: @""] componentsJoinedByString:@" — "]}];
    a.ahead = ahead;
  }
}

// A pushed screen often hides the tab bar; say where its tabs went, or "Saved tab" looks unreachable.
static void HiddenTabBarHint(SFSnapshot *s) {
  for (UIWindow *w in s.windows) {
    NSMutableArray *queue = [NSMutableArray arrayWithObjects:w.rootViewController, nil];
    for (NSUInteger i = 0; i < queue.count && i < 50; i++) {
      UIViewController *vc = queue[i];
      [queue addObjectsFromArray:vc.childViewControllers];
      if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
      if (![vc isKindOfClass:UITabBarController.class]) continue;
      UITabBar *bar = ((UITabBarController *)vc).tabBar;
      CGRect f = bar.window ? [bar convertRect:bar.bounds toView:nil] : CGRectNull;
      if (bar.window && !bar.hidden && bar.alpha > 0.01 && CGRectIntersectsRect(f, UIScreen.mainScreen.bounds)) continue;
      NSMutableArray *names = [NSMutableArray array];
      for (UITabBarItem *it in bar.items) if (it.title.length) [names addObject:it.title];
      if (names.count) [s.notes addObject:[NSString stringWithFormat:@"(Tab bar with %@ is hidden on this screen; go Back to reach it.)", [names componentsJoinedByString:@", "]]];
      break;
    }
  }
}

// One control often shows up as its view, an inner AX element and a row: same id + overlapping frames = one entry.
static int Preference(SFNode *n) { return (n.role == SFRoleRow ? 0 : 4) + (n.role == SFRoleButton ? 2 : 0) + (n.label.length ? 1 : 0); }
static void MergeSameId(SFSnapshot *s) {
  NSMutableArray<SFNode *> *uniq = [NSMutableArray array];
  for (SFNode *n in s.nodes) {
    NSUInteger dup = NSNotFound;
    if (n.identifier.length) for (NSUInteger j = 0; j < uniq.count && dup == NSNotFound; j++)
      if ([uniq[j].identifier isEqualToString:n.identifier] && CGRectIntersectsRect(n.frame, uniq[j].frame)) dup = j;
    if (dup == NSNotFound) [uniq addObject:n];
    else if (Preference(n) > Preference(uniq[dup])) uniq[dup] = n;
  }
  [s.nodes setArray:uniq];
}

void SFRefine(SFSnapshot *s) {
  NearestTextContext(s);
  MergeSamePlace(s);
  DropCaptionsInsideControls(s);
  RowsFromCells(s);
  ContainersToRows(s);
  TextItems(s);
  ScrollPreviews(s);
  HiddenTabBarHint(s);
  MergeSameId(s);
}
