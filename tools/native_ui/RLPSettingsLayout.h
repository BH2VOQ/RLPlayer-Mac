// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSettingsLayout.h — 设置页布局原语，逐项对齐 web 的 .sgroup/.sghead/.sgbody/.sfld。
//
// web 结构（ui_page.h:1214-1221）：
//   .sbody  { padding:0 24px 24px; overflow-y:auto; overflow-x:hidden }
//   .sgroup { margin-bottom:22px; border:1px solid var(--line); border-radius:12px;
//             background:var(--bg2) }
//   .sghead { padding:11px 16px; border-bottom:1px solid var(--line); font-weight:650;
//             font-size:12.5px; background:var(--bg3); border-radius:11px 11px 0 0 }
//   .sgbody { padding:14px 16px; display:grid;
//             grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); gap:14px 20px }
//   .sfld label { display:block; font-size:11px; color:var(--mut); margin-bottom:5px }
//   .sfld .hint { font-size:10.5px; color:var(--mut2); margin-top:4px }
//
// 为什么换掉旧布局：旧原生是「左标签 200px + 右控件」横排，且写死 520/560/620px 宽度。
// 窗口一窄就横向溢出（实测截图里数据源行被右边缘截断）。web 是**响应式列**：
// 宽度不够就减列，永不横向溢出。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 字段网格：按可用宽度决定列数（web repeat(auto-fill,minmax(260px,1fr))）。
@interface RLPFieldGrid : NSView
@property (nonatomic, readonly) NSInteger columnCount;
/// 最近一次布局算出的内容高度。
@property (nonatomic, readonly) CGFloat contentHeight;
- (void)addItem:(NSView *)item span:(BOOL)fullWidth;
/// 清空全部字段（按声道数重建「声道音量微调」这类动态内容时用）。
- (void)removeAllItems;
- (void)relayout;
@end

/// 一个设置分组卡片（web .sgroup）：标题条 + 响应式字段网格。
@interface RLPSettingsGroup : NSView
- (instancetype)initWithTitle:(NSString *)title hint:(nullable NSString *)hint;
/// 字段（web .sfld）：标签在上、控件在下、说明在最下。identifier 落在控件上。
- (void)addField:(NSString *)label control:(NSView *)control hint:(nullable NSString *)hint;
/// 整行字段（web .sfld.wide）：跨满所有列。返回该字段容器（需要按状态整块隐藏时用）。
- (NSView *)addWideField:(NSString *)label control:(NSView *)control hint:(nullable NSString *)hint;
/// 开关行（web .chk）：开关在左、文字在右。
- (void)addCheck:(NSString *)label control:(NSView *)control hint:(nullable NSString *)hint;
- (void)addButtonRow:(NSArray<NSView *> *)buttons;
- (void)addNote:(NSString *)text;
/// 清空卡片体内的全部字段/说明/按钮（用于按输出声道数重建声道微调）。
- (void)removeAllFields;
/// 子标题（web `.meta-card .mh.sub`：12.5/650 + 底部 1px 分隔线 + 下方 8pt 内边距）。
/// 用于同一张卡体内的第二段区块（如「AI 接入」卡里的「标签写回」）。
- (void)addSubHeader:(NSString *)title hint:(nullable NSString *)hint;
/// 调用方自带 identifier 的说明行（web `.hint`）——保住 parity 表里的 sp_wbdesc。
- (void)addNoteView:(NSTextField *)note;
- (void)addFullRow:(NSView *)view;
@property (nonatomic, readonly) NSInteger columnCount;
- (void)applyTheme;
/// 异步内容到达后显式调用一次，让卡片重算高度（不挂观察者，避免布局反馈环）。
- (void)contentDidChange;
@end

NS_ASSUME_NONNULL_END
