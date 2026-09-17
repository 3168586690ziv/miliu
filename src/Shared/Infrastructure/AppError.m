//
//  AppError.m — 模块 08
//
#import "AppError.h"

@implementation AppError
+ (instancetype)errorWithType:(AppErrorType)type message:(NSString *)message {
    return [self errorWithType:type httpStatusCode:0 message:message];
}
+ (instancetype)errorWithType:(AppErrorType)type httpStatusCode:(NSInteger)code message:(NSString *)message {
    AppError *e = [[self alloc] init];
    e.type = type;
    e.httpStatusCode = code;
    e.message = message ?: @"";
    return e;
}
- (BOOL)isCancelled {
    return self.type == AppErrorCancelled;
}
@end
