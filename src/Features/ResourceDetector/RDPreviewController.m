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
#import <AVFoundation/AVFoundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <string.h>

// 与 RDThumbnailGenerator 一致：给 AVURLAsset 全部请求（含 HLS 子资源）注入请求头。
// 该 key 为 AVFoundation 非公开但多年稳定的选项，第 35 轮 Spike 实测 HLS 清单/分片/key 均生效。
static NSString * const RDPreviewHTTPHeaderFieldsKey = @"AVURLAssetHTTPHeaderFieldsKey";

// 经典 KVO 观察者（Foundation 无 block 式 KVO 可用）：item failed → 主线程可读报错。
@interface RDPreviewStatusWatcher : NSObject
@property (nonatomic, copy) void (^onFail)(NSString *message, NSString *title);
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
    dispatch_async(dispatch_get_main_queue(), ^{ onFail(msg, title); });
}
@end

static RDPreviewStatusWatcher *_statusWatcher = nil;
static AVPlayer *_player = nil;
static NSURLSession *_masterSession = nil;
static URLPolicy *_policy = nil;
static BOOL _playing = NO;

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
// 拿 response.URL。解析失败时原样使用输入 URL（行为与修复前一致，绝不让预览变得更差）。

@interface RDPreviewTrustDelegate : NSObject <NSURLSessionDelegate>
@end
@implementation RDPreviewTrustDelegate
- (void)URLSession:(NSURLSession *)session
        didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
        completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if (RDTLSHandleServerTrustChallenge(challenge, @"preview", completionHandler)) return;
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
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

/// 把媒体地址解析到重定向终跳。返回 nil 表示「无需改写或解析失败」——
/// 调用方应当继续用原地址（绝不因为解析失败而阻断预览）。
static NSString *RDPreviewResolveFinalURL(NSString *urlString, DetectedMedia *media) {
    if (!urlString.length) return nil;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url.host.length) return nil;
    // 环回地址（钉选路径的伪 URL）本来就是本机、无重定向可言。
    if ([url.host isEqualToString:@"127.0.0.1"] || [url.host isEqualToString:@"localhost"]) return nil;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 8;
    req.HTTPMethod = @"GET";
    [req setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
    if (media.sourcePageURL.length) [req setValue:media.sourcePageURL forHTTPHeaderField:@"Referer"];

    __block NSString *finalURLString = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [RDPreviewTrustSession() dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        // 只看终跳地址：状态码/正文一概不采信（这一步只为拿到重定向后的 host）。
        if (!err && resp.URL.absoluteString.length) finalURLString = resp.URL.absoluteString;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    // 预览是用户主动触发的动作，短暂等待可接受；超时则原样继续（不阻断）。
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC)) != 0) {
        [task cancel];
        return nil;
    }
    if (!finalURLString.length) return nil;
    if ([finalURLString isEqualToString:urlString]) return nil;   // 无重定向：不改写
    return finalURLString;
}

#pragma mark - 环回钉选服务器

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
    if (_loopbackListenFD >= 0) {
        shutdown(_loopbackListenFD, SHUT_RDWR);
        close(_loopbackListenFD);
        _loopbackListenFD = -1;
    }
    _loopbackPath = nil;
    _loopbackBody = nil;
    _loopbackPort = 0;
}

static BOOL RDPreviewLoopbackStart(NSString *body) {
    if (_loopbackListenFD >= 0) {
        // 已在服务，只换响应体。写操作投递到 accept 循环所在的串行队列，
        // 与循环内的读操作串行化，消除跨线程裸读写（2026-10-24 审计）。
        dispatch_queue_t q = _loopbackQueue;
        if (q) dispatch_async(q, ^{ _loopbackBody = body; });
        else _loopbackBody = body;
        return YES;
    }
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
    socklen_t len = sizeof(addr);
    getsockname(fd, (struct sockaddr *)&addr, &len);
    _loopbackPort = ntohs(addr.sin_port);
    _loopbackListenFD = fd;
    _loopbackQueue = dispatch_queue_create("com.sevenzz.miliu.preview-loopback", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t q = _loopbackQueue;

    // accept 循环：listen fd 被 stopPreview 关闭（shutdown 使 accept 以 EINVAL
    // 失败）后线程随之退出。
    dispatch_async(q, ^{
        for (;;) {
            struct sockaddr_in peer;
            socklen_t plen = sizeof(peer);
            int conn = accept(_loopbackListenFD, (struct sockaddr *)&peer, &plen);
            if (conn < 0) {
                // 瞬时失败继续服务：BSD 对「进队后被客户端中止」的连接真实返回
                // ECONNABORTED（AVPlayer 快速断开即可触发），EINTR 是信号打断。
                // 其余错误从统一出口收尾，绝不停在「fd 仍开但无人 accept」的
                // 假服务状态（否则后续每次 Start 都直接返回 YES 而预览永挂）。
                if (errno == ECONNABORTED || errno == EINTR) continue;
                dispatch_async(dispatch_get_main_queue(), ^{ RDPreviewLoopbackStop(); });
                break;
            }
            int nosig = 1;
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
            // 无超时的 recv 会让单个不发请求的本地连接卡死整个串行循环。
            struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
            setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            char buf[4096];
            size_t got = 0;
            while (got < sizeof(buf) - 1) {
                ssize_t n = recv(conn, buf + got, sizeof(buf) - 1 - got, 0);
                if (n <= 0) break;
                got += (size_t)n;
                if (memmem(buf, got, "\r\n\r\n", 4)) break;
            }
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
            NSData *respBody = [_loopbackBody dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
            NSMutableData *resp = [NSMutableData data];
            if ([target isEqualToString:_loopbackPath]) {
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
    });
    return YES;
}

#pragma mark - 播放装配

static void RDPreviewShowError(NSString *reason, NSString *title) {
    [RDPreviewController stopPreview];
    [RDPreviewWindow showError:reason ?: @"该资源暂无法预览" title:title];
}

static NSDictionary *RDPreviewAssetOptions(DetectedMedia *media) {
    NSString *referer = media.sourcePageURL;
    if (!referer.length) return @{};
    return @{ RDPreviewHTTPHeaderFieldsKey : @{@"Referer": referer} };
}

static void RDPreviewAttach(AVURLAsset *asset, NSString *title) {
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    AVPlayer *p = [AVPlayer playerWithPlayerItem:item];
    _player = p;
    RDPreviewStatusWatcher *watcher = [RDPreviewStatusWatcher new];
    watcher.title = title;
    watcher.onFail = ^(NSString *message, NSString *reasonTitle) {
        RDPreviewShowError(message, reasonTitle);
    };
    [item addObserver:watcher forKeyPath:@"status"
              options:NSKeyValueObservingOptionNew context:NULL];
    _statusWatcher = watcher;
    [RDPreviewWindow attachPlayer:p title:title];
    _playing = YES;
    [p play];
}

static void RDPreviewPlayDirect(NSURL *url, DetectedMedia *media, NSString *title) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:RDPreviewAssetOptions(media)];
    RDPreviewAttach(asset, title);
}

/// 直连播放前先解析终跳：站点域证书被吊销时 AVPlayer 会直接 TLS 失败，
/// 而 302 之后的 CDN 域证书正常、可播。解析失败则原样播输入地址（不阻断）。
static void RDPreviewPlayResolvedDirect(NSURL *url, DetectedMedia *media, NSString *title) {
    NSString *resolved = RDPreviewResolveFinalURL(url.absoluteString, media);
    NSURL *target = resolved.length ? [NSURL URLWithString:resolved] : url;
    if (resolved.length) NSLog(@"[preview] 直链已解析到终跳 host=%@", target.host ?: @"-");
    RDPreviewPlayDirect(target, media, title);
}

// 钉选路径：拉 master → 改写 → 环回 serve → AVPlayer 播环回地址（子请求直连远程）。
static void RDPreviewPlayPinned(NSString *masterURLString, NSString *pinnedURLString,
                                DetectedMedia *media, NSString *title) {
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
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:masterURLString]];
    req.timeoutInterval = 15;
    if (media.sourcePageURL.length) [req setValue:media.sourcePageURL forHTTPHeaderField:@"Referer"];
    [_masterSession dataTaskWithRequest:req
                      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSInteger status = [(NSHTTPURLResponse *)resp statusCode];
            NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            if (!text.length || (status && (status < 200 || status >= 300))) {
                NSString *detail = status ? [NSString stringWithFormat:@"HTTP %@", @(status)]
                                          : (err.localizedDescription ?: @"网络错误");
                RDPreviewShowError([NSString stringWithFormat:@"预览清单拉取失败（%@）", detail], title);
                return;
            }
            RDPreviewPlaylistResult *r = [RDPreviewPlaylistRewrite rewriteMaster:text
                                                                         baseURL:masterURLString
                                                              pinnedVariantURL:pinnedURLString];
            if (!r.succeeded || r.remoteURLs.count == 0) {
                // 钉选失败（变体不在清单等）→ 降级直连 master（自适应档位），不谎报钉选生效。
                RDPreviewPlayResolvedDirect([NSURL URLWithString:masterURLString], media, title);
                return;
            }
            for (NSString *u in r.remoteURLs) {
                URLPolicyDecision *d = [_policy evaluateTextURL:u];
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
            NSString *pseudo = [NSString stringWithFormat:@"http://127.0.0.1:%d%@", _loopbackPort, _loopbackPath];
            RDPreviewPlayDirect([NSURL URLWithString:pseudo], media, title);
        });
    }];
}

#pragma mark - 对外接口

@implementation RDPreviewController

+ (void)startPreviewForMedia:(nullable DetectedMedia *)media policy:(nullable URLPolicy *)policy {
    _policy = policy;
    [self stopPreview];                        // 换条目/重播前先回收旧播放与环回
    NSString *title = media.title.length ? media.title : nil;
    RDPreviewVerdict *v = [RDPreviewEligibility verdictForMedia:media];
    if (v.decision == RDPreviewDecisionRefused) {
        RDPreviewShowError(v.refusalReason, title);
        return;
    }
    URLPolicyDecision *d = [policy evaluateTextURL:media.mediaURL];
    if (d && !d.allowed) {
        RDPreviewShowError(d.userMessage, title);
        return;
    }
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
}

+ (BOOL)isPreviewActive {
    return _playing;
}

@end
