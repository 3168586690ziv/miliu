#import "ResourceDownloadSettings.h"
#import "PreferencesStore.h"

@interface ResourceDownloadSettings ()
@property (nonatomic, strong) PreferencesStore *store;
@property (nonatomic, copy) NSURL *downloadsURL;
@property (nonatomic, copy) NSURL *desktopURL;
- (NSURL *)validCustomDirectoryURL;
@end

@implementation ResourceDownloadSettings

- (instancetype)initWithPreferencesStore:(PreferencesStore *)store
                             downloadsURL:(NSURL *)downloadsURL
                               desktopURL:(NSURL *)desktopURL {
    self = [super init];
    if (self) {
        _store = store;
        _downloadsURL = [downloadsURL copy];
        _desktopURL = [desktopURL copy];
    }
    return self;
}

- (ResourceDownloadDestination)downloadDestination {
    NSInteger value = [self.store integerForKey:SevenZZKeyResourceDownloadDestination
                                    defaultValue:ResourceDownloadDestinationDownloads];
    if (value == ResourceDownloadDestinationCustom) return ResourceDownloadDestinationCustom;
    return value == ResourceDownloadDestinationDesktop
        ? ResourceDownloadDestinationDesktop : ResourceDownloadDestinationDownloads;
}

- (void)setDownloadDestination:(ResourceDownloadDestination)value {
    NSInteger safeValue = value == ResourceDownloadDestinationCustom
        ? (NSInteger)ResourceDownloadDestinationCustom
        : (value == ResourceDownloadDestinationDesktop
           ? (NSInteger)ResourceDownloadDestinationDesktop
           : (NSInteger)ResourceDownloadDestinationDownloads);
    [self.store setInteger:safeValue forKey:SevenZZKeyResourceDownloadDestination];
}

- (NSURL *)customDirectoryURL {
    NSString *path = [self.store stringForKey:SevenZZKeyResourceDownloadCustomDirectory defaultValue:@""];
    if (path.length == 0) return nil;
    return [NSURL fileURLWithPath:path];
}

- (void)setCustomDirectoryURL:(NSURL *)url {
    NSString *path = url.isFileURL ? url.path : @"";
    [self.store setString:path forKey:SevenZZKeyResourceDownloadCustomDirectory];
}

- (NSURL *)downloadDirectoryURL {
    switch (self.downloadDestination) {
        case ResourceDownloadDestinationDesktop:
            return self.desktopURL;
        case ResourceDownloadDestinationCustom: {
            // 自定义目录可能随 U 盘拔出或用户手动删除而失效；失效时必须真正回退，
            // 不能只把路径原样返回（否则下载会写进不存在的目录而失败）。
            return [self validCustomDirectoryURL] ?: self.downloadsURL;
        }
        case ResourceDownloadDestinationDownloads:
        default:
            return self.downloadsURL;
    }
}

// 自定义目录仅在「路径非空且当前确实是存在的目录」时才算可用。
- (NSURL *)validCustomDirectoryURL {
    NSURL *custom = self.customDirectoryURL;
    if (custom.path.length == 0) return nil;
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:custom.path isDirectory:&isDir] || !isDir) return nil;
    return custom;
}

// 显示名描述**实际生效**的位置：自定义目录失效时与 downloadDirectoryURL 一致地报「下载文件夹」。
- (NSString *)downloadDirectoryDisplayName {
    switch (self.downloadDestination) {
        case ResourceDownloadDestinationDesktop:
            return @"桌面";
        case ResourceDownloadDestinationCustom: {
            NSURL *custom = [self validCustomDirectoryURL];
            if (!custom) return @"下载文件夹";
            NSString *name = custom.lastPathComponent;
            return name.length ? [NSString stringWithFormat:@"自定义（%@）", name] : @"自定义位置";
        }
        case ResourceDownloadDestinationDownloads:
        default:
            return @"下载文件夹";
    }
}

@end
