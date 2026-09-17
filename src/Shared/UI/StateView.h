//
//  StateView.h — 模块 09｜统一状态视图
//
//  同一时刻只处于一个状态：loading / empty / error / stale / content。
//  error 状态包含明确重试动作。支持减少动态效果与提高对比度。
//
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, StateViewState) {
    StateViewStateLoading = 0,
    StateViewStateEmpty,
    StateViewStateError,
    StateViewStateStale,
    StateViewStateContent,
};

@interface StateView : NSView

@property (nonatomic, readonly) StateViewState state;

// 当前可见子视图（仅一个非隐藏），供测试断言单一状态。
@property (nonatomic, readonly) NSInteger visibleChildCount;

// 内容视图（content 状态展示）
@property (nonatomic, strong, nullable) NSView *contentView;

// 各状态文案
@property (nonatomic, copy) NSString *emptyMessage;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic, copy) NSString *staleMessage;

// error 状态重试回调（必须存在，否则 error 状态无重试动作视为非法）
@property (nonatomic, copy, nullable) void (^retryAction)(void);

- (void)setState:(StateViewState)state;

// 触发重试（供按钮与测试调用）
- (BOOL)invokeRetry;

// error 状态是否具备明确重试动作
- (BOOL)errorHasRetryAction;

@end

NS_ASSUME_NONNULL_END
