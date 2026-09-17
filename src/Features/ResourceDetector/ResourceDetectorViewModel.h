//
//  ResourceDetectorViewModel.h — 模块 17｜探测 ViewModel
//
//  single-flight + generation：快速重复探测只采用最新结果，旧代次回调失效。
//  负责把 WebProbe 结果映射到统一状态（loading/content/empty/error），并对结果去重。
//

#import <Foundation/Foundation.h>
#import "WebProbe.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ResourceDetectorState) {
    ResourceDetectorStateLoading = 0,
    ResourceDetectorStateContent,
    ResourceDetectorStateEmpty,
    ResourceDetectorStateError,
    /// HTML was obtained, but the analyzer could not recognize a usable page.
    ResourceDetectorStateBadPage,
};

@interface ResourceDetectorViewModel : NSObject
@property (nonatomic, strong) id<RDProbeProvider> provider;  // WebProbe 或测试 mock
@property (nonatomic, assign) ResourceDetectorState state;
@property (nonatomic, copy) NSString *errorText;
@property (nonatomic, copy) NSArray<DetectedMedia *> *results;
@property (nonatomic, copy) NSString *inputURL;

- (void)probeURL:(NSString *)urlString;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
