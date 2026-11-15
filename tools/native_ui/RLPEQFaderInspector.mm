// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPEQFaderInspector.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

static const CGFloat kInspH = 30.0;

@implementation RLPEQFaderInspector {
    NSTextField *_freqLabel;
    NSTextField *_qField;
    NSPopUpButton *_typePopup;
    NSButton *_enableSwitch;
}
// 自定义 setter 用到了 _freqText/_q/_typeCode/_bandEnabled，必须显式合成后备 ivar
@synthesize bandIndex = _bandIndex;
@synthesize freqText = _freqText;
@synthesize q = _q;
@synthesize typeCode = _typeCode;
@synthesize bandEnabled = _bandEnabled;

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    _bandIndex = -1;
    RLPTheme *t = [RLPTheme current];

    _enableSwitch = [[NSButton alloc] initWithFrame:NSZeroRect];
    _enableSwitch.buttonType = NSButtonTypeSwitch;
    _enableSwitch.title = @"";
    _enableSwitch.target = self;
    _enableSwitch.action = @selector(onEnable:);
    _enableSwitch.toolTip = RLPTr(@"启用/停用这一段");
    _enableSwitch.identifier = @"eq.insp.enable";
    [self addSubview:_enableSwitch];

    _freqLabel = RLPLabel(@"", [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold],
                          t.text);
    _freqLabel.identifier = @"eq.insp.freq";
    [self addSubview:_freqLabel];

    NSTextField *ql = RLPLabel(@"Q", t.small, t.mut);
    [self addSubview:ql];
    _qField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _qField.identifier = @"eq.insp.q";
    _qField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _qField.alignment = NSTextAlignmentCenter;
    _qField.target = self;
    _qField.action = @selector(onQ:);
    _qField.toolTip = RLPTr(@"品质因数 Q（0.1–20）");
    [self addSubview:_qField];

    NSTextField *tl = RLPLabel(RLPTr(@"类型"), t.small, t.mut);
    [self addSubview:tl];
    _typePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _typePopup.identifier = @"eq.insp.type";
    // 与后端契约同码（PK / LS / HS），显示给人看的是名字。
    [_typePopup addItemWithTitle:RLPTr(@"峰值 PK")];
    [_typePopup addItemWithTitle:RLPTr(@"低架 LS")];
    [_typePopup addItemWithTitle:RLPTr(@"高架 HS")];
    _typePopup.target = self;
    _typePopup.action = @selector(onType:);
    [self addSubview:_typePopup];

    // 手排一行（不用 NSStackView：这一行要精确控制每个控件的位置与宽度）
    const CGFloat y = 4;
    _enableSwitch.frame = NSMakeRect(0, y, 22, kInspH - 8);
    ql.frame = NSMakeRect(30, y + 2, 16, 16);
    _qField.frame = NSMakeRect(48, y, 66, kInspH - 10);
    tl.frame = NSMakeRect(124, y + 2, 34, 16);
    _typePopup.frame = NSMakeRect(160, y - 1, 118, kInspH - 6);
    _freqLabel.frame = NSMakeRect(290, y + 1, 120, 18);
    return self;
}

- (void)setBandIndex:(NSInteger)bandIndex {
    _bandIndex = bandIndex;
    self.hidden = (bandIndex < 0);
}

- (void)setFreqText:(NSString *)freqText {
    _freqText = [freqText copy];
    _freqLabel.stringValue = freqText ?: @"";
}
- (NSString *)freqText { return _freqText; }

- (void)setQ:(double)q { _q = q; [self syncValues]; }
- (void)setTypeCode:(NSString *)typeCode { _typeCode = [typeCode copy]; [self syncValues]; }
- (void)setBandEnabled:(BOOL)bandEnabled { _bandEnabled = bandEnabled; [self syncValues]; }

- (void)syncValues {
    // 正在编辑 Q 的时候不要覆盖用户输入
    NSWindow *win = [self window];
    if (!(win && win.firstResponder && (win.firstResponder == _qField ||
          win.firstResponder == [_qField currentEditor]))) {
        _qField.stringValue = [NSString stringWithFormat:@"%.2f", _q];
    }
    const NSInteger idx = [self typeIndexForCode:_typeCode];
    if (idx >= 0 && idx < (NSInteger)_typePopup.numberOfItems)
        [_typePopup selectItemAtIndex:idx];
    _enableSwitch.state = _bandEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (NSInteger)typeIndexForCode:(NSString *)code {
    if ([code isEqualToString:@"LS"]) return 1;
    if ([code isEqualToString:@"HS"]) return 2;
    return 0;   // PK
}

- (NSTextField *)qField { return _qField; }
- (NSPopUpButton *)typePopup { return _typePopup; }
- (NSButton *)enableSwitch { return _enableSwitch; }

- (void)onQ:(NSTextField *)f {
    if (self.bandIndex < 0 || !self.onQChanged) return;
    double v = f.doubleValue;
    if (!isfinite(v)) v = 1.41;
    v = MAX(0.1, MIN(20.0, v));
    f.stringValue = [NSString stringWithFormat:@"%.2f", v];
    self.onQChanged(self.bandIndex, v);
}

- (void)onType:(NSPopUpButton *)p {
    if (self.bandIndex < 0 || !self.onTypeChanged) return;
    NSArray<NSString *> *codes = @[ @"PK", @"LS", @"HS" ];
    const NSInteger i = p.indexOfSelectedItem;
    if (i < 0 || i >= (NSInteger)codes.count) return;
    self.onTypeChanged(self.bandIndex, codes[(NSUInteger)i]);
}

- (void)onEnable:(NSButton *)s {
    if (self.bandIndex < 0 || !self.onEnabledChanged) return;
    self.onEnabledChanged(self.bandIndex, s.state == NSControlStateValueOn);
}

@end
