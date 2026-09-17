//
//  InspectMedia.m — 本地下载文件真实分辨率/可播放性检查（AVFoundation）
//  用法：InspectMedia <文件路径>
//
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { printf("usage: InspectMedia <file>\n"); return 2; }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            printf("INSPECT-FAIL 文件不存在：%s\n", path.UTF8String); return 1;
        }
        unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        NSArray<NSString *> *keys = @[@"playable", @"tracks", @"duration", @"hasProtectedContent"];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{ dispatch_semaphore_signal(sem); }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
        NSError *error = nil;
        BOOL playable = NO;
        if ([asset statusOfValueForKey:@"playable" error:&error] == AVKeyValueStatusLoaded) playable = asset.playable;
        double duration = 0;
        if ([asset statusOfValueForKey:@"duration" error:&error] == AVKeyValueStatusLoaded) duration = CMTimeGetSeconds(asset.duration);
        printf("INSPECT path=%s size=%llu playable=%s duration=%.3fs\n", path.UTF8String, size,
               playable ? "yes" : "no", duration);
        if ([asset statusOfValueForKey:@"tracks" error:&error] == AVKeyValueStatusLoaded) {
            for (AVAssetTrack *track in asset.tracks) {
                CGSize natural = track.naturalSize;
                printf("INSPECT-TRACK type=%s size=%.0fx%.0f nominal=%dx%d fps=%.2f bitrate=%ld\n",
                       track.mediaType.UTF8String, natural.width, natural.height,
                       (int)track.naturalSize.width, (int)track.naturalSize.height,
                       track.nominalFrameRate, (long)track.estimatedDataRate);
            }
        }
        if (!playable) { printf("INSPECT-FAIL 不可播放\n"); return 1; }
    }
    return 0;
}
