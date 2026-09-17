//
//  RDDisplayMetadataRecoveryStore.h
//  7zz
//
//  资源卡片“展示元数据”的稳定存储：按规范化 sourcePage URL 索引标题与封面。
//  与媒体 URL 的缓存/下载身份解耦，专门解决 token 刷新后标题和封面退化。
//  保持旧历史兼容：新键 pageMetadata 与旧 titles/sources/posters 共存。
//

#import <Foundation/Foundation.h>
#import "RDResourceDisplayMetadata.h"

NS_ASSUME_NONNULL_BEGIN

@interface RDDisplayMetadataRecoveryStore : NSObject

/// 从 items（detectedResources 数组，含 variants）提取 sourcePage → 元数据。
- (void)recordMetadataForItems:(NSArray<NSDictionary *> *)items;

/// 记录一次实际恢复出来的展示元数据（标题/封面皆可独立存在），按规范化
/// sourcePage URL 合并落地。用于恢复链路把来源页带回的标题/封面写入
/// pageMetadata 历史，重启或媒体 URL token 变化后仍可按 sourcePage 恢复。
- (void)recordRecoveredMetadata:(nonnull RDResourceDisplayMetadata *)metadata
                forSourcePageURL:(nonnull NSString *)sourcePageURL;

/// 根据 sourcePage URL 取展示元数据；nil 表示无记录。
- (nullable RDResourceDisplayMetadata *)metadataForSourcePageURL:(NSString *)sourcePageURL;

/// 根据 sourcePage URL 取标题；无记录或标题无效时返回空字符串。
- (NSString *)titleForSourcePageURL:(NSString *)sourcePageURL;

/// 根据 sourcePage URL 取封面 URL；无记录或不安全时返回 nil。
- (nullable NSString *)posterURLStringForSourcePageURL:(NSString *)sourcePageURL;

/// 可序列化的历史字典片段（应写入 history[@"pageMetadata"]）。
- (NSDictionary *)historyDictionary;

/// 从历史字典片段恢复（传入 history[@"pageMetadata"]）。
- (void)loadFromHistoryDictionary:(nullable NSDictionary *)dict;

/// 从旧版历史字典（titles/sources/posters 按媒体 URL 索引）反推 sourcePage → 元数据。
- (void)loadLegacyHistoryDictionary:(nullable NSDictionary *)history;

/// 规范化 sourcePage URL：去掉 fragment、host 小写、路径统一化。
+ (NSString *)normalizedSourcePageURLString:(NSString *)sourcePageURL;

@end

NS_ASSUME_NONNULL_END
