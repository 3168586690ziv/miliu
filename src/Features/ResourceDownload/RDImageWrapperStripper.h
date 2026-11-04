//
//  RDImageWrapperStripper.h
//  Miliu
//
//  剥掉 HLS 分片外面那层图片外壳。
//
//  有些站把每一条 .ts/.aac 分片前面接一张完整的 PNG/JPEG（防盗链手段），
//  播放器会自动跳过，但 ffmpeg 的 hls 解复用器会把它当成损坏数据，
//  结果是「分片全都下齐了，合流却报错」。
//
//  实现要点（与随手 indexOf 的差别都写在实现注释里）：
//  · PNG 按 chunk 表走到 IEND 之后，**不**搜字节串 IEND ——那四个字节会出现在
//    IDAT 压缩数据里，搜到就切会切在图片中间。
//  · JPEG 先严格验证 SOI 后的 marker 是不是真的 marker（0xFFD8FF 在随机字节里
//    大约每 1600 万条分片出现一次），验证通过才找 FFD9。
//  · 任何不确定的情况一律返回 0（原样输出）——切错比不切更糟。
//
//  设计来源：OmniGet 的 hls_downloader.rs 同名逻辑（思路借鉴，代码按本项目
//  现有风格重写；对方 GPL-3.0，本项目 MIT）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 返回外壳之后正文的起始偏移；没有可识别外壳、或外壳不完整时返回 0。
/// 纯函数，不读写磁盘。
NSUInteger RDImageWrapperPayloadOffset(NSData * _Nullable data);

/// 便捷入口：返回剥壳后的数据（无外壳时原样返回同一份数据对象，不复制）。
NSData *RDStripImageWrapper(NSData * _Nullable data);

NS_ASSUME_NONNULL_END
