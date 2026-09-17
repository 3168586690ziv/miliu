//
//  ResourceThumbnailProgressView.m
//
#import "ResourceThumbnailProgressView.h"
#import "ColorTokens.h"

@interface ResourceThumbnailProgressView ()
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSProgressIndicator *progressIndicator;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *trackedIdentifiers;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *finishedIdentifiers;
@end

@implementation ResourceThumbnailProgressView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.alignment = NSLayoutAttributeCenterY;
    self.spacing = 8;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.accessibilityLabel = @"缩略图加载进度";

    _titleLabel = [NSTextField labelWithString:@"缩略图"];
    _titleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _titleLabel.textColor = [ColorTokens textSecondary];
    [_titleLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    _progressIndicator = [NSProgressIndicator new];
    _progressIndicator.style = NSProgressIndicatorStyleBar;
    _progressIndicator.indeterminate = NO;
    _progressIndicator.minValue = 0;
    _progressIndicator.maxValue = 100;
    _progressIndicator.doubleValue = 0;
    _progressIndicator.controlSize = NSControlSizeSmall;
    _progressIndicator.accessibilityLabel = @"缩略图加载进度条";

    _countLabel = [NSTextField labelWithString:@"--"];
    _countLabel.alignment = NSTextAlignmentRight;
    _countLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
    _countLabel.textColor = [ColorTokens textSecondary];
    _countLabel.accessibilityLabel = @"缩略图加载数量";

    [self addArrangedSubview:_titleLabel];
    [self addArrangedSubview:_progressIndicator];
    [self addArrangedSubview:_countLabel];
    [_titleLabel.widthAnchor constraintEqualToConstant:48].active = YES;
    [_countLabel.widthAnchor constraintEqualToConstant:38].active = YES;
    [self.heightAnchor constraintEqualToConstant:16].active = YES;

    _trackedIdentifiers = [NSMutableSet set];
    _finishedIdentifiers = [NSMutableSet set];
    [self updatePresentation];
    return self;
}

- (NSUInteger)totalCount { return self.trackedIdentifiers.count; }
- (NSUInteger)completedCount { return self.finishedIdentifiers.count; }

- (void)beginWithIdentifiers:(NSArray<NSNumber *> *)identifiers {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self beginWithIdentifiers:identifiers]; });
        return;
    }
    [self.trackedIdentifiers removeAllObjects];
    [self.finishedIdentifiers removeAllObjects];
    for (NSNumber *identifier in identifiers) {
        if ([identifier isKindOfClass:NSNumber.class]) [self.trackedIdentifiers addObject:identifier];
    }
    [self updatePresentation];
}

- (void)markPendingIdentifier:(NSNumber *)identifier {
    if (!identifier) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self markPendingIdentifier:identifier]; });
        return;
    }
    [self.trackedIdentifiers addObject:identifier];
    [self.finishedIdentifiers removeObject:identifier];
    [self updatePresentation];
}

- (void)markFinishedIdentifier:(NSNumber *)identifier {
    if (!identifier) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self markFinishedIdentifier:identifier]; });
        return;
    }
    if (![self.trackedIdentifiers containsObject:identifier]) return;
    [self.finishedIdentifiers addObject:identifier];
    [self updatePresentation];
}

- (void)reset {
    [self beginWithIdentifiers:@[]];
}

- (void)updatePresentation {
    NSUInteger total = self.totalCount;
    NSUInteger completed = MIN(self.completedCount, total);
    double percent = total ? ((double)completed / (double)total) * 100.0 : 0;
    self.progressIndicator.doubleValue = percent;
    self.countLabel.stringValue = total ? [NSString stringWithFormat:@"%lu/%lu", (unsigned long)completed, (unsigned long)total] : @"--";
    self.progressIndicator.accessibilityValue = total ? [NSString stringWithFormat:@"%lu/%lu", (unsigned long)completed, (unsigned long)total] : @"尚未加载";
}

@end
