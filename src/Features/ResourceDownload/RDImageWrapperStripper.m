//
//  RDImageWrapperStripper.m
//  Miliu
//

#import "RDImageWrapperStripper.h"

static const unsigned char RD_PNG_SIGNATURE[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
static const unsigned char RD_JPEG_SIGNATURE[3] = {0xFF, 0xD8, 0xFF};

/// PNG 的结尾：走 chunk 表，而不是搜字节串。
/// 每个 chunk = 4 字节长度 + 4 字节类型 + 载荷 + 4 字节 CRC。
/// IEND 是四个普通字节，完全可能出现在 IDAT 的压缩数据里——字面搜索会切在
/// 图片中间，产出一个语法上「像分片」、实际不可解码的坏段。
static NSUInteger RDPNGPayloadOffset(NSData *data) {
    const unsigned char *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger at = sizeof(RD_PNG_SIGNATURE);
    while (YES) {
        if (at + 8 > length) return 0;                       // 头部都不完整
        uint32_t chunkLength = ((uint32_t)bytes[at] << 24) | ((uint32_t)bytes[at + 1] << 16) |
                               ((uint32_t)bytes[at + 2] << 8) | (uint32_t)bytes[at + 3];
        const unsigned char *kind = bytes + at + 4;
        unsigned long long next = (unsigned long long)at + 8ULL + chunkLength + 4ULL;
        if (next > length) return 0;                          // 越界：外壳不完整
        if (memcmp(kind, "IEND", 4) == 0) return (NSUInteger)next;
        at = (NSUInteger)next;
    }
}

/// JPEG 的结尾：第一个 FFD9。熵编码数据会转义自己的 0xFF，所以字面 FFD9
/// 在 JPEG 里确实是结尾；风险在于「随机字节恰好以 FFD8FF 开头」，
/// 所以入口先做一次 marker 校验。
static BOOL RDLooksLikeJPEG(NSData *data) {
    if (data.length < 4) return NO;
    const unsigned char *bytes = data.bytes;
    if (memcmp(bytes, RD_JPEG_SIGNATURE, sizeof(RD_JPEG_SIGNATURE)) != 0) return NO;
    // SOI 之后的那个字节是 marker 码：APPn/DQT/DHT/SOF/COM 等。
    // 不可能是 0x00（填充字节）、0xFF（填充）、0xD8（又一个 SOI）。
    unsigned char marker = bytes[3];
    return (marker >= 0xC0 && marker <= 0xCF) || marker == 0xDB || marker == 0xDD ||
           (marker >= 0xE0 && marker <= 0xEF) || marker == 0xFE;
}

static NSUInteger RDJPEGPayloadOffset(NSData *data) {
    const unsigned char *bytes = data.bytes;
    NSUInteger length = data.length;
    for (NSUInteger i = sizeof(RD_JPEG_SIGNATURE); i + 1 < length; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) return i + 2;
    }
    return 0;
}

NSUInteger RDImageWrapperPayloadOffset(NSData *data) {
    if (data.length < 16) return 0;
    NSUInteger start = 0;
    if (memcmp(data.bytes, RD_PNG_SIGNATURE, sizeof(RD_PNG_SIGNATURE)) == 0) {
        start = RDPNGPayloadOffset(data);
    } else if (RDLooksLikeJPEG(data)) {
        start = RDJPEGPayloadOffset(data);
    } else {
        return 0;
    }
    // 只有图片、没有正文的「分片」无法挽救：返回 0，交给上层按原样处理，
    // 由长度/MIME 校验去拒绝它——绝不返回一个空正文让合流产出坏文件。
    if (start == 0 || start >= data.length) return 0;
    return start;
}

NSData *RDStripImageWrapper(NSData *data) {
    NSUInteger offset = RDImageWrapperPayloadOffset(data);
    if (offset == 0) return data ?: [NSData data];
    return [data subdataWithRange:NSMakeRange(offset, data.length - offset)];
}
