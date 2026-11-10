//
//  RDPreviewController.m — 视频预览播放编排实现（第 35 轮）
//

#import "RDPreviewController.h"
#import "RDPreviewEligibility.h"
#import "RDPreviewPlaylistRewrite.h"
#import "RDPreviewWindow.h"
#import "DetectedMedia.h"
#import "URLPolicy.h"
#import "RDTLSTrust.h"
#import "RDCurlHopper.h"
#import "HTTPPrivacyPolicy.h"
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <string.h>
#import <fcntl.h>
#import <poll.h>

// 与 RDThumbnailGenerator 一致：给 AVURLAsset 全部请求（含 HLS 子资源）注入请求头。
// 该 key 为 AVFoundation 非公开但多年稳定的选项，第 35 轮 Spike 实测 HLS 清单/分片/key 均生效。
static NSString * const RDPreviewHTTPHeaderFieldsKey = @"AVURLAssetHTTPHeaderFieldsKey";

// 经典 KVO 观察者（Foundation 无 block 式 KVO 可用）：item failed → 主线程可读报错。
@interface RDPreviewStatusWatcher : NSObject
@property (atomic, copy) void (^onFail)(NSString *message, NSString *title);
@property (nonatomic, copy) NSString *title;
@end
@implementation RDPreviewStatusWatcher
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"status"]) return;
    AVPlayerItem *item = (AVPlayerItem *)object;
    if (item.status != AVPlayerItemStatusFailed) return;
    NSString *msg = item.error.localizedDescription ?: @"预览播放失败（未知错误）";
    NSString *title = self.title;
    void (^onFail)(NSString *, NSString *) = self.onFail;
    // 异步主线程处理：KVO 回调线程不保证主线程，且不在回调栈内注销观察者自身。
    if (onFail) dispatch_async(dispatch_get_main_queue(), ^{ onFail(msg, title); });
}
@end

static RDPreviewStatusWatcher *_statusWatcher = nil;
static AVPlayer *_player = nil;
static NSURLSession *_masterSession = nil;
static URLPolicy *_policy = nil;
static BOOL _playing = NO;
// All playback state is main-thread-owned. Network/KVO callbacks enqueue there.
static NSUInteger _previewGeneration = 0;
static NSURLSessionDataTask *_resolveTask, *_masterTask;
@class RDPreviewRequestContext;
static RDPreviewRequestContext *_resolveContext, *_masterContext;
#if RD_PREVIEW_TESTING
static void (^_testPlayback)(NSURL *, NSDictionary *, NSString *);
static BOOL (^_testLoopback)(NSString *);
#endif

#pragma mark - 证书信任容错会话
//
// 根因（2026-10-12 真实站点实测）：媒体直链落在站点域（www.hanime2.org/jmpres/…）时，
// 该域证书被 Apple 信任评估判为「已吊销」，而 AVPlayer 走系统栈、**无法**接管证书挑战
// （AVURLAsset 没有对应委托），于是预览直接报 TLS -1200/-1202 失败。
//
// 但该直链会 302 到 Cloudflare CDN 域，那个域证书完全正常、AVPlayer 直接可播
// （实测：站点域 playable=失败 / CDN 终跳 playable=可播 duration=910.8s）。
//
// 因此本条修复 = **开播前先把直链解析到终跳地址**，把 302 之后的 CDN 地址交给 AVPlayer。
// 解析用带证书容错的 NSURLSession 做一次 Range: bytes=0-0 的轻量请求（不下载媒体本体），
// 拿 response.URL。普通解析失败仍用输入 URL；URLPolicy 明确拒绝时不绕过策略回退。

@interface RDPreviewRequestContext : NSObject
@property (nonatomic, copy) NSURLRequest *currentRequest;
@property (nonatomic, strong) URLPolicy *policy;
@property (nonatomic, strong) NSError *policyError;
@end
@implementation RDPreviewRequestContext
@end
static char RDPreviewRequestContextKey;

static RDPreviewRequestContext *RDPreviewCreateContext(NSURLRequest *request) {
    RDPreviewRequestContext *context = [RDPreviewRequestContext new];
    context.currentRequest = request;
    context.policy = _policy;
    return context;
}
static NSError *RDPreviewContextError(RDPreviewRequestContext *context) {
    @synchronized (context) { return context.policyError; }
}
static BOOL RDPreviewTrackTask(NSURLSessionDataTask *task, RDPreviewRequestContext *context, NSUInteger generation, BOOL master) {
    // Task creation itself can reenter through an injected/custom transport.
    if (generation != _previewGeneration) { [task cancel]; return NO; }
    objc_setAssociatedObject(task, &RDPreviewRequestContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (master) { _masterTask = task; _masterContext = context; }
    else { _resolveTask = task; _resolveContext = context; }
    [task resume];
    return YES;
}

static void RDPreviewApplySourceHeaders(NSMutableURLRequest *request, DetectedMedia *media) {
    if (media.sourcePageURL.length) [request setValue:media.sourcePageURL forHTTPHeaderField:@"Referer"];
    [HTTPPrivacyPolicy sanitizeMediaRequest:request];
}

@interface RDPreviewTrustDelegate : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate>
@end
@implementation RDPreviewTrustDelegate
- (void)URLSession:(NSURLSession *)session
        didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
        completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if (RDTLSHandleServerTrustChallenge(challenge, @"preview", completionHandler)) return;
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    RDPreviewRequestContext *context = objc_getAssociatedObject(task, &RDPreviewRequestContextKey);
    if (!context) { completionHandler(nil); return; }
    NSMutableURLRequest *next = [request mutableCopy];
    @synchronized (context) {
        URLPolicyDecision *decision = [context.policy evaluateRedirect:next.URL fromURL:context.currentRequest.URL];
        if (decision && !decision.allowed) {
            context.policyError = [NSError errorWithDomain:@"RDPreviewPolicy" code:1
                userInfo:@{NSLocalizedDescriptionKey: decision.userMessage ?: @"该地址未通过安全策略校验"}];
            next = nil;
        } else {
            // Use only the last accepted hop. Secrets stripped by a cross-origin
            // redirect must never be resurrected from the original request.
            [HTTPPrivacyPolicy sanitizeRedirectRequest:next fromRequest:context.currentRequest];
            context.currentRequest = next;
        }
    }
    completionHandler(next);
}
@end

static NSURLSession *_trustSession = nil;
static RDPreviewTrustDelegate *_trustDelegate = nil;

static NSURLSession *RDPreviewTrustSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.HTTPCookieStorage = nil;          // 与探测/下载一致：原生媒体链路无 Cookie
        cfg.HTTPShouldSetCookies = NO;
        cfg.timeoutIntervalForRequest = 8;
        _trustDelegate = [RDPreviewTrustDelegate new];
        _trustSession = [NSURLSession sessionWithConfiguration:cfg
                                                      delegate:_trustDelegate
                                                 delegateQueue:nil];
    });
    return _trustSession;
}

/// Async terminal-URL resolution. Transient failures keep the original direct
/// URL; an explicit URLPolicy rejection never falls back around the policy.
static void RDPreviewResolveFinalURL(NSString *urlString, DetectedMedia *media, NSUInteger generation,
                                    void (^completion)(NSString *, NSError *)) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url.host.length || [url.host isEqualToString:@"127.0.0.1"] || [url.host isEqualToString:@"localhost"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (generation == _previewGeneration) completion(nil, nil); });
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 8;
    req.HTTPMethod = @"GET";
    [req setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
    RDPreviewApplySourceHeaders(req, media);
    RDPreviewRequestContext *context = RDPreviewCreateContext(req);
    NSURLSessionDataTask *task = [RDPreviewTrustSession() dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != _previewGeneration || _resolveContext != context) return;
            _resolveTask = nil; _resolveContext = nil;
            NSError *policyError = RDPreviewContextError(context);
            NSString *final = (!err && !policyError) ? resp.URL.absoluteString : nil;
            completion(final.length && ![final isEqualToString:urlString] ? final : nil, policyError);
        });
    }];
    if (!RDPreviewTrackTask(task, context, generation, NO)) return;
    // Keep a bounded fallback without ever waiting on the UI thread. Identity
    // also suppresses a late timeout/completion after another task has started.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation != _previewGeneration || _resolveContext != context) return;
        NSURLSessionDataTask *pending = _resolveTask;
        _resolveTask = nil; _resolveContext = nil;
        [pending cancel];
        if (generation == _previewGeneration) completion(nil, RDPreviewContextError(context));
    });
}

#pragma mark - 环回钉选服务器

@interface RDPreviewLoopbackServer : NSObject
@property (atomic, assign) BOOL stopped;
@end
@implementation RDPreviewLoopbackServer
@end
static RDPreviewLoopbackServer *_loopbackServer;
static dispatch_queue_t _loopbackQueue = nil;
static int _loopbackListenFD = -1;
static NSString *_loopbackPath = nil;       // /<token>/pinned.m3u8
static NSString *_loopbackBody = nil;       // 改写后的清单文本
static int _loopbackPort = 0;

// 只绑 127.0.0.1、只响应一条改写清单（路径含随机 token）。URLPolicy 对远程 URL 的
// 事前校验发生在启动环回之前；环回本体不出本机、不转发任何媒体数据。
static NSString *RDPreviewLoopbackToken(void) {
    UInt8 bytes[8];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        arc4random_buf(bytes, sizeof(bytes));
    }
    NSMutableString *s = [NSMutableString stringWithCapacity:16];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [s appendFormat:@"%02x", bytes[i]];
    return s;
}

static void RDPreviewLoopbackStop(void) {
    // The worker is the sole FD owner. Closing a listener from another thread
    // permits descriptor reuse; shutdown on a macOS listener is not a reliable
    // wakeup either. A per-server flag + bounded readiness wait avoids both.
    _loopbackServer.stopped = YES;
    _loopbackServer = nil;
    _loopbackListenFD = -1;
    _loopbackPath = nil;
    _loopbackBody = nil;
    _loopbackPort = 0;
}

static void RDPreviewLoopbackFailed(NSUInteger generation) {
    if (generation == _previewGeneration) RDPreviewLoopbackStop();
}

static BOOL RDPreviewLoopbackStart(NSString *body) {
#if RD_PREVIEW_TESTING
    if (_testLoopback) { _loopbackPort = 18765; return _testLoopback(body); }
#endif
    if (_loopbackListenFD >= 0) RDPreviewLoopbackStop();
    _loopbackBody = [body copy];
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    // 客户端在 send 前断开（AVPlayer 快速切换预览的常态）时，macOS 默认处置
    // SIGPIPE 会终止整个进程；本服务器是自管裸 socket，必须自行屏蔽。
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;                        // 随机可用端口
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 4) != 0) {
        close(fd);
        return NO;
    }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return NO; }
    RDPreviewLoopbackServer *server = [RDPreviewLoopbackServer new];
    _loopbackServer = server;
    socklen_t len = sizeof(addr);
    getsockname(fd, (struct sockaddr *)&addr, &len);
    _loopbackPort = ntohs(addr.sin_port);
    _loopbackListenFD = fd;
    _loopbackQueue = dispatch_queue_create("com.sevenzz.miliu.preview-loopback", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t q = _loopbackQueue;
    NSString *servePath = [_loopbackPath copy];
    NSString *serveBody = [_loopbackBody copy];
    NSUInteger generation = _previewGeneration;

    // Each worker captures its own listener/body/path and closes only that FD.
    dispatch_async(q, ^{
        while (!server.stopped) {
            struct pollfd listener = { .fd = fd, .events = POLLIN };
            int ready = poll(&listener, 1, 100);
            if (server.stopped) break;
            if (ready == 0 || (ready < 0 && errno == EINTR)) continue;
            if (ready < 0) {
                dispatch_async(dispatch_get_main_queue(), ^{ RDPreviewLoopbackFailed(generation); });
                break;
            }
            struct sockaddr_in peer;
            socklen_t plen = sizeof(peer);
            int conn = accept(fd, (struct sockaddr *)&peer, &plen);
            if (conn < 0) {
                // 瞬时失败继续服务：BSD 对「进队后被客户端中止」的连接真实返回
                // ECONNABORTED（AVPlayer 快速断开即可触发），EINTR 是信号打断。
                // 其余错误从统一出口收尾，绝不停在「fd 仍开但无人 accept」的
                // 假服务状态（否则后续每次 Start 都直接返回 YES 而预览永挂）。
                if (errno == ECONNABORTED || errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
                dispatch_async(dispatch_get_main_queue(), ^{ RDPreviewLoopbackFailed(generation); });
                break;
            }
            int nosig = 1;
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
            // 无超时的 recv 会让单个不发请求的本地连接卡死整个串行循环。
            int connectionFlags = fcntl(conn, F_GETFL, 0);
            if (connectionFlags >= 0) fcntl(conn, F_SETFL, connectionFlags & ~O_NONBLOCK);
            struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
            setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            char buf[4096];
            size_t got = 0;
            NSDate *requestDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
            while (!server.stopped && got < sizeof(buf) - 1 && requestDeadline.timeIntervalSinceNow > 0) {
                ssize_t n = recv(conn, buf + got, sizeof(buf) - 1 - got, 0);
                if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
                if (n <= 0) break;
                got += (size_t)n;
                if (memmem(buf, got, "\r\n\r\n", 4)) break;
            }
            if (server.stopped) { close(conn); break; }
            // 请求行：GET /path HTTP/1.x（不解析语义——本服务器只认自己发的路径）
            NSString *req = [[NSString alloc] initWithBytesNoCopy:buf length:got
                                                         encoding:NSUTF8StringEncoding freeWhenDone:NO] ?: @"";
            NSString *target = nil;
            NSRange firstSpace = [req rangeOfString:@" "];
            if (firstSpace.location != NSNotFound) {
                NSRange rest = NSMakeRange(firstSpace.location + 1, req.length - firstSpace.location - 1);
                NSRange second = [req rangeOfString:@" " options:0 range:rest];
                if (second.location != NSNotFound)
                    target = [req substringWithRange:NSMakeRange(firstSpace.location + 1,
                                                                 second.location - firstSpace.location - 1)];
            }
            NSData *respBody = [serveBody dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
            NSMutableData *resp = [NSMutableData data];
            if ([target isEqualToString:servePath]) {
                NSString *head = [NSString stringWithFormat:
                    @"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\n"
                    @"Content-Length: %lu\r\nConnection: close\r\n\r\n",
                    (unsigned long)respBody.length];
                [resp appendData:[head dataUsingEncoding:NSUTF8StringEncoding]];
                [resp appendData:respBody];
            } else {
                [resp appendData:[@"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
                                   "Connection: close\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
            }
            // 客户端已断开时的 send 失败是常态：忽略结果、关闭连接即可。
            ssize_t sent = send(conn, resp.bytes, resp.length, 0);
            (void)sent;
            close(conn);
        }
        close(fd);
    });
    return YES;
}

#pragma mark - 播放装配

static void RDPreviewShowError(NSString *reason, NSString *title) {
    NSUInteger generation = _previewGeneration + 1;
    [RDPreviewController stopPreview];
    if (generation == _previewGeneration) [RDPreviewWindow showError:reason ?: @"该资源暂无法预览" title:title];
}

static NSDictionary *RDPreviewAssetOptions(DetectedMedia *media) {
    HTTPRefererMode mode = [HTTPPrivacyPolicy refererMode];
    // AVPlayer propagates asset headers to unknown child hosts and redirects.
    // FullPath cannot be safely scoped per request here, so do not inject it.
    if (mode == HTTPRefererModeNone || mode == HTTPRefererModeFullPath) return @{};
    NSString *referer = [HTTPPrivacyPolicy originForURL:[NSURL URLWithString:media.sourcePageURL ?: @""]];
    if (!referer.length) return @{};
    return @{ RDPreviewHTTPHeaderFieldsKey : @{@"Referer": referer} };
}

static void RDPreviewPlaybackFailed(NSUInteger generation, NSString *message, NSString *title) {
    if (generation == _previewGeneration) RDPreviewShowError(message, title);
}

static void RDPreviewAttach(AVURLAsset *asset, NSString *title) {
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    AVPlayer *p = [AVPlayer playerWithPlayerItem:item];
    _player = p;
    RDPreviewStatusWatcher *watcher = [RDPreviewStatusWatcher new];
    watcher.title = title;
    NSUInteger generation = _previewGeneration;
    watcher.onFail = ^(NSString *message, NSString *reasonTitle) {
        RDPreviewPlaybackFailed(generation, message, reasonTitle);
    };
    [item addObserver:watcher forKeyPath:@"status"
              options:NSKeyValueObservingOptionNew context:NULL];
    _statusWatcher = watcher;
    _playing = YES;
    [RDPreviewWindow attachPlayer:p title:title];
    if (generation == _previewGeneration && _player == p) [p play];
}

static void RDPreviewPlayDirect(NSURL *url, DetectedMedia *media, NSString *title) {
#if RD_PREVIEW_TESTING
    if (_testPlayback) { _playing = YES; _testPlayback(url, RDPreviewAssetOptions(media), title); return; }
#endif
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:RDPreviewAssetOptions(media)];
    RDPreviewAttach(asset, title);
}

/// 直连播放前先解析终跳：站点域证书被吊销时 AVPlayer 会直接 TLS 失败，
/// 而 302 之后的 CDN 域证书正常、可播。解析失败则原样播输入地址（不阻断）。
static void RDPreviewPlayResolvedDirect(NSURL *url, DetectedMedia *media, NSString *title) {
    DetectedMedia *sourceSnapshot = [DetectedMedia new];
    sourceSnapshot.sourcePageURL = media.sourcePageURL;
    media = sourceSnapshot;
    NSUInteger generation = _previewGeneration;
    URLPolicy *policy = _policy;
    RDPreviewResolveFinalURL(url.absoluteString, media, generation, ^(NSString *resolved, NSError *policyError) {
        if (generation != _previewGeneration) return;
        if (policyError) { RDPreviewShowError(policyError.localizedDescription, title); return; }
        NSURL *target = resolved.length ? [NSURL URLWithString:resolved] : url;
        URLPolicyDecision *decision = [policy evaluateTextURL:target.absoluteString];
        if (generation != _previewGeneration) return;
        if (decision && !decision.allowed) { RDPreviewShowError(decision.userMessage, title); return; }
        RDPreviewPlayDirect(target, media, title);
    });
}

// 钉选路径：拉 master → 改写 → 环回 serve → AVPlayer 播环回地址（子请求直连远程）。
static void RDPreviewPlayPinned(NSString *masterURLString, NSString *pinnedURLString,
                                DetectedMedia *media, NSString *title) {
    DetectedMedia *sourceSnapshot = [DetectedMedia new];
    sourceSnapshot.sourcePageURL = media.sourcePageURL;
    media = sourceSnapshot;
    if (!_masterSession) {
        // 信任委托只在 RDPreviewTrustSession() 的 dispatch_once 里创建；钉选路径若
        // 先于直连路径发生，直接用 nil 委托建会话会让被吊销证书的站点首次预览必败，
        // 且 static 会话永不重建。这里先确保委托已存在。
        (void)RDPreviewTrustSession();
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.HTTPCookieStorage = nil;          // 与探测/下载一致：原生媒体链路无 Cookie
        cfg.HTTPShouldSetCookies = NO;
        _masterSession = [NSURLSession sessionWithConfiguration:cfg
                                                       delegate:_trustDelegate
                                                  delegateQueue:nil];
    }
    NSUInteger generation = _previewGeneration;
    URLPolicyDecision *initial = [_policy evaluateTextURL:masterURLString];
    if (generation != _previewGeneration) return;
    if (initial && !initial.allowed) { RDPreviewShowError(initial.userMessage, title); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:masterURLString]];
    req.timeoutInterval = 15;
    RDPreviewApplySourceHeaders(req, media);
    RDPreviewRequestContext *context = RDPreviewCreateContext(req);
    NSURLSessionDataTask *task = [_masterSession dataTaskWithRequest:req
                      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != _previewGeneration || _masterContext != context) return;
            _masterTask = nil; _masterContext = nil;
            NSError *policyError = RDPreviewContextError(context);
            if (policyError) { RDPreviewShowError(policyError.localizedDescription, title); return; }
            NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
            NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            if (err || !text.length || (status && (status < 200 || status >= 300))) {
                NSString *detail = status ? [NSString stringWithFormat:@"HTTP %@", @(status)]
                                          : (err.localizedDescription ?: @"网络错误");
                RDPreviewShowError([NSString stringWithFormat:@"预览清单拉取失败（%@）", detail], title);
                return;
            }
            NSString *baseURL = resp.URL.absoluteString.length ? resp.URL.absoluteString : masterURLString;
            URLPolicyDecision *final = [context.policy evaluateTextURL:baseURL];
            if (generation != _previewGeneration) return;
            if (final && !final.allowed) { RDPreviewShowError(final.userMessage, title); return; }
            RDPreviewPlaylistResult *r = [RDPreviewPlaylistRewrite rewriteMaster:text
                                                                         baseURL:baseURL
                                                              pinnedVariantURL:pinnedURLString];
            if (!r.succeeded || r.remoteURLs.count == 0) {
                // 钉选失败（变体不在清单等）→ 降级直连 master（自适应档位），不谎报钉选生效。
                RDPreviewPlayResolvedDirect([NSURL URLWithString:masterURLString], media, title);
                return;
            }
            for (NSString *u in r.remoteURLs) {
                URLPolicyDecision *d = [context.policy evaluateTextURL:u];
                if (generation != _previewGeneration) return;
                if (d && !d.allowed) {
                    RDPreviewShowError(d.userMessage, title);
                    return;
                }
            }
            _loopbackPath = [NSString stringWithFormat:@"/%@/pinned.m3u8", RDPreviewLoopbackToken()];
            if (!RDPreviewLoopbackStart(r.rewrittenPlaylist)) {
                RDPreviewShowError(@"预览本地服务启动失败", title);
                return;
            }
            if (generation != _previewGeneration) return;
            NSString *pseudo = [NSString stringWithFormat:@"http://127.0.0.1:%d%@", _loopbackPort, _loopbackPath];
            RDPreviewPlayDirect([NSURL URLWithString:pseudo], media, title);
        });
    }];
    RDPreviewTrackTask(task, context, generation, YES);
}

#if defined(RD_PREVIEW_TESTING)
// Test-only boundary injection; compile this .m normally rather than importing
// it as a header. No player/window/network algorithm is duplicated in tests.
void RDPreviewTestSetBoundaries(void (^playback)(NSURL *, NSDictionary *, NSString *), BOOL (^loopback)(NSString *)) {
    _testPlayback = [playback copy]; _testLoopback = [loopback copy];
}
void RDPreviewTestUseLocalSessions(void) {
    (void)RDPreviewTrustSession();
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.connectionProxyDictionary = @{};
    cfg.HTTPCookieStorage = nil;
    cfg.HTTPShouldSetCookies = NO;
    cfg.URLCredentialStorage = nil;
    cfg.URLCache = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:_trustDelegate delegateQueue:nil];
    _masterSession = session;
    _trustSession = session;
}
void RDPreviewTestSetSessions(id master, id trust) {
    (void)RDPreviewTrustSession();
    _masterSession = master;
    _trustSession = trust;
}
NSURLRequest *RDPreviewTestRedirect(id task, NSURLRequest *request) {
    __block NSURLRequest *result = nil;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [_trustDelegate URLSession:RDPreviewTrustSession() task:task willPerformHTTPRedirection:response newRequest:request
             completionHandler:^(NSURLRequest *next) { result = next; }];
    return result;
}
void RDPreviewTestRegisterRequest(id task, NSURLRequest *request) {
    objc_setAssociatedObject(task, &RDPreviewRequestContextKey, RDPreviewCreateContext(request), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
NSDictionary *RDPreviewTestAssetOptions(DetectedMedia *media) { return RDPreviewAssetOptions(media); }
NSString *RDPreviewTestResolveURL(NSString *url, DetectedMedia *media) {
    __block BOOL done = NO;
    __block NSString *result = nil;
    RDPreviewResolveFinalURL(url, media, _previewGeneration, ^(NSString *value, NSError *error) { result = value; done = YES; });
    // Only the synchronous fixture bridge spins a run loop; production never waits.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.2];
    while (!done && deadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    return result;
}
NSUInteger RDPreviewTestPlaybackGeneration(void) { return _previewGeneration; }
void RDPreviewTestLoopbackFailed(NSUInteger generation) { RDPreviewLoopbackFailed(generation); }
void RDPreviewTestPlaybackFailure(NSUInteger generation) { RDPreviewPlaybackFailed(generation, @"fixture failure", @"fixture"); }
NSURL *RDPreviewTestStartLoopback(NSString *body) {
    [RDPreviewController stopPreview];
    _testLoopback = nil;
    _loopbackPath = [NSString stringWithFormat:@"/%@/pinned.m3u8", RDPreviewLoopbackToken()];
    if (!RDPreviewLoopbackStart(body)) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d%@", _loopbackPort, _loopbackPath]];
}
void RDPreviewTestPlayPinned(NSString *master, NSString *variant, DetectedMedia *media) {
    RDPreviewPlayPinned(master, variant, media, @"isolated fixture");
}
#endif

#pragma mark - 对外接口

@implementation RDPreviewController

+ (void)startPreviewForMedia:(nullable DetectedMedia *)media policy:(nullable URLPolicy *)policy {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startPreviewForMedia:media policy:policy]; });
        return;
    }
    NSUInteger generation = _previewGeneration + 1;
    [self stopPreview];                        // 换条目/重播前先回收旧播放与环回
    if (generation != _previewGeneration) return; // A reentrant newer start wins.
    _policy = policy;
    NSString *title = media.title.length ? media.title : nil;
    RDPreviewVerdict *v = [RDPreviewEligibility verdictForMedia:media];
    if (v.decision == RDPreviewDecisionRefused) {
        RDPreviewShowError(v.refusalReason, title);
        return;
    }
    URLPolicyDecision *d = [policy evaluateTextURL:media.mediaURL];
    if (generation != _previewGeneration) return;
    if (d && !d.allowed) {
        RDPreviewShowError(d.userMessage, title);
        return;
    }
    _playing = YES; // Includes preparation, so a quality switch can cancel it.
    switch (v.decision) {
        case RDPreviewDecisionDirectFile:
        case RDPreviewDecisionHLSMedia:
            RDPreviewPlayResolvedDirect([NSURL URLWithString:media.mediaURL], media, title);
            break;
        case RDPreviewDecisionHLSMaster: {
            // 选中变体条目（parentMediaURL 指回 master）→ 钉选；master 条目本身 → 自适应。
            if (media.parentMediaURL.length && ![media.parentMediaURL isEqualToString:media.mediaURL]) {
                RDPreviewPlayPinned(media.parentMediaURL, media.mediaURL, media, title);
            } else {
                RDPreviewPlayResolvedDirect([NSURL URLWithString:media.mediaURL], media, title);
            }
            break;
        }
        case RDPreviewDecisionRefused:
            break;
    }
}

+ (void)stopPreview {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self stopPreview]; }); return; }
    ++_previewGeneration;
    NSURLSessionDataTask *resolve = _resolveTask, *master = _masterTask;
    _resolveTask = nil; _masterTask = nil;
    _resolveContext = nil; _masterContext = nil;
    _policy = nil;
    // 先注销 KVO 再释放 item：对象带活跃观察者释放会崩溃。
    AVPlayerItem *oldItem = _player.currentItem;
    if (oldItem && _statusWatcher) {
        [oldItem removeObserver:_statusWatcher forKeyPath:@"status"];
    }
    [_player pause];
    [_player replaceCurrentItemWithPlayerItem:nil];
    _player = nil;
    _playing = NO;
    _statusWatcher.onFail = nil;
    _statusWatcher = nil;
    RDPreviewLoopbackStop();
    // Cleanup precedes cancel: cancellation can synchronously reenter/start a
    // newer preview, which the remainder of this stop must not tear down.
    [resolve cancel];
    [master cancel];
}

+ (BOOL)isPreviewActive {
    return _playing;
}

@end
