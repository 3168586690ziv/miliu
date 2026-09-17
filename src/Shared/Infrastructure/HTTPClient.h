//
//  HTTPClient.h — 模块 08
//
//  GET / 超时 / 取消 / HTTP 状态检查 / 最大响应体 / mock 注入。
//  后台队列执行，completion 回主线程。取消后不回调 UI。
//
#import <Foundation/Foundation.h>
#import "HTTPRequest.h"
#import "HTTPResult.h"

NS_ASSUME_NONNULL_BEGIN

@interface HTTPTask : NSObject
- (void)cancel;
@property (nonatomic, assign, readonly) BOOL isCancelled;
@end

@interface HTTPClient : NSObject

// 测试注入：设置后所有请求走 mock，不触网
@property (nonatomic, copy, nullable) HTTPResult *(^mockHandler)(HTTPRequest *req);

// 流式会话自定义协议类（仅自建 session 时生效；测试用于注入受控数据流）
@property (nonatomic, copy, nullable) NSArray<Class> *protocolClasses;

- (instancetype)initWithSession:(nullable NSURLSession *)session;
- (HTTPTask *)performRequest:(HTTPRequest *)request
                   completion:(void (^)(HTTPResult *result))completion;
- (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
