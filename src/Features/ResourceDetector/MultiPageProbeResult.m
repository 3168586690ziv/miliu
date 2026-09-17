//
//  MultiPageProbeResult.m — 第 3 阶段｜多页面结果模型实现
//

#import "MultiPageProbeResult.h"

@implementation MultiPageProbePageResult

+ (instancetype)resultWithPageURL:(NSURL *)pageURL {
    MultiPageProbePageResult *r = [MultiPageProbePageResult new];
    r.pageURL = pageURL;
    r.status = MultiPageProbePageStatusNotStarted;
    r.media = @[];
    return r;
}

@end

@implementation MultiPageProbeSummary
@end
