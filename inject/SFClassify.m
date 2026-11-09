#import "SFModel.h"
#import <objc/message.h>

static BOOL InWebView(id obj) {
  static Class web;
  if (!web) web = NSClassFromString(@"WKWebView");
  if (!web || ![obj isKindOfClass:UIView.class]) return NO;
  for (UIView *v = obj; v; v = v.superview) if ([v isKindOfClass:web]) return YES;
  return NO;
}

SFRole SFRoleOf(id obj) {
  // Web views (and their content view) and read-only text views adopt UITextInput too, but you can't type into them.
  BOOL editable = !([obj isKindOfClass:UITextView.class] && !((UITextView *)obj).editable) && !InWebView(obj);
  if (editable && [obj conformsToProtocol:@protocol(UITextInput)]) return SFRoleInput;
  UIAccessibilityTraits t = [obj accessibilityTraits];
  if (t & UIAccessibilityTraitButton) return SFRoleButton;
  if (t & UIAccessibilityTraitLink) return SFRoleLink;
  if (t & UIAccessibilityTraitAdjustable) return SFRoleAdjustable;
  if (t & UIAccessibilityTraitHeader) return SFRoleHeader;
  if (t & UIAccessibilityTraitStaticText) return SFRoleText;
  return SFRoleElement;
}

// React Native (Fabric) text: RCTParagraphComponentView, which is not always an accessibility element.
BOOL SFIsRNText(UIView *v) { return [NSStringFromClass(v.class) containsString:@"Paragraph"]; }

// Readable text from any framework: RN text, or an accessibility element that is static text / a header, not a control.
BOOL SFIsTextView(UIView *v) {
  if (SFIsRNText(v)) return YES;
  SFRole role = v.isAccessibilityElement ? SFRoleOf(v) : SFRoleElement;
  return role == SFRoleText || role == SFRoleHeader;
}

// A bar/point of a chart (Swift Charts, or any view with an accessibilityChartDescriptor): data, not a control.
BOOL SFIsChartPoint(id obj) {
  SEL descriptor = NSSelectorFromString(@"accessibilityChartDescriptor");
  id c = obj;
  for (int i = 0; i < 3 && [c respondsToSelector:@selector(accessibilityContainer)] && (c = [c accessibilityContainer]); i++)
    if ([c respondsToSelector:descriptor] && ((id (*)(id, SEL))objc_msgSend)(c, descriptor)) return YES;
  return NO;
}

// The button an element is part of (SwiftUI: text inside a post's or a name's button), via its accessibility parents.
id SFOwningButton(id obj) {
  id c = obj;
  for (int i = 0; i < 4 && [c respondsToSelector:@selector(accessibilityContainer)] && (c = [c accessibilityContainer]); i++) {
    if ([c isKindOfClass:UIView.class] && ![c isAccessibilityElement]) continue;  // plain container views
    if ([c accessibilityTraits] & (UIAccessibilityTraitButton | UIAccessibilityTraitLink)) return c;
  }
  return nil;
}

// Progress bars, spinners, timers: they update by themselves and can't be acted on.
BOOL SFIsStatus(id obj) {
  if ([obj isKindOfClass:UIActivityIndicatorView.class] || [obj isKindOfClass:UIProgressView.class]) return YES;
  UIAccessibilityTraits t = [obj accessibilityTraits];
  return (t & UIAccessibilityTraitUpdatesFrequently) && !(t & (UIAccessibilityTraitButton | UIAccessibilityTraitLink | UIAccessibilityTraitAdjustable));
}

// What a view itself responds to, from the gesture recognizers attached to it (UIKit, react-native-gesture-handler).
// Not accessibility: this is how the touch is actually handled. UIKit's own internals (scroll views, bars, RN's root
// touch handler) are skipped: they say nothing about this view being a control.
NSArray<NSString *> *SFGesturesOf(UIView *v) {
  if ([v isKindOfClass:UIScrollView.class] || [v isKindOfClass:UIControl.class] || [NSStringFromClass(v.class) hasPrefix:@"_"]) return nil;
  NSMutableOrderedSet *kinds = [NSMutableOrderedSet orderedSet];
  for (UIGestureRecognizer *g in v.gestureRecognizers) {
    NSString *cls = NSStringFromClass(g.class);
    if (!g.enabled || [cls hasPrefix:@"_"] || [cls containsString:@"TouchHandler"] || [cls containsString:@"Hover"]) continue;
    if ([g isKindOfClass:UITapGestureRecognizer.class] || [cls containsString:@"Tap"]) [kinds addObject:@"tap"];
    else if ([g isKindOfClass:UIPanGestureRecognizer.class] || [g isKindOfClass:UISwipeGestureRecognizer.class] ||
             [cls containsString:@"Pan"] || [cls containsString:@"Swipe"] || [cls containsString:@"Fling"]) [kinds addObject:@"swipe"];
    else if ([g isKindOfClass:UILongPressGestureRecognizer.class] || [cls containsString:@"LongPress"]) [kinds addObject:@"long press"];
  }
  return kinds.count ? kinds.array : nil;
}

// Content still arriving: a spinning UIActivityIndicatorView or a web view that is loading.
BOOL SFIsLoadingIndicator(UIView *v) {
  if ([v isKindOfClass:UIActivityIndicatorView.class]) return ((UIActivityIndicatorView *)v).isAnimating;
  static Class web;
  if (!web) web = NSClassFromString(@"WKWebView");
  if (web && [v isKindOfClass:web] && [v respondsToSelector:@selector(isLoading)])
    return ((BOOL (*)(id, SEL))objc_msgSend)(v, @selector(isLoading));
  return NO;
}

// Says what something is ("Riga"), unlike counters ("491", "5 · 238").
BOOL SFHasWords(NSString *s) {
  return s.length > 2 && [s rangeOfString:@"[A-Za-z\\p{L}]{2}" options:NSRegularExpressionSearch].location != NSNotFound;
}
