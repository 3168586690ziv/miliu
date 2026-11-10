// Real production controller, NSURLSession, loopback server and AVPlayer decoding.
// Only window reception and the policy's fixed local fixture allowlist are replaced.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "RDPreviewController.h"
#import "RDPreviewWindow.h"
#import "DetectedMedia.h"
#import "HTTPPrivacyPolicy.h"
extern void RDPreviewTestUseLocalSessions(void);
static int gPassed, gFailed;
static AVPlayer *receivedPlayer;
static NSString *playbackError;
static NSString *fixturePort;
static void Check(BOOL ok, NSString *msg) {
    if (ok) gPassed++; else gFailed++;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", msg.UTF8String);
}
NSString *const RDPreviewWindowDidCloseNotification = @"RDPreviewWindowDidClose";
@implementation RDPreviewWindow
+ (void)attachPlayer:(AVPlayer *)player title:(NSString *)title {
    // The production controller calls this BEFORE play. Never create any window.
    player.muted = YES;
    receivedPlayer = player;
}
+ (void)showError:(NSString *)message title:(NSString *)title { playbackError = message; }
+ (void)close {}
@end
@interface LocalDecision : NSObject
@property(nonatomic) BOOL allowed;
@property(nonatomic,copy) NSString *userMessage;
@end
@implementation LocalDecision
@end
@interface LocalFixturePolicy : NSObject
- (id)evaluateTextURL:(NSString *)text;
- (id)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current;
@end
@implementation LocalFixturePolicy
- (id)evaluateTextURL:(NSString *)text {
    NSURL *url = [NSURL URLWithString:text];
    LocalDecision *d = [LocalDecision new];
    d.allowed = [url.scheme isEqual:@"http"] && [url.host isEqual:@"127.0.0.1"] &&
        [url.port.stringValue isEqual:fixturePort] && !url.user.length && !url.password.length;
    d.userMessage = @"E2E permits only this run's fixed loopback fixture";
    return d;
}
- (id)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current { return [self evaluateTextURL:target.absoluteString]; }
@end
static NSString *ReadLog(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
}
static int Count(NSString *text, NSString *needle) {
    return (int)[text componentsSeparatedByString:needle].count - 1;
}
static void Pump(NSTimeInterval duration) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:duration];
    while (end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}
static NSString *Play(NSString *path, BOOL pinned, NSString *logPath, NSString **delta) {
    [RDPreviewController stopPreview]; receivedPlayer = nil; playbackError = nil;
    Pump(0.2); // Drain old callbacks before this scenario's log boundary.
    NSUInteger start = ReadLog(logPath).length;
    NSString *base = [NSString stringWithFormat:@"http://127.0.0.1:%@/", fixturePort];
    DetectedMedia *media = [DetectedMedia new];
    media.title = path; media.format = [path hasSuffix:@"mp4"] ? @"mp4" : @"hls";
    media.mediaURL = [base stringByAppendingString:path];
    media.sourcePageURL = [base stringByAppendingString:@"page.html?private=FIXTURE_ONLY#fragment"];
    if (pinned) {
        media.parentMediaURL = [base stringByAppendingString:@"av-master.m3u8"];
        media.declaredVariants = @[@{@"url":media.mediaURL}, @{@"url":[base stringByAppendingString:@"av480.m3u8"]}];
    }
    [RDPreviewController startPreviewForMedia:media policy:(id)[LocalFixturePolicy new]];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    NSString *result = @"TIMEOUT";
    while (deadline.timeIntervalSinceNow > 0) {
        if (playbackError.length) { result = [@"FAILED: " stringByAppendingString:playbackError]; break; }
        if (receivedPlayer.currentItem.status == AVPlayerItemStatusFailed) {
            result = [NSString stringWithFormat:@"FAILED: %@", receivedPlayer.currentItem.error]; break;
        }
        double time = receivedPlayer ? CMTimeGetSeconds(receivedPlayer.currentTime) : 0;
        if (time >= 1.0) { result = [NSString stringWithFormat:@"OK %.2f", time]; break; }
        Pump(0.05);
    }
    Check(receivedPlayer && receivedPlayer.muted, [path stringByAppendingString:@": real player muted before play"]);
    if (pinned && receivedPlayer) {
        NSURL *assetURL = [(AVURLAsset *)receivedPlayer.currentItem.asset URL];
        Check([assetURL.host isEqual:@"127.0.0.1"] && ![assetURL.port.stringValue isEqual:fixturePort], @"pinned uses production random-port loopback, not fixture prewritten master");
    }
    [RDPreviewController stopPreview]; receivedPlayer = nil;
    Pump(0.2);
    NSString *whole = ReadLog(logPath);
    *delta = whole.length >= start ? [whole substringFromIndex:start] : @"";
    return result;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        fixturePort = @(argv[1]); NSString *logPath = @(argv[2]);
        [HTTPPrivacyPolicy setRefererModeOverride:@(HTTPRefererModeOrigin)];
        RDPreviewTestUseLocalSessions();
        NSArray *paths = @[@"direct.mp4", @"av-master.m3u8", @"av720.m3u8", @"av-enc.m3u8"];
        NSArray *labels = @[@"direct mp4", @"adaptive two-variant HLS", @"production pinned HLS", @"AES-128 decrypted HLS"];
        for (NSUInteger i = 0; i < paths.count; i++) {
            NSString *delta = nil;
            NSString *result = Play(paths[i], i == 2, logPath, &delta);
            Check([result hasPrefix:@"OK"], [NSString stringWithFormat:@"%@ time advances (%@)", labels[i], result]);
            NSString *origin = [NSString stringWithFormat:@"Referer=http://127.0.0.1:%@", fixturePort];
            int requests = 0, valid = 0;
            for (NSString *line in [delta componentsSeparatedByString:@"\n"]) {
                if (![line containsString:@"HTTP: GET"]) continue;
                requests++;
                if ([line hasSuffix:origin]) valid++;
            }
            Check(requests > 0 && valid == requests, [NSString stringWithFormat:@"%@: ALL %d requests have origin-only Referer (%d valid)", labels[i], requests, valid]);
            Check(![delta containsString:@"private=FIXTURE_ONLY"], @"source path/query never leaks in Referer");
            if (i == 2) {
                Check(Count(delta, @"/avseg480") == 0, @"pinned scenario: 480p zero requests (isolated log delta)");
                Check(Count(delta, @"/avseg720") > 0, @"pinned scenario: 720p segments fetched");
                Check(Count(delta, @"/av480.m3u8") == 0, @"pinned scenario: other variant playlist zero requests");
                Check(Count(delta, @"/av-master.m3u8") > 0, @"pinned scenario actually fetches production master");
            }
            if (i == 3) Check(Count(delta, @"/enc.key") > 0, @"AES-128 scenario actually fetched key");
        }
        printf("REAL_CONTROLLER_AVPLAYER_E2E passed=%d failed=%d NO_WINDOWS=YES MUTED=YES\n", gPassed, gFailed);
        return gFailed ? 1 : 0;
    }
}
