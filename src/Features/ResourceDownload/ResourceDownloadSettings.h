#import <Foundation/Foundation.h>

@class PreferencesStore;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ResourceSelectAllScope) {
    ResourceSelectAllScopeCurrentPage = 0,
    ResourceSelectAllScopeAllResults = 1,
};

typedef NS_ENUM(NSInteger, ResourceDownloadDestination) {
    ResourceDownloadDestinationDownloads = 0,
    ResourceDownloadDestinationDesktop = 1,
    ResourceDownloadDestinationCustom = 2,   // 用户自选目录（如 U 盘），2026-09-03 新增
};

@interface ResourceDownloadSettings : NSObject

- (instancetype)initWithPreferencesStore:(PreferencesStore *)store
                             downloadsURL:(NSURL *)downloadsURL
                               desktopURL:(NSURL *)desktopURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, assign) ResourceSelectAllScope selectAllScope;
@property (nonatomic, assign) ResourceDownloadDestination downloadDestination;

- (NSIndexSet *)selectionIndexesForItemCount:(NSUInteger)itemCount
                                 currentPage:(NSInteger)currentPage
                                    pageSize:(NSUInteger)pageSize;
- (NSURL *)downloadDirectoryURL;
- (NSString *)downloadDirectoryDisplayName;

/// 自选下载目录（U 盘等）；downloadDestination==Custom 时生效。可空。
- (nullable NSURL *)customDirectoryURL;
- (void)setCustomDirectoryURL:(nullable NSURL *)url;

@end

NS_ASSUME_NONNULL_END
