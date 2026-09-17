//
//  AppError.h — 模块 08｜共享异步、网络与错误基础
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AppErrorType) {
    AppErrorNone = 0,
    AppErrorOffline,        // 无网络
    AppErrorTimeout,        // 超时
    AppErrorHTTP,           // HTTP 状态错误
    AppErrorParse,          // 解析失败
    AppErrorCache,          // 缓存错误
    AppErrorBusinessDate,   // 业务日期缺失/非法
    AppErrorPermission,     // 权限不足
    AppErrorFile,           // 文件错误
    AppErrorCancelled,      // 已取消
};

@interface AppError : NSObject
@property (nonatomic, assign) AppErrorType type;
@property (nonatomic, assign) NSInteger httpStatusCode;
@property (nonatomic, copy) NSString *message;
+ (instancetype)errorWithType:(AppErrorType)type message:(NSString *)message;
+ (instancetype)errorWithType:(AppErrorType)type httpStatusCode:(NSInteger)code message:(NSString *)message;
- (BOOL)isCancelled;
@end

NS_ASSUME_NONNULL_END
