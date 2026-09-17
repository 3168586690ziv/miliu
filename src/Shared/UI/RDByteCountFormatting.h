#pragma once
#import <Foundation/Foundation.h>

static inline NSString *RDFormatByteCount(int64_t bytes) {
    if (bytes <= 0) return @"0 B";
    return [NSByteCountFormatter stringFromByteCount:bytes
                                        countStyle:NSByteCountFormatterCountStyleFile];
}
