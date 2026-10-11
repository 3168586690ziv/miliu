// RDPreviewPlaylistRewrite.h — HLS master 钉选改写：把 master 清单改写为仅含目标变体的单变体清单（第 35 轮预览播放）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RDPreviewPlaylistResult : NSObject
@property (nonatomic, copy, readonly) NSString *rewrittenPlaylist;      // 改写后 master 文本
@property (nonatomic, copy, readonly) NSArray<NSString *> *remoteURLs;  // 改写后清单内全部绝对 http(s) URL（供 URLPolicy 事前校验）
@property (nonatomic, assign, readonly) BOOL succeeded;                 // 钉选失败时 NO，rewritten 为原文原样返回
@end

@interface RDPreviewPlaylistRewrite : NSObject
+ (RDPreviewPlaylistResult *)rewriteMaster:(NSString *)masterText
                                   baseURL:(nullable NSString *)baseURL
                        pinnedVariantURL:(nullable NSString *)pinnedVariantURL;
@end

NS_ASSUME_NONNULL_END
