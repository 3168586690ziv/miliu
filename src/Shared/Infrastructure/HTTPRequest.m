//
//  HTTPRequest.m — 模块 08
//
#import "HTTPRequest.h"

@implementation HTTPRequest
- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _url = url;
        _method = @"GET";
        _timeout = 30.0;
        _maxBodyBytes = 5 * 1024 * 1024;
        _idempotent = YES;   // GET 默认幂等可重试
        _retryLimit = 2;
    }
    return self;
}
@end
