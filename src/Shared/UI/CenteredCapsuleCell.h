//
//  CenteredCapsuleCell.h — 胶囊/徽章/pill 文字垂直居中共享组件
//
//  根因：NSTextFieldCell / NSButtonCell 默认把 baseline 放在排版行框内
//  `ascender` 处绘制单行文字，而中文字形（PingFang）的视觉 ink 中心位于
//  baseline 上方约 (ascender+descender)/2 ≈ 0.36em 处，于是固定高度胶囊
//  内的文字看起来偏上。纯约束（centerYAnchor）只能居中「行框」，无法修正
//  字体度量不对称，所以必须在 cell 层按字形 ink 中心重新定位 baseline。
//
//  算法（本组件共享，全部按物理像素取整，兼容 1x/2x Retina）：
//    baseline = 容器中心 - 字形 ink 中心偏移（可选 verticalAdjustment 光学微调）
//    绘制矩形 = baseline - ascender 起、高度为单行行高的行框
//    Retina 取整：round(origin.y * backingScale) / backingScale
//
//  使用约定：只用于「非编辑、单行、固定高度」的胶囊/徽章/状态标签；
//  不得替换普通正文 label、多行文本、可选中文本、表单输入框的 cell。
//
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// 胶囊文字专用 NSTextFieldCell：重写 drawingRectForBounds: / titleRectForBounds: /
/// drawInteriorWithFrame:inView: 三入口，统一做字形 ink 居中。
@interface CenteredCapsuleTextFieldCell : NSTextFieldCell

/// 光学微调（pt）。默认 0；正值 = 视觉下移，负值 = 视觉上移。
/// 仅允许 ±1pt 内的中文字形光学微调，必须集中在共享组件中，禁止硬编码单点偏移。
@property (nonatomic) CGFloat verticalAdjustment;

/// 测试用像素比例覆盖。0 = 自动（window.backingScaleFactor → mainScreen → 2.0）。
@property (nonatomic) CGFloat zzBackingScaleOverride;

/// 布局查询接口（供几何测试断言字形 ink 中心贴容器中心）。
/// 生产绘制只走 drawInteriorWithFrame:inView: 单入口；此方法不参与绘制。
- (NSRect)centeredTextRectForBounds:(NSRect)bounds;

@end

/// 胶囊按钮专用 NSButtonCell：只重写 titleRectForBounds:（不碰 drawTitle:，
/// macOS 11+ 重写 drawTitle 会把标题压到底部），标题同样按字形 ink 居中。
@interface CenteredCapsuleButtonCell : NSButtonCell

@property (nonatomic) CGFloat verticalAdjustment;
@property (nonatomic) CGFloat zzBackingScaleOverride;

@end

NS_ASSUME_NONNULL_END
