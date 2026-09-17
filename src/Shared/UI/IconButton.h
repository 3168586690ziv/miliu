//
//  IconButton.h — 模块 09｜纯图标按钮
//
//  强制空 title；图标可见；必须提供 accessibilityLabel（VoiceOver 可读用途）。
//  视觉上不得出现"按钮"二字（title 恒为空）。
//
#import "HoverableControl.h"

NS_ASSUME_NONNULL_BEGIN

@interface IconButton : HoverableControl

// 系统符号名或自定义图像
@property (nonatomic, copy, nullable) NSString *symbolName;
@property (nonatomic, strong, nullable) NSImage *iconImage;

// 强制可见的图标尺寸
@property (nonatomic, assign) CGFloat pointSize;     // 默认 16
@property (nonatomic, assign) NSFontWeight weight;    // 默认 semibold

// 无障碍标签（必填；缺省时初始化失败）
@property (nonatomic, copy, nullable) NSString *iconAccessibilityLabel;

// 恒为空标题（供测试断言）
- (NSString *)visibleTitle;

// 图标当前是否可见
- (BOOL)iconIsVisible;

// 初始化：必须提供图标与无障碍标签
- (nullable instancetype)initWithSymbol:(NSString *)symbol
                     accessibilityLabel:(NSString *)label
                                  target:(nullable id)target
                                  action:(nullable SEL)action;

@end

NS_ASSUME_NONNULL_END
