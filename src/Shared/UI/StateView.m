//
//  StateView.m — 模块 09
//
#import "StateView.h"
#import "ColorTokens.h"
#import "TypographyTokens.h"
#import "LayoutMetrics.h"

@interface StateView ()
@property (nonatomic, strong) NSTextField *loadingLabel;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSTextField *errorLabel;
@property (nonatomic, strong) NSButton *retryButton;
@property (nonatomic, strong) NSTextField *staleLabel;
@property (nonatomic, strong) NSView *errorContainer;
@end

@implementation StateView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _state = StateViewStateLoading;
        _emptyMessage = @"暂无数据";
        _errorMessage = @"加载失败";
        _staleMessage = @"显示的是旧缓存";
        [self buildSubviews];
        [self applyState];
    }
    return self;
}

- (void)buildSubviews {
    self.wantsLayer = YES;

    _loadingLabel = [self makeLabel:@"加载中…" color:[ColorTokens textSecondary] font:[TypographyTokens body]];
    _emptyLabel   = [self makeLabel:_emptyMessage color:[ColorTokens textTertiary] font:[TypographyTokens body]];
    _staleLabel   = [self makeLabel:_staleMessage color:[ColorTokens stale] font:[TypographyTokens footnote]];

    _errorContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    _errorLabel = [self makeLabel:_errorMessage color:[ColorTokens error] font:[TypographyTokens body]];
    [_errorContainer addSubview:_errorLabel];

    _retryButton = [NSButton buttonWithTitle:@"重试" target:self action:@selector(retryTapped:)];
    _retryButton.bezelStyle = NSBezelStyleRounded;
    [_retryButton setAccessibilityLabel:@"重试加载"];
    [_errorContainer addSubview:_retryButton];

    for (NSView *v in @[_loadingLabel, _emptyLabel, _staleLabel, _errorContainer]) {
        [self addSubview:v];
    }
}

- (NSTextField *)makeLabel:(NSString *)text color:(NSColor *)color font:(NSFont *)font {
    NSTextField *l = [NSTextField labelWithString:text ?: @""];
    l.textColor = color;
    l.font = font;
    return l;
}

- (void)setEmptyMessage:(NSString *)m { _emptyMessage = [m copy]; _emptyLabel.stringValue = m ?: @""; }
- (void)setErrorMessage:(NSString *)m { _errorMessage = [m copy]; _errorLabel.stringValue = m ?: @""; }
- (void)setStaleMessage:(NSString *)m { _staleMessage = [m copy]; _staleLabel.stringValue = m ?: @""; }

- (void)setContentView:(NSView *)contentView {
    if (_contentView) [_contentView removeFromSuperview];
    _contentView = contentView;
    if (contentView) [self addSubview:contentView];
    [self applyState];
}

- (void)setState:(StateViewState)state {
    _state = state;
    [self applyState];
}

// 核心不变式：任一时刻仅一个子视图可见。
- (void)applyState {
    _loadingLabel.hidden  = (_state != StateViewStateLoading);
    _emptyLabel.hidden    = (_state != StateViewStateEmpty);
    _errorContainer.hidden = (_state != StateViewStateError);
    _staleLabel.hidden    = (_state != StateViewStateStale);
    _contentView.hidden   = (_state != StateViewStateContent);
}

- (NSInteger)visibleChildCount {
    NSInteger n = 0;
    NSArray *tracked = @[_loadingLabel, _emptyLabel, _errorContainer, _staleLabel];
    for (NSView *v in tracked) { if (v && !v.hidden) n++; }
    if (_contentView && !_contentView.hidden) n++;
    return n;
}

- (void)retryTapped:(id)sender { [self invokeRetry]; }

- (BOOL)invokeRetry {
    if (_state != StateViewStateError) return NO;
    if (!self.retryAction) return NO;
    self.retryAction();
    return YES;
}

- (BOOL)errorHasRetryAction {
    return self.retryAction != nil;
}

@end
