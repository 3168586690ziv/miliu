//
//  MoodIconActionView.h — 迁移自 App/SevenZZToolbox.m
//
//  心情页图标动作视图：绘制图标并转发点击事件。
//
#import <Cocoa/Cocoa.h>

@interface MoodIconActionView : NSView
@property (strong) NSImage *image;
@property (weak) id target;
@property SEL action;
@property(nonatomic) BOOL enabled;
@end
