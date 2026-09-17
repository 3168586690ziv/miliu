//
//  MoodAmbientBackdropView.h — 迁移自 App/SevenZZToolbox.m
//
//  心情页背景浮动氛围的承载视图：对鼠标完全透明（hitTest→nil），
//  绝不遮挡按钮/文字/抽签结果或影响点击；仅承载低透明度柔和光团 CALayer。
//
#import <Cocoa/Cocoa.h>

@interface MoodAmbientBackdropView : NSView
@end
