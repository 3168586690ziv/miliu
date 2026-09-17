#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把非中文资源标题翻译为简体中文。回调固定在主线程；失败或结果仍非中文时返回空串。
@interface ResourceTitleTranslator : NSObject

+ (BOOL)titleNeedsChineseTranslation:(NSString *)title;
- (instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)configuration;
- (void)translateTitle:(NSString *)title completion:(void (^)(NSString *translated))completion;
- (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
