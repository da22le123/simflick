// Shared types and helpers of the injected reader. Pipeline: SFCollect (walk) -> SFRefine (passes) -> SFScreenJSON.
#import <UIKit/UIKit.h>
#import "SFTuning.h"

typedef NS_ENUM(NSInteger, SFRole) {
  SFRoleElement, SFRoleButton, SFRoleLink, SFRoleInput, SFRoleSwitch, SFRoleAdjustable, SFRoleHeader, SFRoleText, SFRoleRow,
};
NSString *SFRoleName(SFRole role);

@interface SFScrollArea : NSObject
@property(nonatomic, copy) NSString *ref, *identifier;   // ref = "S0", "S1"… in walk order
@property(nonatomic, weak) UIView *view;
@property(nonatomic) CGRect visibleFrame;
@property(nonatomic) CGPoint offset;
@property(nonatomic) CGSize contentSize;
@property(nonatomic, copy) NSArray<NSString *> *more;     // directions with content left: up/down/left/right
@property(nonatomic) BOOL paging;
@property(nonatomic) NSInteger hiddenCount;               // elements scrolled out of view
@property(nonatomic, copy) NSArray<NSDictionary *> *ahead; // preview of hidden elements, filled by SFRefine
- (NSDictionary *)json;
@end

// Something to act on: on screen (tap set) or scrolled out of view inside a scroll area (direction set).
@interface SFNode : NSObject
@property(nonatomic) SFRole role;
@property(nonatomic, copy) NSString *identifier, *label, *value, *context;
@property(nonatomic) CGRect frame;          // screen points, rounded
@property(nonatomic) CGPoint tap;
@property(nonatomic, copy) NSString *scrollRef;
@property(nonatomic) BOOL clipped, selected;
@property(nonatomic, copy) NSString *direction; // hidden nodes only
@property(nonatomic, copy) NSString *coveredBy; // covered nodes only: what lies on top
@property(nonatomic, weak) id source;            // the view or accessibility element it came from
- (NSDictionary *)json;
- (NSDictionary *)hiddenJSON;
@end

// Readable text: page text, a source of context, and a fallback tap target for gesture-only SwiftUI views.
@interface SFText : NSObject
@property(nonatomic, copy) NSString *label;
@property(nonatomic) CGRect frame, visibleFrame;  // frame rounded; visibleFrame raw
@property(nonatomic, copy) NSString *scrollRef;
@property(nonatomic) BOOL shown, header, noTapTarget;  // noTapTarget: RN / web text, never offered as a text item
@property(nonatomic, copy) NSString *direction;  // scrolled out of view: which way
@property(nonatomic, weak) id owner;            // the button this text is part of (tapping the text = tapping it)
@property(nonatomic, copy) NSString *ownerLabel;
@end

// A link/button inside a web page, clicked by script (index into the page's last read).
@interface SFWebTarget : NSObject
@property(nonatomic, weak) UIView *webView;
@property(nonatomic) NSInteger index;
@end

// A list cell or accessibility container that may become an "open item" row.
@interface SFRowCandidate : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic, copy) NSString *scrollRef;
@property(nonatomic) BOOL axGroup;
@end

@interface SFSnapshot : NSObject
@property(nonatomic, strong) NSArray<UIWindow *> *windows;
@property(nonatomic, strong) NSMutableArray<SFNode *> *nodes, *hidden, *covered;  // covered: on screen under a popup
@property(nonatomic, strong) NSMutableArray<SFText *> *texts;
@property(nonatomic, strong) NSMutableArray<NSString *> *notes;          // extra page text lines (hints)
@property(nonatomic, strong) NSMutableArray<SFRowCandidate *> *rowCandidates;
@property(nonatomic, strong) NSMutableArray<SFScrollArea *> *scrolls;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *remote, *textItems;
@property(nonatomic, strong) NSMutableArray<UIView *> *webViews;          // visible WKWebViews, read after the walk
@property(nonatomic, strong) NSMutableArray<SFWebTarget *> *webTargets;   // keeps web nodes' sources alive
@property(nonatomic, weak) UIView *focused;
@property(nonatomic) BOOL animating, loading;
@property(nonatomic, strong) NSMutableArray *debug;                       // rejected candidates, only with ?debug=1
- (SFScrollArea *)scrollWithRef:(NSString *)ref;
- (NSArray<NSString *> *)pageText;
@end

// Geometry and hit testing (SFGeometry.m).
NSNumber *SFNum(CGFloat v);
NSArray<NSNumber *> *SFRectJSON(CGRect r);
NSArray<NSNumber *> *SFPointJSON(CGPoint p);
CGRect SFRound(CGRect r);
CGPoint SFMid(CGRect r);
NSArray<UIWindow *> *SFWindows(void);
CGRect SFAppBounds(void);
UIView *SFHitView(CGPoint p, NSArray<UIWindow *> *windows);
BOOL SFHitBelongsTo(UIView *hit, UIView *owner);
NSString *SFNearestId(UIView *v);
CGRect SFFrameOnScreen(UIView *v);

// Classification (SFClassify.m).
SFRole SFRoleOf(id obj);
BOOL SFIsChartPoint(id obj);
BOOL SFIsStatus(id obj);
id SFOwningButton(id obj);
BOOL SFIsLoadingIndicator(UIView *v);
BOOL SFIsRNText(UIView *v);
BOOL SFIsTextView(UIView *v);
BOOL SFHasWords(NSString *s);

// Context text (SFContext.m).
NSString *SFContextFor(UIView *v, NSString *own, BOOL offscreenOK);
NSString *SFSiblingText(NSArray *siblings, id me);
NSArray *SFAXChildren(id obj);

// Pipeline.
SFSnapshot *SFCollect(BOOL debug);
void SFRefine(SFSnapshot *s);
void SFScanLists(SFSnapshot *s);
void SFReadWebViews(SFSnapshot *s);
BOOL SFWebClick(SFWebTarget *target);
NSData *SFScreenJSON(BOOL debug, BOOL scan);
NSData *SFViewDump(void);
NSData *SFHandleAction(NSString *path, NSDictionary<NSString *, NSString *> *query);
BOOL SFActivateAt(CGPoint p, NSString **label);
void SFKeyboardTrack(void);
CGRect SFKeyboardFrame(void);
void SFServe(void);
