#import "SFModel.h"
#import <objc/message.h>

SFRole SFRoleOf(id obj) {
  // Web views and read-only text views adopt UITextInput too, but you can't type into them.
  BOOL editable = !([obj isKindOfClass:UITextView.class] && !((UITextView *)obj).editable) && ![NSStringFromClass([obj class]) hasPrefix:@"WK"];
  if (editable && [obj conformsToProtocol:@protocol(UITextInput)]) return SFRoleInput;
  UIAccessibilityTraits t = [obj accessibilityTraits];
  if (t & UIAccessibilityTraitButton) return SFRoleButton;
  if (t & UIAccessibilityTraitLink) return SFRoleLink;
  if (t & UIAccessibilityTraitAdjustable) return SFRoleAdjustable;
  if (t & UIAccessibilityTraitHeader) return SFRoleHeader;
  if (t & UIAccessibilityTraitStaticText) return SFRoleText;
  return SFRoleElement;
}

// Swift Charts exposes every bar as an element ("0 to 0,5", value "20"): data points, not controls.
BOOL SFIsChartPoint(id obj) {
  if ([obj isKindOfClass:UIView.class] || ([obj accessibilityTraits] & (UIAccessibilityTraitButton | UIAccessibilityTraitLink))) return NO;
  return [[obj accessibilityLabel] rangeOfString:@"^-?[0-9.,]+ to -?[0-9.,]+$" options:NSRegularExpressionSearch].location != NSNotFound;
}

// Content still arriving: a spinning UIActivityIndicatorView or a web view that is loading.
BOOL SFIsLoadingIndicator(UIView *v) {
  if ([v isKindOfClass:UIActivityIndicatorView.class]) return ((UIActivityIndicatorView *)v).isAnimating;
  if ([NSStringFromClass(v.class) isEqualToString:@"WKWebView"] && [v respondsToSelector:@selector(isLoading)])
    return ((BOOL (*)(id, SEL))objc_msgSend)(v, @selector(isLoading));
  return NO;
}

// Says what something is ("Riga"), unlike counters ("491", "5 · 238").
BOOL SFHasWords(NSString *s) {
  return s.length > 2 && [s rangeOfString:@"[A-Za-z\\p{L}]{2}" options:NSRegularExpressionSearch].location != NSNotFound;
}
