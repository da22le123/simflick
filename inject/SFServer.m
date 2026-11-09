// Minimal HTTP server on 127.0.0.1: GET /screen, GET /debug, POST /tap, POST /swipe.
#import "SFModel.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <pthread.h>

typedef struct { NSString *method, *path; NSDictionary<NSString *, NSString *> *query, *headers; } SFRequest;

static SFRequest Parse(const char *raw) {
  NSString *req = [NSString stringWithUTF8String:raw] ?: @"";
  NSArray *lines = [req componentsSeparatedByString:@"\r\n"];
  NSArray *first = [lines.firstObject componentsSeparatedByString:@" "];
  NSURLComponents *u = first.count > 1 ? [NSURLComponents componentsWithString:first[1]] : nil;
  NSMutableDictionary *q = [NSMutableDictionary dictionary], *h = [NSMutableDictionary dictionary];
  for (NSURLQueryItem *it in u.queryItems) if (it.value) q[it.name] = it.value;
  for (NSString *l in lines) {
    NSRange c = [l rangeOfString:@":"];
    if (c.location != NSNotFound) h[[l substringToIndex:c.location].lowercaseString] = [[l substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  }
  return (SFRequest){first.firstObject ?: @"", u.path ?: @"", q, h};
}

// Browsers can reach 127.0.0.1 too: require the launch token, a local Host (DNS rebinding), no Origin
// (any web page), and POST for anything that acts. Returns 0 when allowed.
static int Rejection(SFRequest r, NSString *token) {
  NSString *host = [r.headers[@"host"] componentsSeparatedByString:@":"].firstObject ?: @"";
  if (r.headers[@"origin"] || !([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"])) return 403;
  if (token.length && ![r.headers[@"x-simflick-token"] isEqualToString:token]) return 401;
  BOOL readOnly = [r.path isEqualToString:@"/screen"] || [r.path isEqualToString:@"/debug"];
  if (!readOnly && ![r.method isEqualToString:@"POST"]) return 405;
  return 0;
}

static NSData *Route(SFRequest r) {
  __block NSData *body = nil;
  if ([r.path isEqualToString:@"/screen"]) {
    BOOL debug = r.query[@"debug"] != nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ @autoreleasepool { body = SFScreenJSON(debug); } });
  } else if ([r.path isEqualToString:@"/debug"]) {
    dispatch_sync(dispatch_get_main_queue(), ^{ body = SFViewDump(); });
  } else {
    body = SFHandleAction(r.path, r.query);  // waits on the main thread itself
  }
  return body;
}

static void Reply(int fd, int status, NSData *body) {
  NSString *head = status == 200
    ? [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)body.length]
    : [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status, status == 404 ? @"Not Found" : @"Rejected"];
  send(fd, head.UTF8String, strlen(head.UTF8String), 0);
  if (status == 200) send(fd, body.bytes, body.length, 0);
  close(fd);
}

static void *Loop(void *arg) {
  NSString *token = getenv("SIMFLICK_TOKEN") ? @(getenv("SIMFLICK_TOKEN")) : nil;
  if (!token.length) NSLog(@"[simflick] no SIMFLICK_TOKEN set; any local process can drive this app");
  int port = getenv("SIMFLICK_PORT") ? atoi(getenv("SIMFLICK_PORT")) : 8765;
  int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 8)) { NSLog(@"[simflick] bind %d failed", port); return NULL; }
  NSLog(@"[simflick] listening on 127.0.0.1:%d", port);
  for (;;) {
    int cl = accept(fd, NULL, NULL);
    if (cl < 0) continue;
    char buf[2048];
    ssize_t n = recv(cl, buf, sizeof buf - 1, 0);
    buf[n > 0 ? n : 0] = 0;
    @autoreleasepool {
      SFRequest r = Parse(buf);
      int status = Rejection(r, token);
      if (status) { Reply(cl, status, nil); continue; }
      NSData *body = Route(r);
      Reply(cl, body ? 200 : 404, body);
    }
  }
}

void SFServe(void) {
  pthread_t t;
  pthread_create(&t, NULL, Loop, NULL);
  pthread_detach(t);
}
