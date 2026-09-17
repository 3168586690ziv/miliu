//
//  ResourceDetectorViewModel.m — 模块 17｜探测 ViewModel 实现
//
#import "ResourceDetectorViewModel.h"
#import "DetectedMedia.h"
#import "AppError.h"
#import "RequestGeneration.h"

@interface ResourceDetectorViewModel ()
@property (nonatomic, strong) RequestGeneration *gen;
@property (nonatomic, assign) NSUInteger currentGen;
@end

@implementation ResourceDetectorViewModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _gen = [RequestGeneration new];
        _state = ResourceDetectorStateLoading;
        _results = @[];
    }
    return self;
}

- (void)probeURL:(NSString *)urlString {
    if (urlString == nil || urlString.length == 0) {
        self.state = ResourceDetectorStateError;
        self.errorText = @"请输入有效的网页地址";
        return;
    }
    NSUInteger g = [self.gen nextGeneration];
    self.currentGen = g;
    self.inputURL = urlString;
    self.state = ResourceDetectorStateLoading;
    self.errorText = @"";
    self.results = @[];

    __weak typeof(self) w = self;
    [self.provider probeURL:urlString completion:^(RDProbeResult *result, AppError *error, NSUInteger generation) {
        __strong typeof(w) s = w;
        if (!s) return;
        if (generation != s.currentGen) return;   // 旧代次结果丢弃
        if (error) {
            s.state = ResourceDetectorStateError;
            s.errorText = error.message ?: @"探测失败";
            s.results = @[];
            return;
        }
        // 防御性再去重
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSMutableArray<DetectedMedia *> *ordered = [NSMutableArray arrayWithCapacity:result.media.count];
        for (DetectedMedia *dm in result.media) {
            NSString *k = [DetectedMedia dedupKeyForURL:dm.mediaURL];
            if (k.length && ![seen containsObject:k]) { [seen addObject:k]; [ordered addObject:dm]; }
        }
        NSArray<DetectedMedia *> *final = [ordered copy];
        s.results = final;
        if (final.count == 0) {
            s.state = (!result || result.isBadPage) ? ResourceDetectorStateBadPage : ResourceDetectorStateEmpty;
        } else {
            s.state = ResourceDetectorStateContent;
        }
    }];
}

- (void)cancel {
    [self.provider cancelAll];
    self.currentGen = [self.gen nextGeneration];
    self.state = ResourceDetectorStateLoading;
    self.errorText = @"探测已取消";
}

@end
