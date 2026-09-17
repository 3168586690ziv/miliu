// RDThumbnailGenerator — reusable, generation-isolated asynchronous thumbnails.
#import "RDThumbnailGenerator.h"
#import <AVFoundation/AVFoundation.h>

@interface RDThumbnailGenerator ()
@property (nonatomic, strong, nullable) AVAssetImageGenerator *generator;
@property (nonatomic) NSUInteger generation;
@end

@implementation RDThumbnailGenerator

- (void)generateThumbnailForURL:(NSURL *)url atTime:(CMTime)time
                    completion:(void (^)(CGImageRef, AppError *))completion {
    [self generateThumbnailForURL:url atTime:time referer:nil completion:completion];
}

- (void)generateThumbnailForURL:(NSURL *)url atTime:(CMTime)time
                       referer:(nullable NSString *)referer
                    completion:(void (^)(CGImageRef, AppError *))completion {
    @synchronized (self) {
        NSUInteger generation = ++self.generation;
        [self.generator cancelAllCGImageGeneration];
        self.generator = nil;
        if (!url) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized (self) {
                    if (generation == self.generation && completion)
                        completion(nil, [AppError errorWithType:AppErrorFile message:@"无效地址"]);
                }
            });
            return;
        }
        NSDictionary *options = referer.length
            ? @{@"AVURLAssetHTTPHeaderFieldsKey": @{@"Referer": referer}} : nil;
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
        AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        gen.appliesPreferredTrackTransform = YES;
        gen.maximumSize = CGSizeMake(512, 512);
        self.generator = gen;
        [gen generateCGImageAsynchronouslyForTime:time completionHandler:
            ^(CGImageRef image, CMTime actualTime, NSError *error) {
            // AVFoundation lends image only for this callback. Own a separate +1
            // before crossing queues; never release the borrowed reference.
            CGImageRef ownedImage = image ? CGImageRetain(image) : NULL;
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized (self) {
                    // Keep this request's generator alive through delivery, and
                    // never cancel/clear self.generator from an old callback.
                    (void)gen.asset;
                    if (generation != self.generation || !completion) {
                        if (ownedImage) CGImageRelease(ownedImage);
                        return;
                    }
                    if (error || !ownedImage) {
                        if (ownedImage) CGImageRelease(ownedImage);
                        completion(nil, [AppError errorWithType:AppErrorFile
                            message:error.localizedDescription ?: @"无法生成缩略图"]);
                    } else {
                        completion(ownedImage, nil); // transfer +1 to caller
                    }
                }
            });
        }];
    }
}

- (void)cancel {
    @synchronized (self) {
        ++self.generation;
        [self.generator cancelAllCGImageGeneration];
        self.generator = nil;
    }
}
@end
