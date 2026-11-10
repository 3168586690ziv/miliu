#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把非中文资源标题翻译为简体中文。回调固定在主线程；失败或结果仍非中文时返回空串。
@interface ResourceTitleTranslator : NSObject

+ (BOOL)titleNeedsChineseTranslation:(NSString *)title;
/// 默认仅本地词表，不向第三方发送标题；未命中返回空串，由调用方保留原题。
- (instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)configuration;
/// 仅显式允许时使用第三方翻译；许可在实例生命周期内固定。
- (instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)configuration
                   allowsNetworkTranslation:(BOOL)allowed;
- (void)translateTitle:(NSString *)title completion:(void (^)(NSString *translated))completion;
- (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
