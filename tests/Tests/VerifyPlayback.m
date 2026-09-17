//
//  VerifyPlayback.m — 视频可播放性验证（手动工具）
//
//  用 AVFoundation 读取时长/轨道/分辨率，并在 3 个时间点抽帧解码。
//  退出码 0 = 可正常播放；1 = 解码失败。用法：VerifyPlayback <file>
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) { printf("usage: VerifyPlayback <file>\n"); return 2; }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:@{}];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [asset loadValuesAsynchronouslyForKeys:@[ @"duration", @"tracks", @"playable" ]
                             completionHandler:^{ dispatch_semaphore_signal(sem); }];
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC)) != 0) {
            printf("PLAYBACK-FAIL: 读取元数据超时\n");
            return 1;
        }
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded) {
            printf("PLAYBACK-FAIL: 无法读取轨道：%s\n", error.localizedDescription.UTF8String ?: "");
            return 1;
        }
        if (!asset.playable) {
            printf("PLAYBACK-FAIL: asset 不可播放\n");
            return 1;
        }
        double seconds = CMTimeGetSeconds(asset.duration);
        NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        AVAssetTrack *video = videoTracks.firstObject;
        CGSize size = video ? CGSizeApplyAffineTransform(video.naturalSize, video.preferredTransform)
                            : CGSizeZero;
        size = CGSizeMake(fabs(size.width), fabs(size.height));
        printf("元数据: 时长=%.1fs 分辨率=%.0fx%.0f 视频轨=%lu 音频轨=%lu\n",
               seconds, size.width, size.height,
               (unsigned long)videoTracks.count, (unsigned long)audioTracks.count);

        // 三个时间点抽帧（开头/中段/结尾），任何真实可播视频都应至少成功 2 帧
        AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.requestedTimeToleranceBefore = kCMTimeZero;
        generator.requestedTimeToleranceAfter = kCMTimeZero;
        NSMutableArray<NSValue *> *times = [NSMutableArray array];
        if (seconds > 0.5) {
            [times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(MIN(3.0, seconds / 2.0), 600)]];
            [times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(seconds * 0.5, 600)]];
            [times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(MAX(0.0, seconds - 0.5), 600)]];
        }
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        __block NSInteger succeeded = 0;
        __block NSInteger delivered = 0;
        [generator generateCGImagesAsynchronouslyForTimes:times
                                        completionHandler:^(CMTime requestedTime,
                                                            CGImageRef image,
                                                            CMTime actualTime,
                                                            AVAssetImageGeneratorResult result,
                                                            NSError *frameError) {
            delivered++;
            if (result == AVAssetImageGeneratorSucceeded && image) succeeded++;
            else printf("抽帧失败 @%.1fs: %s\n", CMTimeGetSeconds(requestedTime),
                        frameError.localizedDescription.UTF8String ?: "");
            if (delivered == (NSInteger)times.count) dispatch_group_leave(group);
        }];
        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 60LL * NSEC_PER_SEC));

        if (seconds > 0 && videoTracks.count >= 1 && succeeded >= 2) {
            printf("PLAYBACK-PASS: 解码抽帧 %ld/%lu 成功，可正常播放\n",
                   (long)succeeded, (unsigned long)times.count);
            return 0;
        }
        printf("PLAYBACK-FAIL: 抽帧成功 %ld/%lu\n", (long)succeeded, (unsigned long)times.count);
        return 1;
    }
}
