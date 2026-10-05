//
//  RealBodyScanTests.m — 注入脚本「接口响应体媒体链接扫描」真实 WebKit 端到端测试
//
//  场景（2026-10-05 第 21 轮）：媒体链接只出现在 fetch/XHR 接口的响应体里，页面本身
//  从不请求这些媒体地址 —— 因此 media 列表里出现 cdn.example.com 链接只可能来自
//  响应体扫描（旧钩子只按「请求 URL」分类，绝不可能看到它们）。
//  服务器夹具：fixtures/body_scan_server.py（见文件头路由说明）。
//

#import <Cocoa/Cocoa.h>
#import "WebProbe.h"
#import "URLPolicy.h"
#import "DNSResolver.h"
#import "DetectedMedia.h"

// 与 RealSiteProbe.m 的夹具策略同构：仅放行解析到 127.0.0.1 的目标（SSRF 防线原样保留）。
@interface BSLoopbackFixturePolicy : URLPolicy
@end
@implementation BSLoopbackFixturePolicy
- (BOOL)rd_isLoopbackFixtureURL:(NSURL *)url {
    if ([url.host isEqualToString:@"127.0.0.1"] || [url.host isEqualToString:@"localhost"]) return YES;
    NSArray<NSString *> *ips = [DNSResolver resolveIPsForHost:url.host];
    return ips.count == 1 && [ips.firstObject isEqualToString:@"127.0.0.1"];
}
- (URLPolicyDecision *)evaluateTextURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    return [self rd_isLoopbackFixtureURL:url] ? [URLPolicyDecision allow] : [super evaluateTextURL:urlString];
}
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips {
    return [self rd_isLoopbackFixtureURL:url] ? [URLPolicyDecision allow] : [super evaluateResolvedURL:url resolvedIPs:ips];
}
- (URLPolicyDecision *)evaluateResolvedURL:(NSURL *)url resolvedIPs:(NSArray<NSString *> *)ips
                          resolutionStatus:(DNSResolutionStatus)status {
    return [self rd_isLoopbackFixtureURL:url] ? [URLPolicyDecision allow] : [super evaluateResolvedURL:url resolvedIPs:ips resolutionStatus:status];
}
- (URLPolicyDecision *)evaluateRedirect:(NSURL *)target fromURL:(NSURL *)current {
    return [self rd_isLoopbackFixtureURL:target] ? [URLPolicyDecision allow] : [super evaluateRedirect:target fromURL:current];
}
@end

static int failures;
static void check(BOOL ok, const char *name) { printf("%s %s\n", ok ? "PASS" : "FAIL", name); if (!ok) failures++; }

static BOOL mediaListHasURL(NSArray<DetectedMedia *> *media, NSString *needle, NSString **foundSource) {
    for (DetectedMedia *m in media) {
        if ([m.mediaURL containsString:needle]) {
            if (foundSource) *foundSource = m.discoverySource;
            return YES;
        }
    }
    return NO;
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *base = NSProcessInfo.processInfo.environment[@"RD_BODYSCAN_HTTP"];
    if (!base.length) { printf("FAIL missing RD_BODYSCAN_HTTP\n"); return 1; }
    NSURL *pageURL = [NSURL URLWithString:[base stringByAppendingString:@"/"]];

    WebProbe *probe = [[WebProbe alloc] initWithPolicy:[BSLoopbackFixturePolicy new]];
    __block RDProbeResult *result = nil;
    [probe probeURL:pageURL.absoluteString
         completion:^(RDProbeResult *r, AppError *error, NSUInteger gen) {
             (void)error; (void)gen;
             result = r;
         }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
    while (!result && deadline.timeIntervalSinceNow > 0) {
        usleep(100000);
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    }
    if (!result) { printf("FAIL probe timed out\n"); return 1; }
    NSArray<DetectedMedia *> *media = result.media ?: @[];
    printf("RS-MEDIA %lu 条\n", (unsigned long)media.count);

    NSString *source = nil;
    check(mediaListHasURL(media, @"master.m3u8", &source), "m3u8 link inside fetch JSON body discovered");
    check(source && [source containsString:@"fetch_body"], "m3u8 discovery source is fetch_body");
    source = nil;
    check(mediaListHasURL(media, @"movie.mp4", &source), "mp4 link inside fetch JSON body discovered");
    source = nil;
    check(mediaListHasURL(media, @"clip2.webm", &source), "webm link inside XHR text body discovered");
    check(source && [source containsString:@"xhr_body"], "webm discovery source is xhr_body");
    check(!mediaListHasURL(media, @"too-big.mp4", NULL), "over-size response body is NOT scanned (3MB guard)");
    // 二分诊断锚点：页面静态直链必须被发现——否则问题不在响应体扫描层。
    check(mediaListHasURL(media, @"/direct/v.mp4", NULL), "static <video> direct link discovered (control anchor)");

    printf("%s\n", failures == 0 ? "ALL PASS" : "HAS FAILURES");
    return failures == 0 ? 0 : 1;
}}
