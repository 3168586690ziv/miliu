//
//  RDFailureDiagnosis.h
//  Miliu
//
//  把一条下载失败原因翻译成「具名原因 + 一个能点的动作」。
//
//  背景：失败行原本只显示 error.localizedDescription 或一句中文原因。用户读到
//  「网站返回 403」时不知道该做什么——是登录？是链接过期？还是等一会儿？
//  这里给每个可识别的原因配**恰好一个**下一步动作，动作直接对应界面上已有的按钮
//  （重新获取链接 / 重试 / 导入登录态 / 去清理磁盘）。
//
//  设计来源：OmniGet 的 core/root_cause.rs（仅借鉴「原因→动作」这一条，
//  阈值与文案按密流现有失败路径重写；对方 GPL-3.0，本项目 MIT，代码零复制）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RDFailureAction) {
    /// 没有可建议的动作（未知失败）：如实说不知道，不编造原因。
    RDFailureActionNone = 0,
    /// 重新获取下载链接（对应行内「重试」按钮的链接刷新路径）。
    RDFailureActionRefreshLink,
    /// 直接重试（网络瞬断、响应截断）。
    RDFailureActionRetry,
    /// 导入浏览器登录态 / 在应用内浏览器里登录后重试。
    RDFailureActionSignIn,
    /// 清理磁盘空间。
    RDFailureActionFreeDiskSpace,
    /// 换网络或稍等（限流 / DNS 异常）。
    RDFailureActionWaitAndRetry,
};

typedef struct {
    /// 稳定的原因键（测试与日志用，不进界面文案）。
    __unsafe_unretained NSString *causeKey;
    RDFailureAction action;
} RDFailureDiagnosis;

/// 纯函数：输入失败原因（中文/英文皆可）与 HTTP 状态码（无则 0），
/// 输出具名原因与建议动作。识别不出返回 causeKey=nil, action=None。
/// 顺序即优先级：越具体的判据越靠前，避免把「需要登录」误判成「指纹被拒」。
FOUNDATION_EXPORT RDFailureDiagnosis RDDiagnoseFailure(NSString * _Nullable reason, NSInteger statusCode);

/// 动作对应的界面文案（一句话，中文）。
FOUNDATION_EXPORT NSString *RDFailureActionText(RDFailureAction action);

/// 把原因与建议拼成界面上一行文字。原始原因永远原样保留在最前面——
/// 用户已经在看的文案不变，建议只追加在后面。
FOUNDATION_EXPORT NSString *RDFailureMessageWithAdvice(NSString * _Nullable reason, NSInteger statusCode);

/// 量一串文字在界面上的宽度（由调用方提供字体，组件本身不依赖 AppKit）。
typedef CGFloat (^RDFailureTextMeasure)(NSString *text);

/// 按字素安全截断到给定宽度（不切坏 emoji 代理对）。仅截断，不加省略号。
FOUNDATION_EXPORT NSString *RDFailureTextTruncatedToWidth(NSString *text, CGFloat budget,
                                                          RDFailureTextMeasure measure);

/// 把「原因 · 建议」塞进一行可用宽度里。
///
/// 为什么必须做这件事（2026-11-05 实测）：建议文案最宽 259px，而下载行给失败
/// 原因的位置在**最小窗口**下只有 402px（760 宽窗口 → 列表 712 → 110 左侧状态
/// 栏 + 200 右侧按钮）。原先用尾部截断，**被切掉的正好是末尾的建议**——引导在
/// 最窄窗口下等于不存在。
///
/// 规则：放得下就原样返回；放不下就**保住建议**（动作比原因更该被看见），
/// 把原因从尾部按字素截断到剩余预算。建议本身都放不下时只显示建议。
/// measure 为 nil 或 maxWidth <= 0 时不做适配，原样返回。
FOUNDATION_EXPORT NSString *RDFailureTextFitted(NSString * _Nullable reason, NSInteger statusCode,
                                                CGFloat maxWidth, RDFailureTextMeasure _Nullable measure);

NS_ASSUME_NONNULL_END
