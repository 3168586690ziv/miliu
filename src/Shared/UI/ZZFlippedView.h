//
//  ZZFlippedView.h — 迁移自 App/SevenZZToolbox.m
//
//  系统记录中心：flipped 坐标 documentView。
//  NSScrollView 使用非 flipped documentView 时初始滚动位置可能在底部（时间线直接显示较早日期）。
//  flipped 视图使原点在左上角，首次进入即显示「今天/最新」记录；详情文档同理。
//
#import <Cocoa/Cocoa.h>

@interface ZZFlippedView : NSView
@end
