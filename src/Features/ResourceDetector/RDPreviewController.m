//
//  RDPreviewController.m — 视频预览播放编排实现（第 35 轮）
//

#import "RDPreviewController.h"
#import "RDPreviewEligibility.h"
#import "RDPreviewPlaylistRewrite.h"
#import "RDPreviewWindow.h"
#import "DetectedMedia.h"
#import "URLPolicy.h"
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
    _loopbackBody = body;
    if (_loopbackListenFD >= 0) return YES;   // 已在服务，只换响应体
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
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

    // accept 循环：listen fd 被 stopPreview 关闭后 accept 返回 -1，线程随之退出。
    dispatch_async(q, ^{
        for (;;) {
            struct sockaddr_in peer;
            socklen_t plen = sizeof(peer);
            int conn = accept(_loopbackListenFD, (struct sockaddr *)&peer, &plen);
            if (conn < 0) break;
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
            send(conn, resp.bytes, resp.length, 0);
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

// 钉选路径：拉 master → 改写 → 环回 serve → AVPlayer 播环回地址（子请求直连远程）。
static void RDPreviewPlayPinned(NSString *masterURLString, NSString *pinnedURLString,
                                DetectedMedia *media, NSString *title) {
    if (!_masterSession) {
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.HTTPCookieStorage = nil;          // 与探测/下载一致：原生媒体链路无 Cookie
        cfg.HTTPShouldSetCookies = NO;
        _masterSession = [NSURLSession sessionWithConfiguration:cfg];
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
                RDPreviewPlayDirect([NSURL URLWithString:masterURLString], media, title);
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
            RDPreviewPlayDirect([NSURL URLWithString:media.mediaURL], media, title);
            break;
        case RDPreviewDecisionHLSMaster: {
            // 选中变体条目（parentMediaURL 指回 master）→ 钉选；master 条目本身 → 自适应。
            if (media.parentMediaURL.length && ![media.parentMediaURL isEqualToString:media.mediaURL]) {
                RDPreviewPlayPinned(media.parentMediaURL, media.mediaURL, media, title);
            } else {
                RDPreviewPlayDirect([NSURL URLWithString:media.mediaURL], media, title);
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
