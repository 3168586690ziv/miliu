#import "RDResourceModeFilter.h"

@implementation RDResourceModeFilter

+ (BOOL)allowsMedia:(DetectedMedia *)media mode:(ZZResourceDiscoveryMode)mode {
    if (![media isKindOfClass:[DetectedMedia class]] || media.mediaURL.length == 0) return NO;
    if (mode == ZZResourceDiscoveryModeCurrentPage) {
        return media.resourceKind == RDResourceKindImage ||
               media.resourceKind == RDResourceKindVideo ||
               media.resourceKind == RDResourceKindManifest;
    }
    return media.resourceKind == RDResourceKindVideo || media.resourceKind == RDResourceKindManifest;
}

+ (NSArray<DetectedMedia *> *)allowedMedia:(NSArray<DetectedMedia *> *)media
                                      mode:(ZZResourceDiscoveryMode)mode {
    NSMutableArray *result = [NSMutableArray array];
    for (DetectedMedia *item in media ?: @[]) {
        if ([self allowsMedia:item mode:mode]) [result addObject:item];
    }
    return [result copy];
}

@end
