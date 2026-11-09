// Stage 2: passes over the whole snapshot, in order. Each one is a rule about several elements at once.
#import "SFModel.h"

static BOOL SameScroll(NSString *a, NSString *b) { return [(a ?: @"") isEqualToString:(b ?: @"")]; }

// A spot inside `area` on no listed element, nearest to `aim`, where a tap lands inside `within` (the row's list,
// not a tab bar or nav bar over it; nil = anywhere). NO if there is none.
static BOOL FreeSpot(CGRect area, NSArray<NSValue *> *avoid, int cols, int rows, CGPoint aim, NSArray<UIWindow *> *windows, UIView *within, CGPoint *out) {
  double bestD = 1e9;
  for (int gx = 1; gx < cols; gx++) for (int gy = 1; gy < rows; gy++) {
    CGPoint p = CGPointMake(CGRectGetMinX(area) + area.size.width * gx / cols, CGRectGetMinY(area) + area.size.height * gy / rows);
    BOOL onElement = NO;
    for (NSValue *ev in avoid) if (CGRectContainsPoint(CGRectInset(ev.CGRectValue, -kSFFreeSpotPadding, -kSFFreeSpotPadding), p)) { onElement = YES; break; }
    UIView *hit = onElement ? nil : SFHitView(p, windows);
    if (!hit || (within && ![hit isDescendantOfView:within])) continue;
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
    if (n.context.length || !n.scrollRef) continue;
    CGPoint m = SFMid(n.frame);
    double best = kSFNearestTextRadius; NSString *ctx = nil;
    for (SFText *t in s.texts) {
      if (![t.scrollRef isEqualToString:n.scrollRef]) continue;
      double d = hypot(SFMid(t.frame).x - m.x, SFMid(t.frame).y - m.y);
      if (d < best) { best = d; ctx = t.label; }
    }
    if (ctx) n.context = ctx.length > kSFContextMaxChars ? [ctx substringToIndex:kSFContextMaxChars] : ctx;
  }
}

// SwiftUI controls appear both as a view and as an accessibility object: merge same-place, same-size entries,
// keeping the richer one (inputs over text, labelled over unlabelled, with an id over without).
static int Richness(SFNode *n) {
  return (n.role == SFRoleInput ? 8 : 0) + (n.label.length ? 2 : 0) + (n.identifier.length ? 1 : 0) + (n.value.length ? 1 : 0);
}
static BOOL FromWeb(SFNode *n) { return [n.source isKindOfClass:SFWebTarget.class]; }

static void MergeSamePlaceIn(NSMutableArray<SFNode *> *nodes) {
  NSMutableArray<SFNode *> *merged = [NSMutableArray array];
  for (SFNode *n in nodes) {
    if (FromWeb(n)) { [merged addObject:n]; continue; }  // the page says exactly what its links are
    NSInteger dup = NSNotFound;
    for (NSUInteger j = 0; j < merged.count && dup == NSNotFound; j++) {
      CGRect f = n.frame, g = merged[j].frame;
      if (fabs(CGRectGetMidX(f) - CGRectGetMidX(g)) < kSFSamePlaceCenter && fabs(CGRectGetMidY(f) - CGRectGetMidY(g)) < kSFSamePlaceCenter &&
          fabs(f.size.width - g.size.width) < kSFSamePlaceSize && fabs(f.size.height - g.size.height) < kSFSamePlaceSize) dup = j;
    }
    if (dup == NSNotFound) [merged addObject:n];
    else if (Richness(n) > Richness(merged[dup])) merged[dup] = n;
  }
  [nodes setArray:merged];
}
static void MergeSamePlace(SFSnapshot *s) {
  MergeSamePlaceIn(s.nodes);
  MergeSamePlaceIn(s.hidden);  // scrolled-away duplicates too, or counts and previews double up
}

// Context that the label already says ("Games" for a link "Games\nOn English Wikipedia") adds nothing.
static void DropRedundantContext(SFSnapshot *s) {
  NSMutableArray<SFNode *> *all = [NSMutableArray arrayWithArray:s.nodes];
  [all addObjectsFromArray:s.hidden];
  for (SFNode *n in all) if (n.context.length && [n.label containsString:n.context]) n.context = nil;
}

// A gesture view that holds several controls is a pager or swipeable screen (RN tabs), not a card: drop it.
static void DropGestureContainers(SFSnapshot *s) {
  NSMutableArray *drop = [NSMutableArray array];
  for (SFNode *g in s.nodes) {
    if (g.role != SFRoleGesture) continue;
    int inside = 0;
    for (SFNode *o in s.nodes) if (o != g && CGRectContainsPoint(g.frame, SFMid(o.frame))) inside++;
    if (inside >= 2) [drop addObject:g];
  }
  [s.nodes removeObjectsInArray:drop];
}

// --- "Open item" rows: something that opens when tapped (a post, a list cell) but isn't one clean element. ---

// Label from what's inside: visible text first, then each inner element's label and context, at most 3 phrases.
static NSString *RowLabel(NSArray<NSString *> *texts, NSArray<SFNode *> *inner) {
  NSMutableArray *words = [NSMutableArray array];
  for (NSString *t in texts) if (words.count < kSFRowLabelPhrases) AddWord(words, t);  // not counters ("4", "70")
  for (SFNode *n in inner) if (words.count < kSFRowLabelPhrases) { AddWord(words, n.label ?: @""); AddWord(words, n.context ?: @""); }
  return Clip([words componentsJoinedByString:@" · "], kSFRowLabelChars);
}

// Where a person taps to open it: a free spot (on no inner element) nearest `aim`.
static BOOL RowTap(SFSnapshot *s, CGRect area, NSString *scrollRef, NSArray<SFNode *> *inner, CGPoint aim, CGPoint *out) {
  NSMutableArray *avoid = [NSMutableArray array];
  for (SFNode *n in inner) [avoid addObject:[NSValue valueWithCGRect:n.frame]];
  return FreeSpot(area, avoid, kSFFreeSpotColumns, kSFFreeSpotRows, aim, s.windows, scrollRef ? [s scrollWithRef:scrollRef].view : nil, out);
}

// A list cell or AX group that opens something (e.g. a SwiftUI post) has no element of its own: add one.
static void RowsFromCells(SFSnapshot *s) {
  for (SFRowCandidate *cell in s.rowCandidates) {
    CGRect cf = cell.frame;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableArray<SFNode *> *inner = [NSMutableArray array];
    for (SFText *t in s.texts)
      if (t.shown && !t.header && CGRectContainsPoint(cf, SFMid(t.visibleFrame))) [texts addObject:t.label];
    for (SFNode *n in s.nodes)  // same scroll area: not e.g. a tab bar over the cell's edge
      if (CGRectContainsPoint(cf, SFMid(n.frame)) && [n.scrollRef isEqualToString:cell.scrollRef]) [inner addObject:n];
    // Not a row: one control (it already is the row), a carousel host, or a duplicate of a row already added.
    // An AX group needs several elements to be an item; a real list cell may hold only text.
    if (inner.count == 1 || (cell.axGroup && inner.count < 2)) continue;
    BOOL redundant = NO;
    for (SFNode *n in inner) if (n.frame.size.width * n.frame.size.height >= kSFOneControlFraction * cf.size.width * cf.size.height) redundant = YES;
    for (SFScrollArea *a in s.scrolls)
      if (![a.ref isEqualToString:cell.scrollRef] && CGRectContainsPoint(cf, SFMid(SFRound(a.visibleFrame)))) redundant = YES;
    for (SFNode *n in s.nodes) if (n.role == SFRoleRow) {
      CGRect ov = CGRectIntersection(n.frame, cf);
      if (!CGRectIsEmpty(ov) && ov.size.width * ov.size.height > kSFDuplicateRowOverlap * MIN(n.frame.size.width * n.frame.size.height, cf.size.width * cf.size.height)) redundant = YES;
    }
    NSString *label = RowLabel(texts, inner);
    CGPoint tap;
    if (redundant || !label.length || !RowTap(s, cf, cell.scrollRef, inner, SFMid(cf), &tap)) continue;
    SFNode *row = [SFNode new];
    row.role = SFRoleRow; row.identifier = @""; row.label = label; row.frame = SFRound(cf); row.tap = tap; row.scrollRef = cell.scrollRef;
    // The button the cell's controls sit in (a SwiftUI post) is what opening the row means: activate it on tap.
    for (SFNode *n in inner) if (n.source && (row.source = SFOwningButton(n.source))) break;
    [s.nodes addObject:row];
  }
}

// An element whose area holds other elements is a container (e.g. a whole post as one button). Its own
// activation point often sits on an inner control (the avatar): label it from its contents, tap a free spot.
static void ContainersToRows(SFSnapshot *s) {
  NSArray<SFNode *> *nodes = [s.nodes copy];
  NSMutableArray<void (^)(void)> *changes = [NSMutableArray array];  // applied after all decisions, so they don't feed each other
  for (SFNode *n in nodes) {
    if (n.role == SFRoleRow || n.role == SFRoleInput || FromWeb(n)) continue;  // a link wrapping lines isn't a container
    NSMutableArray<SFNode *> *inner = [NSMutableArray array];
    for (SFNode *o in nodes)  // same scroll area: not e.g. a tab bar
      if (o != n && CGRectContainsRect(CGRectInset(n.frame, -1, -1), o.frame) && !CGRectEqualToRect(o.frame, n.frame) && SameScroll(o.scrollRef, n.scrollRef))
        [inner addObject:o];
    if (inner.count < 2) continue;
    // A container element is typically a whole post as one button: aim just below its top inner element (the
    // header), where its text is. The middle tends to be media, which opens a viewer or nothing.
    CGRect top = inner.firstObject.frame;
    for (SFNode *o in inner) if (CGRectGetMinY(o.frame) < CGRectGetMinY(top)) top = o.frame;
    CGPoint tap;
    if (!RowTap(s, n.frame, n.scrollRef, inner, CGPointMake(CGRectGetMidX(top), CGRectGetMaxY(top) + kSFBelowHeader), &tap)) continue;
    NSString *label = n.label.length ? n.label : RowLabel(@[], inner);
    [changes addObject:^{ n.role = SFRoleRow; n.label = label; n.tap = tap; }];
  }
  for (void (^apply)(void) in changes) apply();
}

// SwiftUI views with only a tap gesture have no element; their visible text is the best handle.
// Not RN: tappable RN text is exposed as a button already.
static void TextItems(SFSnapshot *s) {
  for (SFText *t in s.texts) {
    if (!t.shown || t.header || t.noTapTarget) continue;
    CGPoint mid = SFMid(t.visibleFrame); BOOL covered = NO;
    for (SFNode *n in s.nodes) if (n.role != SFRoleRow && CGRectContainsPoint(n.frame, mid)) { covered = YES; break; }
    if (covered || s.textItems.count >= kSFMaxTextItems) continue;
    NSMutableDictionary *item = [@{@"label": t.label, @"tap": SFPointJSON(mid)} mutableCopy];
    if (t.owner) item[@"partOf"] = t.ownerLabel ?: @"";  // known tappable: part of this button
    [s.textItems addObject:item];
  }
}

// What each scroll area would reveal, so the model can scroll toward something it can't see yet.
// Also counts and trims the scrolled-away elements per area.
static void ScrollPreviews(SFSnapshot *s) {
  NSMutableArray<SFNode *> *kept = [NSMutableArray array];
  for (SFScrollArea *a in s.scrolls) {
    NSArray *mine = [s.hidden filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"scrollRef == %@", a.ref]];
    a.hiddenCount = mine.count;
    [kept addObjectsFromArray:[mine subarrayWithRange:NSMakeRange(0, MIN(mine.count, kSFMaxHidden))]];
  }
  [s.hidden setArray:kept];
  for (SFScrollArea *a in s.scrolls) {
    NSMutableArray *ahead = [NSMutableArray array];
    for (SFNode *h in s.hidden) if ([h.scrollRef isEqualToString:a.ref] && ahead.count < kSFMaxAhead)
      [ahead addObject:@{@"dir": h.direction, @"what": [@[h.label ?: @"", h.context ?: @""] componentsJoinedByString:@" — "]}];
    for (SFText *t in s.texts) {  // text further on, unless a control already listed says it
      if (!t.direction || ![t.scrollRef isEqualToString:a.ref] || ahead.count >= kSFMaxAhead) continue;
      BOOL said = NO;
      for (SFNode *h in s.hidden) if ([h.label containsString:t.label] || [h.context containsString:t.label]) { said = YES; break; }
      if (!said) [ahead addObject:@{@"dir": t.direction, @"what": t.label}];
    }
    a.ahead = ahead;
  }
}

// A pushed screen often hides the tab bar; say where its tabs went, or "Saved tab" looks unreachable.
static void HiddenTabBarHint(SFSnapshot *s) {
  for (UIWindow *w in s.windows) {
    NSMutableArray *queue = [NSMutableArray arrayWithObjects:w.rootViewController, nil];
    for (NSUInteger i = 0; i < queue.count && i < kSFMaxViewControllers; i++) {
      UIViewController *vc = queue[i];
      [queue addObjectsFromArray:vc.childViewControllers];
      if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
      if (![vc isKindOfClass:UITabBarController.class]) continue;
      UITabBar *bar = ((UITabBarController *)vc).tabBar;
      CGRect f = bar.window ? SFFrameOnScreen(bar) : CGRectNull;
      BOOL hidden = !bar.window || bar.hidden || bar.alpha <= kSFInvisibleAlpha || !CGRectIntersectsRect(f, SFAppBounds());
      // Not UITabBarController.isTabBarHidden (iOS 18): it stays NO when a pushed screen hides the bar.
      if (!hidden) continue;
      NSMutableArray *names = [NSMutableArray array];
      for (UITabBarItem *it in bar.items) if (it.title.length) [names addObject:it.title];
      if (names.count) [s.notes addObject:[NSString stringWithFormat:@"(Tab bar with %@ is hidden on this screen; go Back to reach it.)", [names componentsJoinedByString:@", "]]];
      break;
    }
  }
}

// A bar control often shows up as its view, its icon and a row: same id + overlapping = one entry. Only outside
// lists: there an id is often inherited by a card's own buttons. A field and a control inside it (Clear) stay apart.
static int Preference(SFNode *n) { return (n.role == SFRoleRow ? 0 : 4) + (n.role == SFRoleButton ? 2 : 0) + (n.label.length ? 1 : 0); }
static void MergeSameId(SFSnapshot *s) {
  NSMutableArray<SFNode *> *uniq = [NSMutableArray array];
  for (SFNode *n in s.nodes) {
    NSUInteger dup = NSNotFound;
    if (n.identifier.length) for (NSUInteger j = 0; j < uniq.count && dup == NSNotFound; j++)
      if (!n.scrollRef && !uniq[j].scrollRef && [uniq[j].identifier isEqualToString:n.identifier] && CGRectIntersectsRect(n.frame, uniq[j].frame) &&
          (n.role == SFRoleInput) == (uniq[j].role == SFRoleInput)) dup = j;
    if (dup == NSNotFound) [uniq addObject:n];
    else if (Preference(n) > Preference(uniq[dup])) uniq[dup] = n;
  }
  [s.nodes setArray:uniq];
}

// Controls a toast or banner lies on top of: say what they show (e.g. "Saved"), since the model can't tap them.
static void CoveredNote(SFSnapshot *s) {
  if (!s.covered.count || s.covered.count > kSFMaxCoveredReported) return;
  NSMutableDictionary<NSString *, NSMutableArray *> *byCover = [NSMutableDictionary dictionary];
  for (SFNode *n in s.covered) {
    if (!n.label.length) continue;
    NSString *what = n.value.length ? [NSString stringWithFormat:@"%@ (%@)", n.label, n.value] : n.label;
    [byCover[n.coveredBy] ?: (byCover[n.coveredBy] = [NSMutableArray array]) addObject:what];
  }
  for (NSString *cover in byCover)
    [s.notes addObject:[NSString stringWithFormat:@"(Under \"%@\", not tappable now: %@)", cover, [byCover[cover] componentsJoinedByString:@"; "]]];
}

// Order matters; each line says what it relies on.
void SFRefine(SFSnapshot *s) {
  NearestTextContext(s);          // first: hidden nodes need context before ScrollPreviews
  MergeSamePlace(s);              // before rows: duplicates would count as two inner elements
  DropGestureContainers(s);       // before rows: a pager would become a giant row
  RowsFromCells(s);               // adds rows; its duplicate check sees rows added earlier in the loop
  ContainersToRows(s);            // sees cell rows as inner elements
  TextItems(s);                   // after both row passes: text under a non-row element is covered
  HiddenTabBarHint(s);
  MergeSameId(s);                 // collapses a control with the row made from it
  DropRedundantContext(s);        // after every pass that sets context
  ScrollPreviews(s);              // summarises the final scrolled-away elements
  CoveredNote(s);
}
