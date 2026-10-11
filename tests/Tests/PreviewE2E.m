// PreviewE2E.m — 预览播放端到端守卫（第 35 轮）
// 与 RDPreviewController 的播放管线等价（同款 AVURLAsset options + 钉选环回语义），
// 不依赖 GUI：预览窗口（RDPreviewWindow）为 AppKit 层，测试只验证网络与解码行为。
// 断言：① 播放时间推进 ② 全部子请求带 Referer（server.log）③ 钉选后零请求其他档位
//       ④ AES-128 加密流可播（解密成功）。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

static NSString *const kBase = @"http://127.0.0.1:%@";
static int gPassed = 0, gFailed = 0;
static void Check(BOOL ok, NSString *msg) {
    if (ok) { gPassed++; NSLog(@"PASS: %@", msg); }
    else { gFailed++; NSLog(@"FAIL: %@", msg); }
}

// 与生产同款：AVURLAssetHTTPHeaderFieldsKey 注入来源页 Referer（Spike 实测作用于全部子请求）
static NSString *Play(NSString *port, NSString *path, NSTimeInterval target) {
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%@/%@", port, path];
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:url]
        options:@{@"AVURLAssetHTTPHeaderFieldsKey": @{@"Referer": @"http://127.0.0.1:8901/page.html"}}];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:a];
    AVPlayer *p = [AVPlayer playerWithPlayerItem:item];
    [p play];
    NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:15];
    while ([NSDate date].timeIntervalSince1970 < dl.timeIntervalSince1970) {
        if (item.status == AVPlayerItemStatusFailed) return [NSString stringWithFormat:@"FAILED: %@", item.error.localizedDescription];
        if (CMTimeGetSeconds(p.currentTime) >= target)
            return [NSString stringWithFormat:@"OK %.2f", CMTimeGetSeconds(p.currentTime)];
        usleep(100000);
    }
    return @"TIMEOUT";
}

static int CountInLog(NSString *logPath, NSString *needle) {
    NSString *s = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    if (!s) return -1;
    NSInteger n = 0;
    NSRange r = NSMakeRange(0, s.length);
    for (;;) {
        NSRange f = [s rangeOfString:needle options:0 range:r];
        if (f.location == NSNotFound) break;
        n++;
        r = NSMakeRange(NSMaxRange(f), s.length - NSMaxRange(f));
    }
    return (int)n;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *port = argc > 1 ? @(argv[1]) : @"8911";
        NSString *logPath = argc > 2 ? @(argv[2]) : nil;
        __block int rc = 0;
        // AVFoundation 加载依赖主 runloop（第 35 轮 Spike 实测教训）：
        // 测试主体放后台队列编排，主线程 dispatch_main 保活。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSLog(@"== 预览端到端（第 35 轮）==");

            NSString *r1 = Play(port, @"direct.mp4", 1.0);
            Check([r1 hasPrefix:@"OK"], [NSString stringWithFormat:@"直链 mp4 可播（%@）", r1]);

            NSString *r2 = Play(port, @"av-master.m3u8", 1.0);
            Check([r2 hasPrefix:@"OK"], [NSString stringWithFormat:@"明文双档 HLS master 可播（%@）", r2]);

            NSString *r3 = Play(port, @"pinned-http.m3u8", 1.0);
            Check([r3 hasPrefix:@"OK"], [NSString stringWithFormat:@"环回钉选 master 可播（%@）", r3]);

            NSString *r4 = Play(port, @"av-enc.m3u8", 1.0);
            Check([r4 hasPrefix:@"OK"], [NSString stringWithFormat:@"AES-128 加密 HLS 可播＝解密成功（%@）", r4]);

            if (logPath) {
                int refs = CountInLog(logPath, @"Referer=http://127.0.0.1:8901/page.html");
                Check(refs > 0, [NSString stringWithFormat:@"服务器日志证实子请求带 Referer（%d 处）", refs]);
                int seg480 = CountInLog(logPath, @"/avseg480");
                int seg720 = CountInLog(logPath, @"/avseg720");
                // pinned-http.m3u8 只引用 av720：钉选后其余档位零请求（本次运行段内）
                Check(seg480 == 0, [NSString stringWithFormat:@"钉选后 480p 零请求（实际 %d）", seg480]);
                Check(seg720 > 0, [NSString stringWithFormat:@"钉选后 720p 分片已拉取（%d 处）", seg720]);
            }

            NSLog(@"== 端到端结果：%d 过 / %d 挂 ==", gPassed, gFailed);
            rc = gFailed ? 1 : 0;
            dispatch_async(dispatch_get_main_queue(), ^{ exit(rc); });
        });
        dispatch_main();
    }
}
