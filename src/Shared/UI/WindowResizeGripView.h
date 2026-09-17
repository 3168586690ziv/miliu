//
//  WindowResizeGripView.h — 迁移自 App/SevenZZToolbox.m
//
//  窗口边缘缩放握把：按 directions 组合方向拖动窗口边缘。
//
#import <Cocoa/Cocoa.h>

typedef NS_OPTIONS(NSUInteger, WindowResizeDirections) {
    WindowResizeLeft   = 1 << 0,
    WindowResizeRight  = 1 << 1,
    WindowResizeBottom = 1 << 2,
    WindowResizeTop    = 1 << 3,
};

@interface WindowResizeGripView : NSView
@property(nonatomic) WindowResizeDirections directions;
@end
