// Link the real controller as its own .m. Test-only hooks inject boundaries and
// expose static production entry points, without duplicating their algorithms.
#import "HTTPPrivacyPolicy.h"
#import "RDPreviewController.h"
#import "RDPreviewWindow.h"
#import "DetectedMedia.h"
#import <AVFoundation/AVFoundation.h>
extern void RDPreviewTestSetSessions(id master, id trust);
extern NSURLRequest *RDPreviewTestRedirect(id task, NSURLRequest *request);
extern void RDPreviewTestRegisterRequest(id task, NSURLRequest *request);
extern NSDictionary *RDPreviewTestAssetOptions(DetectedMedia *media);
extern NSString *RDPreviewTestResolveURL(NSString *url, DetectedMedia *media);
extern void RDPreviewTestPlayPinned(NSString *master, NSString *variant, DetectedMedia *media);
static NSString * const RDPreviewHTTPHeaderFieldsKey = @"AVURLAssetHTTPHeaderFieldsKey";

static NSUInteger checks, failed, created, resumed;
static NSMutableArray<NSURLRequest *> *requests;
static BOOL completeSynchronously;
static void Check(BOOL ok, NSString *name) {
    checks++;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name.UTF8String);
    if (!ok) failed++;
}
@interface RDPreviewTestTask : NSObject
@property (nonatomic, copy) void (^completion)(void);
- (void)resume;
- (void)cancel;
@end
@implementation RDPreviewTestTask
- (void)resume { resumed++; if (self.completion) self.completion(); }
- (void)cancel {}
@end
@interface RDPreviewTestSession : NSObject
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
@end
@implementation RDPreviewTestSession
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    created++;
    [requests addObject:[request copy]];
    RDPreviewTestTask *task = [RDPreviewTestTask new];
    if (completeSynchronously) {
        task.completion = ^{
            NSURLResponse *response = [[NSURLResponse alloc] initWithURL:request.URL MIMEType:@"video/mp4" expectedContentLength:1 textEncodingName:nil];
            completion(NSData.data, response, nil);
        };
    }
    return task;
}
@end
// Any accidentally reached UI boundary aborts the executable: never create UI.
NSString * const RDPreviewWindowDidCloseNotification = @"RDPreviewWindowDidClose";
@implementation RDPreviewWindow
+ (void)attachPlayer:(AVPlayer *)player title:(NSString *)title { fprintf(stderr, "FORBIDDEN_UI_BOUNDARY\n"); abort(); }
+ (void)showError:(NSString *)message title:(NSString *)title { fprintf(stderr, "FORBIDDEN_UI_BOUNDARY\n"); abort(); }
+ (void)close {}
@end

static void TestHeaderMatrix(void) {
    NSArray *sources = @[
        @{ @"source": @"https://site.example/private/watch?token=FIXTURE_ONLY#fragment", @"origin": @"https://site.example", @"full": @"https://site.example/private/watch?token=FIXTURE_ONLY" },
        @{ @"source": @"https://site.example:8443/watch?q=1#hash", @"origin": @"https://site.example:8443", @"full": @"https://site.example:8443/watch?q=1" },
        @{ @"source": @"https://user:secret@site.example/watch?q=1", @"origin": @"", @"full": @"" },
        @{ @"source": @"file:///private/page?q=1", @"origin": @"", @"full": @"" },
        @{ @"source": @"", @"origin": @"", @"full": @"" }
    ];
    for (NSDictionary *fixture in sources) {
        NSString *origin = fixture[@"origin"];
        NSArray *targets = @[origin.length ? [origin stringByAppendingString:@"/video.mp4"] : @"https://site.example/video.mp4", @"https://cdn.example/video.mp4"];
        for (NSUInteger mode = 0; mode < 4; mode++) {
            [HTTPPrivacyPolicy setRefererModeOverride:@(mode)];
            for (NSUInteger cross = 0; cross < 2; cross++) {
                DetectedMedia *m = [DetectedMedia new];
                m.sourcePageURL = fixture[@"source"];
                NSString *expectedNative = mode == HTTPRefererModeNone ? @"" :
                    (mode == HTTPRefererModeFullPath ? (cross ? @"" : fixture[@"full"]) : origin);
                NSString *expectedAsset = (mode == HTTPRefererModeOrigin || mode == HTTPRefererModeCrossOrigin) ? origin : @"";
                NSString *asset = RDPreviewTestAssetOptions(m)[RDPreviewHTTPHeaderFieldsKey][@"Referer"] ?: @"";
                Check([asset isEqual:expectedAsset], [NSString stringWithFormat:@"asset matrix mode=%lu cross=%lu source=%@", (unsigned long)mode, (unsigned long)cross, fixture[@"source"]]);
                completeSynchronously = YES;
                (void)RDPreviewTestResolveURL(targets[cross], m);
                NSString *resolved = [requests.lastObject valueForHTTPHeaderField:@"Referer"] ?: @"";
                Check([resolved isEqual:expectedNative], [NSString stringWithFormat:@"resolver matrix mode=%lu cross=%lu source=%@", (unsigned long)mode, (unsigned long)cross, fixture[@"source"]]);
                completeSynchronously = NO;
                RDPreviewTestPlayPinned(targets[cross], @"https://cdn.example/720.m3u8", m);
                NSString *master = [requests.lastObject valueForHTTPHeaderField:@"Referer"] ?: @"";
                Check([master isEqual:expectedNative], [NSString stringWithFormat:@"master matrix mode=%lu cross=%lu source=%@", (unsigned long)mode, (unsigned long)cross, fixture[@"source"]]);
            }
        }
    }
}

static void TestRedirectHeaders(void) {
    for (NSUInteger mode = 0; mode < 4; mode++) {
        [HTTPPrivacyPolicy setRefererModeOverride:@(mode)];
        NSObject *task = [NSObject new];
        NSMutableURLRequest *initial = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://site.example/video.mp4"]];
        [initial setValue:@"session=FIXTURE_ONLY" forHTTPHeaderField:@"Cookie"];
        [initial setValue:@"Bearer FIXTURE_ONLY" forHTTPHeaderField:@"Authorization"];
        [initial setValue:mode == HTTPRefererModeNone ? nil : @"https://site.example/private/watch?token=FIXTURE_ONLY" forHTTPHeaderField:@"Referer"];
        RDPreviewTestRegisterRequest(task, initial);
        NSMutableURLRequest *same = [initial mutableCopy];
        same.URL = [NSURL URLWithString:@"https://site.example/step2.mp4"];
        NSURLRequest *accepted = RDPreviewTestRedirect(task, same);
        Check([[accepted valueForHTTPHeaderField:@"Cookie"] isEqual:@"session=FIXTURE_ONLY"], @"same-origin redirect preserves current Cookie");
        Check([[accepted valueForHTTPHeaderField:@"Authorization"] isEqual:@"Bearer FIXTURE_ONLY"], @"same-origin redirect preserves current Authorization");
        NSMutableURLRequest *cross = [initial mutableCopy];
        cross.URL = [NSURL URLWithString:@"https://cdn.example/step3.mp4"];
        NSURLRequest *stripped = RDPreviewTestRedirect(task, cross);
        Check([stripped valueForHTTPHeaderField:@"Cookie"] == nil && [stripped valueForHTTPHeaderField:@"Authorization"] == nil, @"cross-origin redirect strips credentials");
        NSString *ref = [stripped valueForHTTPHeaderField:@"Referer"];
        Check(mode == HTTPRefererModeNone || mode == HTTPRefererModeFullPath ? ref == nil : [ref isEqual:@"https://site.example"], @"redirect Referer follows selected mode");
        NSMutableURLRequest *returning = [initial mutableCopy]; // Deliberately tries to restore original secrets.
        returning.URL = [NSURL URLWithString:@"https://site.example/step4.mp4"];
        NSURLRequest *returned = RDPreviewTestRedirect(task, returning);
        Check([returned valueForHTTPHeaderField:@"Cookie"] == nil && [returned valueForHTTPHeaderField:@"Authorization"] == nil, @"return hop never restores original credentials");
        if (mode == HTTPRefererModeNone || mode == HTTPRefererModeFullPath)
            Check([returned valueForHTTPHeaderField:@"Referer"] == nil, @"return hop never restores stripped Referer");
        NSMutableURLRequest *last = [initial mutableCopy];
        NSURLRequest *again = RDPreviewTestRedirect(task, last);
        Check([again valueForHTTPHeaderField:@"Cookie"] == nil && [again valueForHTTPHeaderField:@"Authorization"] == nil, @"subsequent same-origin hop preserves stripped state");
    }
}

int main(void) {
    @autoreleasepool {
        requests = [NSMutableArray array];
        DetectedMedia *media = [DetectedMedia new];
        media.sourcePageURL = @"https://site.example/private/watch?token=FIXTURE_ONLY#fragment";
        media.mediaURL = @"https://cdn.example/720.m3u8";
        media.parentMediaURL = @"https://cdn.example/master.m3u8";
        media.format = @"hls";
        media.declaredVariants = @[@{@"url": media.mediaURL}, @{@"url": @"https://cdn.example/480.m3u8"}];
        RDPreviewTestSession *session = [RDPreviewTestSession new];
        RDPreviewTestSetSessions(session, session);
        // Public production entry -> real eligibility -> pinned production branch.
        [RDPreviewController startPreviewForMedia:media policy:nil];
        Check(created == 1, @"public preview entry creates one pinned master task");
        Check(resumed == 1, @"production pinned master task is resumed exactly once");
        printf("PINNED_TASK created=%lu resumed=%lu\n", (unsigned long)created, (unsigned long)resumed);

        // No request reaches NSURLSession/network; both sessions are injected.
        [HTTPPrivacyPolicy setRefererModeOverride:@(HTTPRefererModeNone)];
        Check(RDPreviewTestAssetOptions(media)[RDPreviewHTTPHeaderFieldsKey][@"Referer"] == nil,
              @"None: production AVPlayer options omit Referer");
        completeSynchronously = YES;
        (void)RDPreviewTestResolveURL(@"https://cdn.example/direct.mp4", media);
        Check([requests.lastObject valueForHTTPHeaderField:@"Referer"] == nil,
              @"None: production final-URL request omits Referer");
        completeSynchronously = NO;
        RDPreviewTestPlayPinned(media.parentMediaURL, media.mediaURL, media);
        Check([requests.lastObject valueForHTTPHeaderField:@"Referer"] == nil,
              @"None: production master request omits Referer");
        TestHeaderMatrix();
        TestRedirectHeaders();
        printf("NO_NETWORK_NO_WINDOWS=YES\n");
        printf("PREVIEW-CONTROLLER checks=%lu failed=%lu\n", (unsigned long)checks, (unsigned long)failed);
        return failed ? 1 : 0;
    }
}
