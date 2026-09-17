//
//  DoorIntroView.h — 迁移自 App/SevenZZToolbox.m
//
//  启动门扉动画视图：progress 0→1 驱动开门/流光/齿轮动画；
//  progress==0 时点击中央钥匙区域触发 openAction。
//
#import <Cocoa/Cocoa.h>

@interface DoorIntroView : NSView
@property(nonatomic) CGFloat progress;
@property(nonatomic,weak) id openTarget;
@property(nonatomic) SEL openAction;
@end
