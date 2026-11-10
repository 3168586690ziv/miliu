#import <Foundation/Foundation.h>
#import "RDFailureDiagnosis.h"
static NSUInteger checks, failed;
static void Check(NSString *reason, NSInteger status, RDFailureAction expected, NSString *name) {
    checks++;
    RDFailureAction actual = RDDiagnoseFailure(reason, status).action;
    printf("%s: %s status=%ld expected=%ld actual=%ld\n", actual == expected ? "PASS" : "FAIL", name.UTF8String, (long)status, (long)expected, (long)actual);
    if (actual != expected) failed++;
}
int main(void) { @autoreleasepool {
    Check(@"HTTP 请求失败", 401, RDFailureActionSignIn, @"structured 401 without text code");
    Check(nil, 401, RDFailureActionSignIn, @"structured 401 without reason");
    Check(@"网络错误（请求 ID=404123）", 0, RDFailureActionRetry, @"request ID is not HTTP 404");
    Check(@"网络错误（请求 ID=140410）", 0, RDFailureActionRetry, @"numeric substring is not HTTP 410");
    Check(@"请求编号 42901 失败", 0, RDFailureActionNone, @"numeric substring is not HTTP 429");
    Check(@"请求编号 50300 失败", 0, RDFailureActionNone, @"numeric substring is not HTTP 503");
    Check(@"下载失败: https://cdn.example/author/video.mp4", 500, RDFailureActionNone, @"author path is not auth");
    Check(@"网络错误 https://cdn.example/auth/video.mp4", 0, RDFailureActionRetry, @"URL auth path is not login evidence");
    Check(@"下载失败 https://cdn.example/404/video.mp4?status=401", 0, RDFailureActionNone, @"URL path and query are not status evidence");
    Check(@"下载失败 https://login.example/private%20video.mp4", 0, RDFailureActionNone, @"URL hostname is not login evidence");
    Check(@"下载失败（authoritative response）", 0, RDFailureActionNone, @"authoritative is not auth");
    Check(@"HTTP 404", 0, RDFailureActionRefreshLink, @"HTTP 404 textual fallback");
    Check(@"网站返回 410", 0, RDFailureActionRefreshLink, @"Chinese HTTP textual fallback");
    Check(@"HTTP/1.1 401 Unauthorized", 0, RDFailureActionSignIn, @"HTTP version textual fallback");
    Check(@"状态码：429", 0, RDFailureActionWaitAndRetry, @"explicit status code textual fallback");
    Check(@"HTTP 404123", 0, RDFailureActionNone, @"HTTP-prefixed longer number is not status");
    Check(@"HTTP 4012", 0, RDFailureActionNone, @"HTTP-prefixed 4012 is not status");
    Check(@"HTTP 403", 404, RDFailureActionRefreshLink, @"structured 404 wins conflicting text");
    Check(@"HTTP 404", 429, RDFailureActionWaitAndRetry, @"structured 429 wins conflicting text");
    Check(@"HTTP 404", 401, RDFailureActionSignIn, @"structured 401 wins conflicting text");
    Check(@"authentication required", 403, RDFailureActionSignIn, @"explicit auth requirement specializes 403");
    Check(@"这是会员专属内容，HTTP 403", 403, RDFailureActionSignIn, @"existing membership 403 specialization");
    Check(@"需要登录后才能访问", 0, RDFailureActionSignIn, @"Chinese sign-in evidence retained");
    Check(@"Unauthorized", 0, RDFailureActionSignIn, @"whole unauthorized token retained");
    Check(@"sign in required", 0, RDFailureActionSignIn, @"whole sign-in phrase retained");
    Check(@"Forbidden", 0, RDFailureActionRefreshLink, @"Forbidden token retained");
    Check(@"Cloudflare 人机验证", 0, RDFailureActionWaitAndRetry, @"anti-bot evidence retained");
    Check(@"No space left on device", 401, RDFailureActionFreeDiskSpace, @"local disk cause remains highest priority");
    Check(@"保存的内容是网页/错误页，不是视频文件", 0, RDFailureActionRefreshLink, @"non-media evidence retained");
    Check(@"下载不完整：服务器声明 100 字节", 0, RDFailureActionRetry, @"incomplete transfer retained");
    Check(@"链接已过期", 0, RDFailureActionRefreshLink, @"expired semantic evidence retained");
    Check(@"完全没见过的错误", 0, RDFailureActionNone, @"unknown stays unknown");
    Check(nil, 0, RDFailureActionNone, @"nil stays unknown");
    printf("FAILURE-PRECISION checks=%lu failed=%lu\n", (unsigned long)checks, (unsigned long)failed);
    return failed ? 1 : 0;
} }
