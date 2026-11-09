// Web views (WKWebView) draw their page in another process, so the view tree shows nothing of it. We are inside
// the app, though: ask the page itself (JavaScript) for its visible text, links and buttons, and click by script.
#import "SFModel.h"
#import <objc/message.h>

@implementation SFWebTarget
@end

static NSString *const kPageReader = @
  "(() => {"
  "  const vw = innerWidth, vh = innerHeight, out = { items: [], texts: [], vw, vh };"
  "  window.__simflick = [];"
  "  const clean = (s) => (s || '').replace(/\\s+/g, ' ').trim();"
  "  const onScreen = (r) => r.width > 1 && r.height > 1 && r.bottom > 0 && r.top < vh && r.right > 0 && r.left < vw;"
  "  const nearby = (r) => r.width > 1 && r.height > 1 && r.top < vh * 3 && r.bottom > -vh * 2;"
  // A short snippet around a link tells apart same or vague labels ("here", "[1]"); the page text carries the rest.
  "  const around = (el, own) => { const b = el.closest('p,li,td,th,figcaption,dd,h1,h2,h3,h4'); if (!b) return '';"
  "    const t = clean(b.innerText), i = t.indexOf(own); return i < 0 ? t.slice(0, 80) : t.slice(Math.max(0, i - 40), i + own.length + 40); };"
  "  for (const el of document.querySelectorAll('a[href], button, [role=button], input, textarea, select, summary')) {"
  "    const r = el.getBoundingClientRect(); if (!nearby(r)) continue;"
  "    const st = getComputedStyle(el); if (st.visibility === 'hidden' || st.display === 'none' || +st.opacity === 0) continue;"
  "    let label = clean(el.innerText || el.getAttribute('aria-label') || el.title || el.value || el.placeholder);"
  "    if (!label) { const img = el.querySelector('img[alt]'); if (img) label = clean(img.alt); }"
  "    if (!label) continue;"
  "    let shown = onScreen(r);"
  "    if (shown) { const x = Math.min(Math.max(r.left + r.width / 2, 0), vw - 1), y = Math.min(Math.max(r.top + r.height / 2, 0), vh - 1);"
  "      const hit = document.elementFromPoint(x, y); shown = !!hit && (hit === el || el.contains(hit) || hit.contains(el)); }"
  "    const kind = el.matches('input,textarea,select') ? 'input' : el.matches('a[href]') ? 'link' : 'button';"
  "    out.items.push({ k: kind, t: label.slice(0, 100), c: around(el, label), r: [r.left, r.top, r.width, r.height], s: shown, i: window.__simflick.push(el) - 1 });"
  "    if (out.items.length >= 300) break;"
  "  }"
  "  for (const el of document.querySelectorAll('h1,h2,h3,h4,p,li,figcaption,dd,td,th,caption')) {"
  "    if (el.querySelector('p,li,h1,h2,h3,h4,td')) continue;"  // innermost blocks only
  "    const r = el.getBoundingClientRect(); if (!onScreen(r)) continue;"
  "    const t = clean(el.innerText); if (!t) continue;"
  "    out.texts.push({ t: t.slice(0, 400), r: [r.left, r.top, r.width, r.height], h: /^H\\d$/.test(el.tagName) });"
  "    if (out.texts.length >= 40) break;"
  "  }"
  "  return JSON.stringify(out);"
  "})()";

// evaluateJavaScript answers asynchronously on the main thread; the reader is synchronous on that same thread.
// Spin the run loop briefly until the answer arrives (as KIF does), giving up after `timeout`.
static NSDictionary *RunInPage(UIView *web, NSString *js, NSTimeInterval timeout) {
  SEL eval = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
  if (![web respondsToSelector:eval]) return nil;
  __block NSString *json = nil;
  __block BOOL done = NO;
  void (^reply)(id, NSError *) = ^(id result, NSError *error) { if ([result isKindOfClass:NSString.class]) json = result; done = YES; };
  ((void (*)(id, SEL, NSString *, id))objc_msgSend)(web, eval, js, reply);
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!done && until.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  if (!json) return nil;
  return [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}

// Page coordinates (CSS px from the visible viewport's top-left) -> screen points.
static CGRect ToScreen(NSArray *r, CGRect viewport, CGFloat scale) {
  return CGRectMake(viewport.origin.x + [r[0] doubleValue] * scale, viewport.origin.y + [r[1] doubleValue] * scale,
                    [r[2] doubleValue] * scale, [r[3] doubleValue] * scale);
}

void SFReadWebViews(SFSnapshot *s) {
  for (UIView *web in s.webViews) {
    NSDictionary *page = RunInPage(web, kPageReader, 0.6);
    if (!page) continue;
    UIScrollView *sv = [web respondsToSelector:@selector(scrollView)] ? [web valueForKey:@"scrollView"] : nil;
    SFScrollArea *area = nil;
    for (SFScrollArea *a in s.scrolls) if (a.view == sv) area = a;
    // The page's viewport is the web view's area below whatever the content inset hides (a bar over it).
    CGRect frame = SFFrameOnScreen(web);
    UIEdgeInsets inset = sv ? sv.adjustedContentInset : UIEdgeInsetsZero;
    CGRect viewport = UIEdgeInsetsInsetRect(frame, UIEdgeInsetsMake(inset.top, inset.left, 0, 0));
    CGFloat scale = [page[@"vw"] doubleValue] > 0 ? viewport.size.width / [page[@"vw"] doubleValue] : 1;
    CGRect visible = CGRectIntersection(frame, area ? area.visibleFrame : frame);
    for (NSDictionary *it in page[@"items"]) {
      CGRect f = SFRound(ToScreen(it[@"r"], viewport, scale));
      SFNode *n = [SFNode new];
      n.role = [it[@"k"] isEqualToString:@"input"] ? SFRoleInput : [it[@"k"] isEqualToString:@"link"] ? SFRoleLink : SFRoleButton;
      n.label = it[@"t"]; n.identifier = @""; n.frame = f; n.scrollRef = area.ref;
      if (![it[@"c"] isEqualToString:it[@"t"]]) n.context = it[@"c"];
      SFWebTarget *target = [SFWebTarget new];
      target.webView = web; target.index = [it[@"i"] integerValue];
      n.source = target;
      [s.webTargets addObject:target];  // the node holds it weakly
      CGRect on = CGRectIntersection(f, visible);
      if ([it[@"s"] boolValue] && !CGRectIsEmpty(on)) {
        n.tap = SFMid(on);
        n.clipped = !CGRectEqualToRect(on, f);
        [s.nodes addObject:n];
      } else if (area && ![it[@"s"] boolValue]) {
        NSString *dir = CGRectGetMidY(f) > CGRectGetMidY(visible) ? @"down" : @"up";
        if (![area.more containsObject:dir] || CGRectIntersectsRect(f, visible)) continue;  // covered, not scrolled away
        n.direction = dir;
        if (s.hidden.count < kSFMaxHiddenCollected) [s.hidden addObject:n];
      }
    }
    for (NSDictionary *tx in page[@"texts"]) {
      CGRect f = ToScreen(tx[@"r"], viewport, scale);
      if (!CGRectIntersectsRect(f, visible)) continue;
      SFText *t = [SFText new];
      t.label = tx[@"t"]; t.frame = SFRound(f); t.visibleFrame = CGRectIntersection(f, visible); t.scrollRef = area.ref;
      t.shown = YES; t.header = [tx[@"h"] boolValue]; t.noTapTarget = YES;  // page text, not a tap target of its own
      [s.texts addObject:t];
    }
  }
}

// Click by script: the page's own handlers run exactly as for a tap, without hit-testing WebKit's gestures.
BOOL SFWebClick(SFWebTarget *target) {
  UIView *web = target.webView;
  if (!web) return NO;
  NSString *js = [NSString stringWithFormat:@"(() => { const el = (window.__simflick || [])[%ld]; if (!el) return 'gone';"
                   " el.scrollIntoView({block: 'nearest'}); el.focus && el.focus(); el.click(); return 'ok'; })()", (long)target.index];
  NSDictionary *r = RunInPage(web, [NSString stringWithFormat:@"JSON.stringify({ r: %@ })", js], 0.6);
  return [r[@"r"] isEqualToString:@"ok"];
}
