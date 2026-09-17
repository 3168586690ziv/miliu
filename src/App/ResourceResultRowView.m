#import "ResourceResultRowView.h"
#import "../Shared/UI/RDByteCountFormatting.h"

@interface ResourceResultRowView ()
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextField *detailField;
@end

@implementation ResourceResultRowView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _titleField = [self labelWithFont:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                alignment:NSTextAlignmentLeft];
        _titleField.lineBreakMode = NSLineBreakByTruncatingMiddle;  // 前面显示、中间省略、后缀(如 .mp4)保留
        _titleField.maximumNumberOfLines = 1;

        _detailField = [self labelWithFont:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]
                                alignment:NSTextAlignmentLeft];
        _detailField.textColor = [NSColor secondaryLabelColor];
        _detailField.lineBreakMode = NSLineBreakByTruncatingTail;
        _detailField.maximumNumberOfLines = 1;

        for (NSView *v in @[_titleField, _detailField]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:v];
        }
        [self buildConstraints];
    }
    return self;
}

- (NSTextField *)labelWithFont:(NSFont *)font alignment:(NSTextAlignment)alignment {
    NSTextField *f = [NSTextField labelWithString:@""];
    f.font = font;
    f.alignment = alignment;
    f.editable = NO;
    f.bezeled = NO;
    f.drawsBackground = NO;
    return f;
}

- (void)buildConstraints {
    NSDictionary *views = @{ @"title": self.titleField,
                             @"detail": self.detailField };
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint
        constraintsWithVisualFormat:@"H:|-4-[title]-4-|"
                            options:0 metrics:nil views:views]];
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint
        constraintsWithVisualFormat:@"H:|-4-[detail]-4-|"
                            options:0 metrics:nil views:views]];
    [NSLayoutConstraint activateConstraints:[NSLayoutConstraint
        constraintsWithVisualFormat:@"V:|-6-[title]-2-[detail]-6-|"
                            options:0 metrics:nil views:views]];
}

- (void)configureWithMedia:(DetectedMedia *)media {
    [self configureWithMedia:media durationHint:nil];
}

- (void)configureWithMedia:(DetectedMedia *)media durationHint:(NSString *)durationHint {
    [self configureWithMedia:media durationHint:durationHint sizeHint:nil];
}

- (void)configureWithMedia:(DetectedMedia *)media
              durationHint:(NSString *)durationHint
                  sizeHint:(NSString *)sizeHint {
    self.media = media;

    NSString *title = media.titleSummary.length ? media.titleSummary
                     : (media.title.length ? media.title : nil);
    if (!title.length) {
        NSURL *u = [NSURL URLWithString:media.mediaURL ?: @""];
        title = u.lastPathComponent.length ? u.lastPathComponent : (media.mediaURL ?: @"未命名资源");
    }
    // 格式后缀直接拼进标题末尾并确保不被截断（标题本身用中间省略）
    NSString *suffix = media.format.length ? [NSString stringWithFormat:@" (%@)", media.format.uppercaseString] : @"";
    self.titleField.stringValue = [title stringByAppendingString:suffix];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (durationHint.length) [parts addObject:durationHint];
    if (media.format.length) [parts addObject:media.format.uppercaseString];
    // 显式大小优先：用户为该行选定了档位时显示该档位的大小（与详情/下载对象一致）。
    NSString *sizeText = sizeHint.length ? sizeHint
        : ((!media.isManifest && media.resourceKind != RDResourceKindManifest && media.sizeBytes > 0)
           ? RDFormatByteCount(media.sizeBytes) : nil);
    if (sizeText.length) [parts addObject:sizeText];
    NSURL *u = [NSURL URLWithString:media.mediaURL ?: @""];
    if (u.host.length) [parts addObject:u.host];
    self.detailField.stringValue = parts.count ? [parts componentsJoinedByString:@"  ·  "] : (media.mediaURL ?: @"");
}

@end
