// Every threshold the reader uses, in one place. Points are iOS points; fractions are of an area or side.
#import <CoreGraphics/CoreGraphics.h>

// Visibility
static const CGFloat kSFInvisibleAlpha = 0.01;      // at or below: not drawn
static const CGFloat kSFMinProbeSide = 2;           // a visible part thinner than this can't be hit-tested
static const CGFloat kSFSliverFraction = 0.33;      // less than this much of an element showing…
static const CGFloat kSFSliverSide = 24;            // …and thinner than this: too little to tap reliably

// Context: text that says which card/row an element belongs to
static const int kSFContextClimb = 5;               // ancestor levels to search
static const int kSFContextDepth = 10;              // subview levels to collect text from
static const int kSFContextMaxTexts = 6;            // more text than this = we climbed to list level, stop
static const NSUInteger kSFContextMaxChars = 100;
static const NSUInteger kSFMaxSiblingsForContext = 8;  // bigger AX containers are lists, not cards
static const CGFloat kSFNearestTextRadius = 100;    // flat SwiftUI stacks: nearest text within this distance

// Rows ("open item" targets)
static const CGFloat kSFGroupMinHeight = 50;        // AX container as a row: at least this tall…
static const CGFloat kSFGroupMaxScreenHeight = 0.7; // …at most this much of the screen tall…
static const CGFloat kSFGroupMinScreenWidth = 0.6;  // …and at least this much of its width
static const CGFloat kSFCellMinHeight = 30;         // list cells shorter than this aren't rows
static const CGFloat kSFOneControlFraction = 0.7;   // a cell this full of one control is that control
static const CGFloat kSFDuplicateRowOverlap = 0.8;  // rows overlapping this much are the same row
static const int kSFFreeSpotColumns = 10, kSFFreeSpotRows = 16;  // grid searched for a row's tap point
static const CGFloat kSFFreeSpotPadding = 4;        // keep row taps this far from inner elements
static const CGFloat kSFBelowHeader = 18;           // container rows: tap this far below the top inner element
static const NSUInteger kSFRowLabelPhrases = 3;
static const NSUInteger kSFRowLabelChars = 160;

// Merging duplicates
static const CGFloat kSFSamePlaceCenter = 6;        // centres this close…
static const CGFloat kSFSamePlaceSize = 12;         // …and sizes this close = the same control

// Output caps
static const NSUInteger kSFMaxHidden = 200;
static const NSUInteger kSFMaxTextItems = 40;
static const NSUInteger kSFMaxAhead = 20;           // hidden-element preview per scroll area
static const int kSFMaxAXDepth = 40;
static const NSUInteger kSFMaxViewControllers = 50; // searched for a tab bar controller
