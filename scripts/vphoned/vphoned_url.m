/*
 * vphoned_url — URL opening via LSApplicationWorkspace.
 *
 * Uses LSApplicationWorkspace (CoreServices) to open URLs.
 * Does not require UIKit — works from daemon context.
 */

#import "vphoned_url.h"
#import "vphoned_protocol.h"
#include <objc/message.h>

const NSTimeInterval VPURLCommandTimeoutSeconds = 5.0;
static BOOL urlOpenInFlight = NO;

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options;
@end

@interface VPURLOpenResult : NSObject
@property(nonatomic, assign) BOOL ok;
@property(nonatomic, copy) NSString *message;
@end

@implementation VPURLOpenResult
@end

static dispatch_queue_t vp_url_open_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create("vphone.vphoned.url.open", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static NSLock *vp_url_open_lock(void) {
  static NSLock *lock;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    lock = [NSLock new];
  });
  return lock;
}

static BOOL vp_begin_url_open(void) {
  NSLock *lock = vp_url_open_lock();
  [lock lock];
  if (urlOpenInFlight) {
    // busy: reject overlapping open_url calls while the worker is still in flight.
    [lock unlock];
    return NO;
  }
  urlOpenInFlight = YES;
  [lock unlock];
  return YES;
}

NSDictionary *vp_handle_url_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *urlStr = msg[@"url"];

  if (!urlStr) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"missing url";
    return r;
  }

  NSURL *url = [NSURL URLWithString:urlStr];
  if (!url) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"invalid url: %@", urlStr];
    return r;
  }

  if (!vp_begin_url_open()) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"open_url busy";
    return r;
  }

  VPURLOpenResult *result = [VPURLOpenResult new];
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(vp_url_open_queue(), ^{
    @autoreleasepool {
      @try {
        LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
        BOOL ok = NO;

        SEL openURLSel = sel_registerName("openURL:withOptions:");
        if ([ws respondsToSelector:openURLSel]) {
          ok =
              ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, openURLSel, url, nil);
        }

        if (!ok) {
          SEL sensitiveSel = sel_registerName("openSensitiveURL:withOptions:");
          if ([ws respondsToSelector:sensitiveSel]) {
            ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, sensitiveSel,
                                                           url, nil);
          }
        }

        result.ok = ok;
      } @catch (NSException *exception) {
        result.ok = NO;
        result.message = [NSString
            stringWithFormat:@"open url exception: %@", exception.reason ?: exception.name];
      } @finally {
        NSLock *lock = vp_url_open_lock();
        [lock lock];
        urlOpenInFlight = NO;
        [lock unlock];
        dispatch_semaphore_signal(done);
      }
    }
  });

  long waitResult = dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(VPURLCommandTimeoutSeconds * NSEC_PER_SEC)));

  NSMutableDictionary *r = vp_make_response(@"open_url", reqId);
  if (waitResult != 0) {
    r[@"ok"] = @NO;
    r[@"msg"] = [NSString
        stringWithFormat:@"open_url timed out after %.0fs",
                         VPURLCommandTimeoutSeconds];
    return r;
  }

  r[@"ok"] = @(result.ok);
  if (!result.ok) {
    r[@"msg"] = result.message ?:
        [NSString stringWithFormat:@"failed to open url: %@", urlStr];
  }
  return r;
}
