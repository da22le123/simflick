// Runs when the library is loaded into the app (DYLD_INSERT_LIBRARIES).
#import "SFModel.h"
#import <dlfcn.h>

// SwiftUI builds its full accessibility tree only for an attached AX client; turn on automation mode
// like KIF does (private libAccessibility call), so buttons inside rows and cells are exposed.
static void EnableAutomation(void) {
  void *ax = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
  void (*setAutomation)(int) = ax ? (void (*)(int))dlsym(ax, "_AXSSetAutomationEnabled") : NULL;
  if (setAutomation) setAutomation(1); else NSLog(@"[simflick] _AXSSetAutomationEnabled unavailable");
}

// What an AX client (VoiceOver, axe) triggers: the UIKit and SwiftUI accessibility bundles, once UIKit is up.
static void LoadAccessibilityBundles(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    // Simulator processes see iOS system files under IPHONE_SIMULATOR_ROOT, not under the Mac's /System.
    NSString *root = NSProcessInfo.processInfo.environment[@"IPHONE_SIMULATOR_ROOT"] ?: @"";
    for (NSString *b in @[@"UIKit", @"SwiftUI"]) {
      NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/System/Library/AccessibilityBundles/%@.axbundle", root, b]];
      NSError *err = nil;
      if (!bundle || ![bundle loadAndReturnError:&err]) NSLog(@"[simflick] could not load %@.axbundle: %@", b, err ?: @"bundle not found");
      else NSLog(@"[simflick] loaded %@.axbundle", b);
    }
  });
}

__attribute__((constructor)) static void Start(void) {
  EnableAutomation();
  LoadAccessibilityBundles();
  SFKeyboardTrack();
  SFServe();
}
