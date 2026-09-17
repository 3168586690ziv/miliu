//
//  RealDownloadVerify.m — 真实链接端到端下载验证（手动工具，不进自动测试）
//
//  用生产 DownloadManager + SessionDownloadBackend 对一个真实 URL 走完整链路：
//  入队（文件名清洗）→ 分段/单连接下载 → 合并校验 → move 到目标目录 → 终态持久化。
//  用法：
//    RealDownloadVerify <url> <referer> <title> [expectedSize] [destFolder]
//  默认 destFolder 为用户下载目录。输出 VERIFY-PASS/VERIFY-FAIL。
//

#import <Foundation/Foundation.h>
#import "DownloadManager.h"
#import "DownloadJob.h"
#import "PerformancePolicy.h"

// 与 DownloadManager.m 内部实现一致的最小声明（仅测试工具使用）
@interface SessionDownloadBackend : NSObject <RDDownloadBackend, NSURLSessionDownloadDelegate>
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 4) {
            printf("usage: RealDownloadVerify <url> <referer> <title> [expectedSize] [destFolder]\n");
            return 2;
        }
        [PerformancePolicy setMode:1];
        NSString *urlString = [NSString stringWithUTF8String:argv[1]];
        NSString *referer = [NSString stringWithUTF8String:argv[2]];
        NSString *title = [NSString stringWithUTF8String:argv[3]];
        int64_t expected = argc > 4 ? strtoll(argv[4], NULL, 10) : 0;
        NSURL *destFolder = argc > 5
            ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[5]]]
            : [NSURL fileURLWithPath:NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject];

        NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"7zz-realverify-%@", NSUUID.UUID.UUIDString]];
        NSString *suite = [NSString stringWithFormat:@"com.sevenzz.tests.real-download-verify.%@", NSUUID.UUID.UUIDString];
        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:suite];
        DownloadStore *store = [[DownloadStore alloc] initWithUserDefaults:[[NSUserDefaults alloc] initWithSuiteName:suite]];
        DownloadManager *manager = [[DownloadManager alloc] initWithBackend:[SessionDownloadBackend new]
                                                                  tempRoot:[NSURL fileURLWithPath:base]
                                                                     store:store];
        manager.rd_enableEndpointResolution = NO;
        manager.defaultReferer = referer; // 便捷入队入口不带 referer，防盗链站点必须在入队前设置

        // 走与 APP 相同的入口：清洗 + 扩展名保障在 DownloadManager 内部完成
        DownloadJob *job = [manager enqueueItemWithSourceURL:[NSURL URLWithString:urlString]
                                                      folder:destFolder
                                               preferredName:title
                                                        etag:@""
                                                lastModified:@""
                                                 acceptRanges:YES
                                               expectedLength:expected];

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:600];
        while (job.state != DownloadJobStateCompleted && job.state != DownloadJobStateFailed &&
               deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        }

        if (job.state == DownloadJobStateCompleted) {
            NSNumber *size = [[[NSFileManager defaultManager] attributesOfItemAtPath:job.destinationURL.path error:nil] objectForKey:NSFileSize];
            printf("VERIFY-PASS: %s (%lld bytes)\n", job.destinationURL.fileSystemRepresentation, size.longLongValue);
            if (expected > 0 && size.longLongValue != expected) {
                printf("VERIFY-FAIL: 大小不符，期望 %lld\n", expected);
                return 1;
            }
            return 0;
        }
        printf("VERIFY-FAIL: state=%ld error=%s\n", (long)job.state, job.errorText.UTF8String ?: "(none)");
        return 1;
    }
}
