//
//  ResourceThumbnailProgressView.h
//
//  Compact progress presentation for the current discovery batch's thumbnails.
//
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ResourceThumbnailProgressView : NSStackView

@property (nonatomic, readonly) NSUInteger totalCount;
@property (nonatomic, readonly) NSUInteger completedCount;

- (void)beginWithIdentifiers:(NSArray<NSNumber *> *)identifiers;
- (void)markPendingIdentifier:(NSNumber *)identifier;
- (void)markFinishedIdentifier:(NSNumber *)identifier;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
