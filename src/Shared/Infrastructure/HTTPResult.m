//
//  HTTPResult.m — 模块 08
//
#import "HTTPResult.h"

@implementation HTTPResult
- (BOOL)isSuccess {
    return self.error == nil && self.statusCode >= 200 && self.statusCode < 300;
}
@end
