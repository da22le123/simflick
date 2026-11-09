#import "SFModel.h"

NSString *SFRoleName(SFRole role) {
  switch (role) {
    case SFRoleButton: return @"button";
    case SFRoleLink: return @"link";
    case SFRoleInput: return @"input";
    case SFRoleSwitch: return @"switch";
    case SFRoleAdjustable: return @"adjustable";
    case SFRoleHeader: return @"header";
    case SFRoleText: return @"text";
    case SFRoleRow: return @"row";
    case SFRoleElement: return @"element";
  }
  return @"element";
}

@implementation SFScrollArea
- (NSDictionary *)json {
  return @{@"ref": _ref, @"id": _identifier ?: @"", @"frame": SFRectJSON(_visibleFrame), @"more": _more ?: @[],
           @"offset": SFPointJSON(_offset), @"content": @[SFNum(_contentSize.width), SFNum(_contentSize.height)],
           @"paging": @(_paging), @"hiddenItems": @(_hiddenCount), @"ahead": _ahead ?: @[]};
}
@end

@implementation SFNode
- (NSDictionary *)json {
  NSMutableDictionary *e = [@{@"kind": SFRoleName(_role), @"id": _identifier ?: @"", @"label": _label ?: @"",
                              @"frame": SFRectJSON(_frame), @"tap": SFPointJSON(_tap)} mutableCopy];
  if (_clipped) e[@"clipped"] = @YES;
  if (_value.length) e[@"value"] = _value;
  if (_scrollRef) e[@"in"] = _scrollRef;
  if (_context.length) e[@"context"] = _context;
  if (_selected) e[@"selected"] = @YES;
  return e;
}
- (NSDictionary *)hiddenJSON {
  return @{@"kind": SFRoleName(_role), @"id": _identifier ?: @"", @"label": _label ?: @"", @"context": _context ?: @"",
           @"frame": SFRectJSON(_frame), @"in": _scrollRef ?: @"", @"dir": _direction ?: @""};
}
@end

@implementation SFText
@end

@implementation SFRowCandidate
@end

@implementation SFSnapshot
- (instancetype)init {
  if ((self = [super init])) {
    _nodes = [NSMutableArray array]; _hidden = [NSMutableArray array]; _covered = [NSMutableArray array]; _texts = [NSMutableArray array];
    _notes = [NSMutableArray array]; _rowCandidates = [NSMutableArray array]; _scrolls = [NSMutableArray array];
    _remote = [NSMutableArray array]; _textItems = [NSMutableArray array];
  }
  return self;
}
- (SFScrollArea *)scrollWithRef:(NSString *)ref {
  for (SFScrollArea *a in _scrolls) if ([a.ref isEqualToString:ref]) return a;
  return nil;
}
- (NSArray<NSString *> *)pageText {
  NSMutableArray *out = [NSMutableArray array];
  NSMutableArray<SFText *> *seen = [NSMutableArray array];
  for (SFText *t in _texts) {
    if (!t.shown) continue;
    BOOL repeat = NO;  // the same text at the same spot (a view and its accessibility node)
    for (SFText *o in seen) if ([o.label isEqualToString:t.label] && CGRectIntersectsRect(o.frame, t.frame)) { repeat = YES; break; }
    if (repeat) continue;
    [seen addObject:t];
    [out addObject:t.label];
  }
  [out addObjectsFromArray:_notes];
  return out;
}
@end
