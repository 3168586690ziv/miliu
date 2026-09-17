//
//  WorkspaceChoiceButton.h — 迁移自 App/SevenZZToolbox.m
//
//  工作区选择卡片按钮：标题/详情/强调色/SF Symbol，hover 发光。
//
#import <Cocoa/Cocoa.h>

@interface WorkspaceChoiceButton : NSButton
@property(copy) NSString *cardTitle;
@property(copy) NSString *cardDetail;
@property(strong) NSColor *accent;
@property(strong) NSImage *symbolImage;
@property(strong) NSTrackingArea *hoverArea;
@property(nonatomic) BOOL hovered;
@end
