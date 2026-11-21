// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_listening_contract.mm — 原生聆听室重设计契约判据（v3.3.11 对齐）
//
// 覆盖：
//   C1 真实 /api/filters 注册表 + Windows 语义听音风格映射（不按最大 gauss taps 碰运气）
//   C2 切风格同一次 POST 清除 taps/mintapsperinput/atten/transition/phase/filterNx 并写后读回
//   C3 presetStatusForCapsJSON / gatingForCapsJSON 按 CoreAudio/DoP/shared/AirPlay/UPnP/null 与播放态给出结果与禁用原因
//   C4 bitperfect 下风格禁用且有说明，不偷偷破坏直通
//   C5 真实几何自适应（宽 4 列 / 中 2 列 / 窄 1 列，四卡等宽；队列预览 ≤4 行且内部无嵌套滚动；页头音乐文件夹入口）
//
// 纪律：隔离 state/library；backend=null、volume=-120；不启动真实 app 服务、不碰 8899、不模拟键鼠。
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPListeningRoom.h"
#import "RLPModels.h"
#import "RLPQuickStartViewController.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <string>
#include <thread>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

namespace rlapp {
void set_upnp_caps_probe_override_for_test(bool active, bool ok,
                                            const std::string& friendlyName,
                                            const std::string& sink,
                                            const std::string& error);
void reset_preset_probe_counts_for_test();
int  preset_coreaudio_probe_count_for_test();
}

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}

static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectViews(s, out);
}

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}

@interface RLPQuickStartViewController (ContractTest)
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, copy, nullable) NSString *defaultDeviceName;
@property (nonatomic, strong) NSTextField *styleValue;
@property (nonatomic, strong) NSTextField *styleSub;
@property (nonatomic, strong) NSView *styleCard;
@property (nonatomic, strong) NSTextField *outputValue;
@property (nonatomic, strong) NSTextField *playValue;
@property (nonatomic, strong) NSTextField *playSub;
@property (nonatomic, strong) NSTextField *capsInfoLabel;
@property (nonatomic, strong) NSTextField *capsPcmBadge;
@property (nonatomic, strong) NSTextField *capsDsdBadge;
@property (nonatomic, strong) NSTextField *presetNotes;
@property (nonatomic, copy, nullable) NSDictionary *presetCapsJSON;
@property (nonatomic, copy, nullable) NSString *presetCapsKey;
@property (nonatomic, assign) NSUInteger presetCapsSeq;
@property (nonatomic, copy, nullable) NSString *presetCapsDevice;
@property (nonatomic, copy, nullable) NSString *localDevice;
@property (nonatomic, strong, nullable) NSPopover *popover;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) BOOL pausedNow;
@property (nonatomic, strong) NSView *cardsContainer;
@property (nonatomic, strong) NSStackView *albumRow;
@property (nonatomic, strong) RLPCoverImageView *npCover;
@property (nonatomic, strong) NSTextField *npTitle;
@property (nonatomic, strong) NSTextField *npSub;
@property (nonatomic, strong) NSButton *npOpenButton;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, copy, nullable) NSDictionary *lastMetaDict;
@property (nonatomic, copy) NSArray<RLPAlbum *> *albumsData;
@property (nonatomic, assign) NSInteger currentCardColumns;
@property (nonatomic, assign) NSInteger currentAlbumColumns;
@property (nonatomic, strong) NSStackView *queueList;
@property (nonatomic, strong) NSMutableArray<NSView *> *queueRowSurfaces;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *queueRowCurrentFlags;
@property (nonatomic, weak, nullable) NSTextField *queueEmptyLabel;
@property (nonatomic, copy) NSArray<NSString *> *queuePaths;
@property (nonatomic, assign) NSInteger queueCurrentIndex;
+ (NSDictionary<NSString *, NSString *> *)playModeFeedbackForNotes:(NSArray * _Nullable)notes
                                                  playbackActive:(BOOL)active;
- (void)applyPresetCaps:(NSDictionary * _Nullable)json;
- (NSString *)currentPresetCapsKey;
- (NSUInteger)beginPresetCapsRequestWithKey:(NSString *)key;
- (BOOL)completePresetCaps:(NSDictionary * _Nullable)json seq:(NSUInteger)seq key:(NSString *)key;
- (void)syncCapabilitiesUI;
- (void)syncOutputSummary;
- (void)syncPlayAndStyleCards;
- (void)onPickStyle:(NSButton *)sender;
- (void)onPickPlayMode:(NSButton *)sender;
- (void)onOpenOutput:(id)sender;
- (void)onPickBackend:(NSButton *)sender;
- (void)onApplyUpnpOutput:(id)sender;
- (void)applyCastDevicesPayload:(NSDictionary * _Nullable)json;
- (void)reloadSettings;
- (void)reloadQueue;
- (void)applyStatusJSON:(NSDictionary *)json;
- (void)activate;
- (void)viewDidDisappear;
- (void)rebuildAlbumGrid;
- (void)renderQueueFromJSON:(NSDictionary * _Nullable)json;
- (void)updateResponsiveLayoutForWidth:(CGFloat)availWidth;
- (void)applyLanguage;
- (void)onOpenCurrentAlbum:(id)sender;
@end

class TestLoopbackUpnpRenderer {
public:
    std::string friendlyName = "Living Room DAC";
    std::string sink;
    std::atomic<int> descHits{0};
    std::atomic<int> cmHits{0};

    TestLoopbackUpnpRenderer(const std::string& name, const std::string& sinkStr)
        : friendlyName(name), sink(sinkStr) {}
    ~TestLoopbackUpnpRenderer() { stop(); }

    bool start() {
        fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd_ < 0) return false;
        int yes = 1;
        ::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;
        if (::bind(fd_, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) != 0 ||
            ::listen(fd_, 16) != 0) {
            ::close(fd_);
            fd_ = -1;
            return false;
        }
        socklen_t len = sizeof(addr);
        if (::getsockname(fd_, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
            ::close(fd_);
            fd_ = -1;
            return false;
        }
        port_ = ntohs(addr.sin_port);
        stopReq_.store(false);
        th_ = std::thread([this] { serveLoop(); });
        return true;
    }

    void stop() {
        stopReq_.store(true);
        if (fd_ >= 0) {
            ::shutdown(fd_, SHUT_RDWR);
            ::close(fd_);
            fd_ = -1;
        }
        if (th_.joinable()) th_.join();
    }

    std::string descURL() const {
        return "http://127.0.0.1:" + std::to_string(port_) + "/desc.xml";
    }

private:
    int fd_ = -1;
    uint16_t port_ = 0;
    std::atomic<bool> stopReq_{false};
    std::thread th_;

    void serveLoop() {
        while (!stopReq_.load() && fd_ >= 0) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(fd_, &rfds);
            timeval tv{0, 50000};
            const int sr = ::select(fd_ + 1, &rfds, nullptr, nullptr, &tv);
            if (sr <= 0 || !FD_ISSET(fd_, &rfds)) continue;
            sockaddr_in cli{};
            socklen_t clen = sizeof(cli);
            const int cfd = ::accept(fd_, reinterpret_cast<sockaddr*>(&cli), &clen);
            if (cfd < 0) continue;
            timeval rtv{0, 400000};
            ::setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));
            std::string req;
            char buf[2048];
            while (true) {
                const ssize_t n = ::recv(cfd, buf, sizeof(buf), 0);
                if (n <= 0) break;
                req.append(buf, (size_t)n);
                const size_t hdrEnd = req.find("\r\n\r\n");
                if (hdrEnd != std::string::npos) {
                    size_t cl = 0;
                    const size_t pos = req.find("Content-Length:");
                    const size_t posL = req.find("content-length:");
                    const size_t p = (pos != std::string::npos) ? pos : posL;
                    if (p != std::string::npos && p < hdrEnd) {
                        cl = (size_t)std::strtoul(req.c_str() + p + 15, nullptr, 10);
                    }
                    if (req.size() >= hdrEnd + 4 + cl) break;
                }
            }
            std::string body;
            std::string status = "200 OK";
            if (req.rfind("GET /desc.xml", 0) == 0) {
                ++descHits;
                body = "<?xml version=\"1.0\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\">"
                       "<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>"
                       "<friendlyName>" + friendlyName + "</friendlyName>"
                       "<modelName>MockRenderer 192</modelName>"
                       "<UDN>uuid:mock-living-room-dac</UDN>"
                       "<serviceList>"
                       "<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/upnp/avt</controlURL></service>"
                       "<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/upnp/cm</controlURL></service>"
                       "</serviceList></device></root>";
            } else if (req.rfind("POST /upnp/cm", 0) == 0) {
                ++cmHits;
                body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                       "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
                       "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
                       "<s:Body><u:GetProtocolInfoResponse xmlns:u=\"urn:schemas-upnp-org:service:ConnectionManager:1\">"
                       "<Source></Source><Sink>" + sink + "</Sink>"
                       "</u:GetProtocolInfoResponse></s:Body></s:Envelope>";
            } else {
                status = "404 Not Found";
                body = "not found";
            }
            const std::string resp =
                "HTTP/1.1 " + status + "\r\nContent-Type: text/xml; charset=utf-8\r\n"
                "Content-Length: " + std::to_string(body.size()) +
                "\r\nConnection: close\r\n\r\n" + body;
            size_t off = 0;
            while (off < resp.size()) {
                const ssize_t w = ::send(cfd, resp.data() + off, resp.size() - off, 0);
                if (w <= 0) break;
                off += (size_t)w;
            }
            ::close(cfd);
        }
    }
};

// Keep output selection tests offline: discovery is explicitly stubbed.
@interface RLPOfflineOutputController : RLPQuickStartViewController
@end
@implementation RLPOfflineOutputController
- (void)discoverCastDevicesForce:(BOOL)force { (void)force; }
- (void)showPopoverFrom:(NSView *)anchor withCard:(NSView *)card width:(CGFloat)width minH:(CGFloat)height {
    (void)anchor;
    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = RLPCardController(card, width, height);
    [self.popover.contentViewController.view layoutSubtreeIfNeeded];
}
@end

static void TestMountedRoomGeometry() {
    RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 620)
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
    NSView *host = win.contentView;
    [host addSubview:vc.view];
    vc.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [vc.view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [vc.view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [vc.view.topAnchor constraintEqualToAnchor:host.topAnchor],
        [vc.view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    CollectViews(vc.view, views);
    NSScrollView *scroll = nil;
    for (NSView *view in views) {
        if ([view isKindOfClass:[NSScrollView class]]) { scroll = (NSScrollView *)view; break; }
    }
    NSView *first = FindById(vc.view, @"room.device");
    NSView *last = FindById(vc.view, @"room.style");
    CK(scroll && first && last, "Mounted room has a scroll view and control cards", @"");
    if (!scroll || !first || !last) return;
    for (NSNumber *width in @[@1180, @674, @954, @574, @820, @360, @1180]) {
        const CGFloat w = width.doubleValue;
        [win setContentSize:NSMakeSize(w, 620)];
        [host layoutSubtreeIfNeeded];
        [host layoutSubtreeIfNeeded];
        NSRect a = [first convertRect:first.bounds toView:scroll.documentView];
        NSRect b = [last convertRect:last.bounds toView:scroll.documentView];
        const BOOL sameRow = std::fabs(NSMaxY(a) - NSMaxY(b)) < 1.5;
        const CGFloat clipWidth = NSWidth(scroll.contentView.bounds);
        CK(std::fabs(NSWidth(scroll.frame) - w) < 1.5 &&
           std::fabs(NSWidth(scroll.documentView.frame) - clipWidth) < 1.5 &&
           NSWidth(a) > 0 && NSWidth(b) > 0 && NSMaxX(a) <= clipWidth + 1 && NSMaxX(b) <= clipWidth + 1 &&
           sameRow == (w > 798.0), "Mounted room resize fits viewport and selects expected card rows",
           [NSString stringWithFormat:@"requested=%.1f host=%@ page=%@ scroll=%@ clip=%.1f doc=%@ first=%@ last=%@",
            w, NSStringFromRect(host.frame), NSStringFromRect(vc.view.frame), NSStringFromRect(scroll.frame), clipWidth, NSStringFromRect(scroll.documentView.frame),
            NSStringFromRect(a), NSStringFromRect(b)]);
    }
}

static void CollectByIdPrefix(NSView *root, NSString *prefix, NSMutableArray<NSView *> *out) {
    if (!root) return;
    if ([root.identifier hasPrefix:prefix]) [out addObject:root];
    for (NSView *s in root.subviews) CollectByIdPrefix(s, prefix, out);
}

static NSScrollView *FindRoomScrollView(NSView *root) {
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    CollectViews(root, views);
    for (NSView *v in views) {
        if ([v isKindOfClass:[NSScrollView class]]) return (NSScrollView *)v;
    }
    return nil;
}

static NSString *DescribeCGColor(CGColorRef cg) {
    if (!cg) return @"nil";
    NSColor *c = [[NSColor colorWithCGColor:cg] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!c) return @"non-srgb";
    return [NSString stringWithFormat:@"rgba(%d,%d,%d,%.2f)",
            (int)std::lround(c.redComponent * 255.0),
            (int)std::lround(c.greenComponent * 255.0),
            (int)std::lround(c.blueComponent * 255.0),
            c.alphaComponent];
}

static BOOL CGColorsRoughlyEqual(CGColorRef a, CGColorRef b) {
    if (!a && !b) return YES;
    if (!a || !b) return NO;
    NSColor *ca = [[NSColor colorWithCGColor:a] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *cb = [[NSColor colorWithCGColor:b] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!ca || !cb) return CGColorEqualToColor(a, b);
    return std::fabs(ca.redComponent - cb.redComponent) < 0.01 &&
           std::fabs(ca.greenComponent - cb.greenComponent) < 0.01 &&
           std::fabs(ca.blueComponent - cb.blueComponent) < 0.01 &&
           std::fabs(ca.alphaComponent - cb.alphaComponent) < 0.01;
}

typedef void (*RLPAddCursorRectImp)(id, SEL, NSRect, NSCursor *);
static RLPAddCursorRectImp gOrigAddCursorRect = NULL;
static BOOL gCapturedHandCursor = NO;
static NSView *gCursorTargetView = nil;

static void RLPTestAddCursorRect(id self, SEL _cmd, NSRect rect, NSCursor *cursor) {
    if (self == gCursorTargetView && cursor == [NSCursor pointingHandCursor] &&
        rect.size.width > 0.0 && rect.size.height > 0.0) {
        gCapturedHandCursor = YES;
    }
    if (gOrigAddCursorRect) gOrigAddCursorRect(self, _cmd, rect, cursor);
}

static BOOL CheckViewHasHandCursor(NSView *view) {
    Method m = class_getInstanceMethod([NSView class], @selector(addCursorRect:cursor:));
    gOrigAddCursorRect = (RLPAddCursorRectImp)method_getImplementation(m);
    gCapturedHandCursor = NO;
    gCursorTargetView = view;
    method_setImplementation(m, (IMP)RLPTestAddCursorRect);
    @try {
        [view resetCursorRects];
    } @finally {
        method_setImplementation(m, (IMP)gOrigAddCursorRect);
        gOrigAddCursorRect = NULL;
        gCursorTargetView = nil;
    }
    return gCapturedHandCursor;
}

@interface RLPCardClickSpy : NSObject
@property (nonatomic, assign) NSInteger hits;
- (void)onCardAction:(id)sender;
@end

@implementation RLPCardClickSpy
- (void)onCardAction:(id)sender {
    (void)sender;
    ++self.hits;
}
@end

static void TestListeningRoomButtonAffordance() {
    std::printf("=== TestListeningRoomButtonAffordance（按钮感/hover/光标/chevron/≥28pt/可点卡区分）===\n");
    NSString *origTheme = [RLPTheme themeName];

    for (NSString *theme in @[@"dark", @"light"]) {
        [RLPTheme setThemeName:theme];
        RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
        (void)vc.view;
        [vc rebuildAlbumGrid]; // 空态卡片与空态按钮一并检查

        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 760)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
        NSView *host = win.contentView;
        [host addSubview:vc.view];
        vc.view.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [vc.view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
            [vc.view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
            [vc.view.topAnchor constraintEqualToAnchor:host.topAnchor],
            [vc.view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        ]];

        for (NSNumber *wn in @[@1180, @900]) {
            const CGFloat w = wn.doubleValue;
            [win setContentSize:NSMakeSize(w, w > 1000 ? 760.0 : 600.0)];
            [host layoutSubtreeIfNeeded];
            [host layoutSubtreeIfNeeded];

            NSArray<NSArray *> *specs = @[
                @[@"room.folders",        @"room.folders.chevron",        @YES, @"音乐文件夹"],
                @[@"room.deviceRefresh",  @"",                            @NO,  @"设备刷新"],
                @[@"room.devicePopup",    @"room.devicePopup.chevron",    @YES, @"设备下拉"],
                @[@"room.output.button",  @"room.output.chevron",         @YES, @"输出入口"],
                @[@"room.play.button",    @"room.play.chevron",           @YES, @"播放入口"],
                @[@"room.style.button",   @"room.style.chevron",          @YES, @"听音风格入口"],
                @[@"room.playToggle",     @"",                            @NO,  @"继续播放"],
                @[@"room.openAlbum",      @"room.openAlbum.chevron",      @YES, @"打开专辑页"],
                @[@"room.queueAll",       @"room.queueAll.chevron",       @YES, @"查看全部"],
                @[@"room.openAlbums",     @"room.openAlbums.chevron",     @YES, @"打开音乐库"],
                @[@"room.libraryAction",  @"room.libraryAction.chevron",  @YES, @"添加音乐目录"],
                @[@"room.more",           @"room.more.chevron",           @YES, @"更多"],
                @[@"room.albumEmptyAction", @"room.albumEmptyAction.chevron", @YES, @"空态添加目录"],
            ];

            for (NSArray *sp in specs) {
                NSString *bid = sp[0];
                NSString *cid = sp[1];
                const BOOL needChev = [sp[2] boolValue];
                NSString *label = sp[3];
                NSView *ctrl = FindById(vc.view, bid);
                CK(ctrl != nil && !ctrl.hidden,
                   [[NSString stringWithFormat:@"BTN[%@:%d] %@ (%@) 存在且可见", theme, (int)w, label, bid] UTF8String],
                   @"nil or hidden");
                if (!ctrl) continue;

                const NSRect fr = ctrl.frame;
                const BOOL sizeOk = (NSHeight(fr) >= 28.0 && NSWidth(fr) >= 28.0);
                CGColorRef bg = ctrl.layer ? ctrl.layer.backgroundColor : NULL;
                CGColorRef bd = ctrl.layer ? ctrl.layer.borderColor : NULL;
                const CGFloat bw = ctrl.layer ? ctrl.layer.borderWidth : 0.0;
                const CGFloat cr = ctrl.layer ? ctrl.layer.cornerRadius : 0.0;
                const BOOL bgOk = (ctrl.wantsLayer && bg != NULL && CGColorGetAlpha(bg) > 0.01);
                const BOOL bdOk = (ctrl.wantsLayer && bw >= 1.0 && bd != NULL && CGColorGetAlpha(bd) > 0.01 && cr >= 4.0);
                const BOOL trackOk = (ctrl.trackingAreas.count >= 1);
                const BOOL handOk = CheckViewHasHandCursor(ctrl);

                // 验证真实 hover 状态切换：mouseEntered 变色，mouseExited 恢复
                NSColor *restBg = bg ? [NSColor colorWithCGColor:bg] : nil;
                NSColor *restBd = bd ? [NSColor colorWithCGColor:bd] : nil;
                NSEvent *enterEv = [NSEvent enterExitEventWithType:NSEventTypeMouseEntered
                                                          location:NSZeroPoint
                                                     modifierFlags:0
                                                         timestamp:0
                                                      windowNumber:win.windowNumber
                                                           context:nil
                                                       eventNumber:0
                                                    trackingNumber:0
                                                          userData:NULL];
                NSEvent *exitEv = [NSEvent enterExitEventWithType:NSEventTypeMouseExited
                                                         location:NSZeroPoint
                                                    modifierFlags:0
                                                        timestamp:0
                                                     windowNumber:win.windowNumber
                                                          context:nil
                                                      eventNumber:0
                                                   trackingNumber:0
                                                         userData:NULL];
                [ctrl mouseEntered:enterEv];
                CGColorRef hovBg = ctrl.layer ? ctrl.layer.backgroundColor : NULL;
                CGColorRef hovBd = ctrl.layer ? ctrl.layer.borderColor : NULL;
                const CGFloat hovBw = ctrl.layer ? ctrl.layer.borderWidth : 0.0;
                const BOOL hoverChanged = (!CGColorsRoughlyEqual(restBg.CGColor, hovBg) ||
                                           !CGColorsRoughlyEqual(restBd.CGColor, hovBd) ||
                                           std::fabs(hovBw - bw) >= 0.2);
                [ctrl mouseExited:exitEv];
                CGColorRef afterBg = ctrl.layer ? ctrl.layer.backgroundColor : NULL;
                CGColorRef afterBd = ctrl.layer ? ctrl.layer.borderColor : NULL;
                const CGFloat afterBw = ctrl.layer ? ctrl.layer.borderWidth : 0.0;
                const BOOL hoverRestored = CGColorsRoughlyEqual(restBg.CGColor, afterBg) &&
                                           CGColorsRoughlyEqual(restBd.CGColor, afterBd) &&
                                           std::fabs(afterBw - bw) < 0.05;

                BOOL chevOk = YES;
                NSString *chevInfo = @"n/a";
                if (needChev) {
                    NSView *chev = FindById(ctrl, cid);
                    if (!chev || chev.hidden || chev.alphaValue <= 0.5 ||
                        NSWidth(chev.frame) <= 0.0 || NSHeight(chev.frame) <= 0.0) {
                        chevOk = NO;
                        chevInfo = chev ? [NSString stringWithFormat:@"hidden=%d frame=%@", chev.hidden, NSStringFromRect(chev.frame)] : @"missing";
                    } else {
                        NSRect cf = [chev convertRect:chev.bounds toView:ctrl];
                        const BOOL inside = NSContainsRect(NSInsetRect(ctrl.bounds, -1.0, -1.0), cf);
                        const BOOL onRight = NSMidX(cf) > NSMidX(ctrl.bounds);
                        chevOk = inside && onRight;
                        chevInfo = NSStringFromRect(cf);
                    }
                }

                std::printf("  [BTN %-5s w=%4d %-22s] frame=%s h=%.1f bg=%s border=%s(w=%.1f,r=%.1f) track=%lu hand=%d hov=%d/%d chev=%s\n",
                            theme.UTF8String, (int)w, bid.UTF8String,
                            NSStringFromRect(fr).UTF8String, NSHeight(fr),
                            DescribeCGColor(bg).UTF8String, DescribeCGColor(bd).UTF8String, bw, cr,
                            (unsigned long)ctrl.trackingAreas.count, handOk, hoverChanged, hoverRestored,
                            chevInfo.UTF8String);

                CK(sizeOk && bgOk && bdOk && trackOk && handOk && hoverChanged && hoverRestored && chevOk,
                   [[NSString stringWithFormat:@"BTN[%@:%d] %@ 满足按钮感/≥28pt/描边/hover/手型/chevron", theme, (int)w, bid] UTF8String],
                   [NSString stringWithFormat:@"h=%.1f bgOk=%d bdOk=%d track=%lu hand=%d hov=%d/%d chevOk=%d(%@)",
                    NSHeight(fr), bgOk, bdOk, (unsigned long)ctrl.trackingAreas.count, handOk,
                    hoverChanged, hoverRestored, chevOk, chevInfo]);
            }

            // 整卡可点 vs 纯展示 / 混合下拉卡片区分
            NSView *capsCard = FindById(vc.view, @"room.caps");
            NSView *devCard  = FindById(vc.view, @"room.device");
            NSView *outCard  = FindById(vc.view, @"room.output");
            NSView *playCard = FindById(vc.view, @"room.play");
            NSView *styCard  = FindById(vc.view, @"room.style");
            CK(capsCard && devCard && outCard && playCard && styCard,
               [[NSString stringWithFormat:@"CARD[%@:%d] 四张控制卡与能力展示卡存在", theme, (int)w] UTF8String], @"");
            if (capsCard && devCard && outCard && playCard && styCard) {
                const BOOL capsPassive = (capsCard.trackingAreas.count == 0) && !CheckViewHasHandCursor(capsCard);
                const BOOL devPassiveShell = (devCard.trackingAreas.count == 0) && !CheckViewHasHandCursor(devCard);
                CK(capsPassive && devPassiveShell,
                   [[NSString stringWithFormat:@"CARD[%@:%d] 纯展示卡(room.caps)与含下拉容器卡(room.device)外壳无整卡手型误触", theme, (int)w] UTF8String],
                   [NSString stringWithFormat:@"capsTrack=%lu devTrack=%lu",
                    (unsigned long)capsCard.trackingAreas.count, (unsigned long)devCard.trackingAreas.count]);

                for (NSView *ic in @[outCard, playCard, styCard]) {
                    CGColorRef restBorder = ic.layer.borderColor;
                    CGColorRef capsBorder = capsCard.layer.borderColor;
                    const BOOL distinctRest = !CGColorsRoughlyEqual(restBorder, capsBorder);
                    const BOOL icTrack = ic.trackingAreas.count >= 1;
                    const BOOL icHand = CheckViewHasHandCursor(ic);
                    [ic mouseEntered:[NSEvent enterExitEventWithType:NSEventTypeMouseEntered
                                                            location:NSZeroPoint
                                                       modifierFlags:0
                                                           timestamp:0
                                                        windowNumber:win.windowNumber
                                                             context:nil
                                                         eventNumber:0
                                                      trackingNumber:0
                                                            userData:NULL]];
                    const BOOL icHover = (ic.layer.borderWidth >= 1.4) && !CGColorsRoughlyEqual(restBorder, ic.layer.borderColor);
                    [ic mouseExited:[NSEvent enterExitEventWithType:NSEventTypeMouseExited
                                                           location:NSZeroPoint
                                                      modifierFlags:0
                                                          timestamp:0
                                                       windowNumber:win.windowNumber
                                                            context:nil
                                                        eventNumber:0
                                                     trackingNumber:0
                                                           userData:NULL]];
                    const BOOL icRestore = (ic.layer.borderWidth <= 1.1) && CGColorsRoughlyEqual(restBorder, ic.layer.borderColor);
                    std::printf("  [CARD %-5s w=%4d %-14s] restBorder=%s(w=%.1f) capsBorder=%s(w=%.1f) track=%lu hand=%d hov=%d/%d\n",
                                theme.UTF8String, (int)w, ic.identifier.UTF8String,
                                DescribeCGColor(restBorder).UTF8String, ic.layer.borderWidth,
                                DescribeCGColor(capsBorder).UTF8String, capsCard.layer.borderWidth,
                                (unsigned long)ic.trackingAreas.count, icHand, icHover, icRestore);
                    CK(distinctRest && icTrack && icHand && icHover && icRestore,
                       [[NSString stringWithFormat:@"CARD[%@:%d] 可点卡片 %@ 与纯展示有边框区分且支持整卡 hover 反馈", theme, (int)w, ic.identifier] UTF8String],
                       [NSString stringWithFormat:@"distinct=%d track=%lu hand=%d hov=%d/%d border=%@ vs caps=%@",
                        distinctRest, (unsigned long)ic.trackingAreas.count, icHand, icHover, icRestore,
                        DescribeCGColor(restBorder), DescribeCGColor(capsBorder)]);
                }

                // 验证整卡点击语义（点击卡片上的 NSTextField 标签可打开弹层，不吞点击；内嵌 NSPopUpButton 不误触整卡）
                if ([theme isEqualToString:@"dark"] && (int)w == 1180) {
                    RLPQuickStartViewController *ovc = [[RLPOfflineOutputController alloc] init];
                    (void)ovc.view;
                    NSWindow *cwin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 760)
                                                                 styleMask:NSWindowStyleMaskBorderless
                                                                   backing:NSBackingStoreBuffered defer:NO];
                    [cwin.contentView addSubview:ovc.view];
                    ovc.view.translatesAutoresizingMaskIntoConstraints = NO;
                    [NSLayoutConstraint activateConstraints:@[
                        [ovc.view.leadingAnchor constraintEqualToAnchor:cwin.contentView.leadingAnchor],
                        [ovc.view.trailingAnchor constraintEqualToAnchor:cwin.contentView.trailingAnchor],
                        [ovc.view.topAnchor constraintEqualToAnchor:cwin.contentView.topAnchor],
                        [ovc.view.bottomAnchor constraintEqualToAnchor:cwin.contentView.bottomAnchor],
                    ]];
                    [cwin.contentView layoutSubtreeIfNeeded];

                    NSView *clickOutCard = FindById(ovc.view, @"room.output");
                    NSTextField *captionField = nil;
                    for (NSView *sv in clickOutCard.subviews) {
                        if ([sv isKindOfClass:[NSTextField class]]) { captionField = (NSTextField *)sv; break; }
                    }
                    if (clickOutCard && captionField) {
                        NSPoint pInCard = NSMakePoint(NSMidX(captionField.frame), NSMidY(captionField.frame));
                        NSPoint pInWin = [clickOutCard convertPoint:pInCard toView:nil];
                        NSEvent *downEv = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                             location:pInWin modifierFlags:0 timestamp:0
                                                         windowNumber:cwin.windowNumber context:nil
                                                          eventNumber:1 clickCount:1 pressure:1.0];
                        NSEvent *upEv = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                                           location:pInWin modifierFlags:0 timestamp:0
                                                       windowNumber:cwin.windowNumber context:nil
                                                        eventNumber:2 clickCount:1 pressure:0.0];
                        [cwin postEvent:upEv atStart:YES];
                        [clickOutCard mouseDown:downEv];
                        CK(ovc.popover != nil,
                           "CARD_CLICK 点击可点卡静态标签（NSTextField）触发整卡弹层而非被 NSControl 吞掉",
                           @"popover is nil");
                        [ovc.popover close];
                        ovc.popover = nil;
                    }

                    // 用同一 interactive card 类验证：内嵌 NSPopUpButton 时点击下拉不误触整卡 action，点空白触发
                    Class cardCls = clickOutCard.class;
                    NSView *guardCard = cardCls ? [[cardCls alloc] initWithFrame:NSMakeRect(0, 0, 220, 110)] : nil;
                    if (guardCard) {
                        RLPCardClickSpy *spy = [[RLPCardClickSpy alloc] init];
                        [guardCard setValue:spy forKey:@"target"];
                        SEL actSel = @selector(onCardAction:);
                        ((void (*)(id, SEL, SEL))objc_msgSend)(guardCard, @selector(setAction:), actSel);
                        NSPopUpButton *innerPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(12, 40, 196, 30) pullsDown:NO];
                        [guardCard addSubview:innerPop];
                        NSWindow *gwin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 260, 140)
                                                                     styleMask:NSWindowStyleMaskBorderless
                                                                       backing:NSBackingStoreBuffered defer:NO];
                        guardCard.translatesAutoresizingMaskIntoConstraints = YES;
                        guardCard.frame = NSMakeRect(10, 10, 220, 110);
                        [gwin.contentView addSubview:guardCard];
                        [gwin.contentView layoutSubtreeIfNeeded];

                        NSPoint popPt = [guardCard convertPoint:NSMakePoint(NSMidX(innerPop.frame), NSMidY(innerPop.frame)) toView:nil];
                        NSEvent *popDown = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                              location:popPt modifierFlags:0 timestamp:0
                                                          windowNumber:gwin.windowNumber context:nil
                                                           eventNumber:3 clickCount:1 pressure:1.0];
                        [guardCard mouseDown:popDown];
                        const NSInteger hitsAfterPop = spy.hits;

                        NSPoint bgPt = [guardCard convertPoint:NSMakePoint(20, 12) toView:nil];
                        NSEvent *bgDown = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                             location:bgPt modifierFlags:0 timestamp:0
                                                         windowNumber:gwin.windowNumber context:nil
                                                          eventNumber:4 clickCount:1 pressure:1.0];
                        NSEvent *bgUp = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                                           location:bgPt modifierFlags:0 timestamp:0
                                                       windowNumber:gwin.windowNumber context:nil
                                                        eventNumber:5 clickCount:1 pressure:0.0];
                        [gwin postEvent:bgUp atStart:YES];
                        [guardCard mouseDown:bgDown];
                        CK(hitsAfterPop == 0 && spy.hits == 1,
                           "CARD_CLICK_GUARD 点击内部 NSPopUpButton 不误触整卡 action，点击卡片空白正常触发",
                           [NSString stringWithFormat:@"afterPop=%ld afterBg=%ld", (long)hitsAfterPop, (long)spy.hits]);
                    }
                }
            }

            // 按钮不得过大挤压/重叠：检查卡内关键控件无重叠、无越界
            NSView *devRefresh = FindById(vc.view, @"room.deviceRefresh");
            NSView *devPopup = FindById(vc.view, @"room.devicePopup");
            NSView *npCard = FindById(vc.view, @"room.nowplaying");
            NSView *npTog = FindById(vc.view, @"room.playToggle");
            NSView *npOpn = FindById(vc.view, @"room.openAlbum");
            if (devCard && devRefresh && devPopup && npCard && npTog && npOpn) {
                NSRect rRef = [devRefresh convertRect:devRefresh.bounds toView:devCard];
                NSRect rPop = [devPopup convertRect:devPopup.bounds toView:devCard];
                NSRect rTog = [npTog convertRect:npTog.bounds toView:npCard];
                NSRect rOpn = [npOpn convertRect:npOpn.bounds toView:npCard];
                const BOOL noOverlap = NSIsEmptyRect(NSIntersectionRect(rRef, rPop)) &&
                                       NSIsEmptyRect(NSIntersectionRect(rTog, rOpn));
                const BOOL insideCard = NSMaxX(rRef) <= NSWidth(devCard.bounds) + 1.0 &&
                                        NSMaxX(rPop) <= NSWidth(devCard.bounds) + 1.0 &&
                                        NSMaxX(rOpn) <= NSWidth(npCard.bounds) + 1.0;
                CK(noOverlap && insideCard,
                   [[NSString stringWithFormat:@"CARD[%@:%d] 强化按钮后不重叠、不挤压溢出父卡", theme, (int)w] UTF8String],
                   [NSString stringWithFormat:@"ref=%@ pop=%@ tog=%@ opn=%@",
                    NSStringFromRect(rRef), NSStringFromRect(rPop), NSStringFromRect(rTog), NSStringFromRect(rOpn)]);
            }
        }
    }

    if (origTheme.length) [RLPTheme setThemeName:origTheme];
}

static NSImage *MakeTestCover512() {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(512, 512)];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:512
                      pixelsHigh:512
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    if (rep) {
        [img addRepresentation:rep];
    } else {
        [img lockFocus];
        [[NSColor systemBlueColor] setFill];
        NSRectFill(NSMakeRect(0, 0, 512, 512));
        [img unlockFocus];
    }
    return img;
}

static NSArray<RLPAlbum *> *MakeTestAlbums(NSInteger count) {
    NSMutableArray<NSDictionary *> *raw = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (NSInteger i = 0; i < count; ++i) {
        [raw addObject:@{
            @"key": [NSString stringWithFormat:@"alb-%ld", (long)i],
            @"name": [NSString stringWithFormat:@"Very Long Classical Symphony Album Title Number %ld With Extra Words For Tail Truncation", (long)i],
            @"album": [NSString stringWithFormat:@"Very Long Classical Symphony Album Title Number %ld With Extra Words For Tail Truncation", (long)i],
            @"artist": @"Very Long Philharmonic Orchestra & Conductor Name That Should Not Overflow",
            @"year": @(2000 + (i % 24)),
            @"sampleRate": @192000,
            @"bits": @24,
        }];
    }
    NSArray<RLPAlbum *> *parsed = [RLPAlbum albumsFromJSON:@{@"ok": @YES, @"albums": raw, @"items": raw}];
    if (parsed.count >= (NSUInteger)count) return parsed;
    NSMutableArray<RLPAlbum *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (NSInteger i = 0; i < count; ++i) {
        RLPAlbum *a = [[RLPAlbum alloc] init];
        @try {
            [a setValue:raw[(NSUInteger)i][@"key"] forKey:@"key"];
            [a setValue:raw[(NSUInteger)i][@"name"] forKey:@"name"];
            [a setValue:raw[(NSUInteger)i][@"artist"] forKey:@"artist"];
            [a setValue:raw[(NSUInteger)i][@"year"] forKey:@"year"];
            [a setValue:raw[(NSUInteger)i][@"sampleRate"] forKey:@"sampleRate"];
            [a setValue:raw[(NSUInteger)i][@"bits"] forKey:@"bits"];
        } @catch (NSException *ex) {
            (void)ex;
        }
        [out addObject:a];
    }
    return out;
}

static NSDictionary *SampleLongQueueJSON() {
    return @{
        @"items": @[@"/tmp/track1.flac", @"/tmp/track2.flac", @"/tmp/track3.flac", @"/tmp/track4.flac"],
        @"metas": @[
            @{@"t": @"Symphony No. 9 in D Minor Op. 125 Movement IV Presto Allegro Assai Very Long Title",
              @"a": @"Berliner Philharmoniker & Long Conductor Name", @"d": @1452.0},
            @{@"t": @"Goldberg Variations BWV 988 Aria da Capo Very Long Title For Narrow Queue Preview",
              @"a": @"Glenn Gould", @"d": @312.0},
            @{@"t": @"Kind of Blue So What Remastered Ultra High Definition Long Title",
              @"a": @"Miles Davis Quintet", @"d": @562.0},
            @{@"t": @"The Well-Tempered Clavier Book I Prelude and Fugue No. 1 in C Major",
              @"a": @"Sviatoslav Richter", @"d": @285.0},
        ],
        @"index": @0,
    };
}

static NSUInteger ApplyCoversToRoom(RLPQuickStartViewController *vc, NSImage * _Nullable cover) {
    vc.npCover.image = cover;
    NSMutableArray<NSView *> *covers = [NSMutableArray array];
    CollectByIdPrefix(vc.view, @"room.albumcover.", covers);
    for (NSView *v in covers) {
        if ([v isKindOfClass:[NSImageView class]]) {
            ((NSImageView *)v).image = cover;
        }
    }
    return covers.count;
}

static void MountVCInWindow(RLPQuickStartViewController *vc, NSWindow *win) {
    NSView *host = win.contentView;
    [host addSubview:vc.view];
    vc.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [vc.view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [vc.view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [vc.view.topAnchor constraintEqualToAnchor:host.topAnchor],
        [vc.view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
}

static void VerifyRoomFit(RLPQuickStartViewController *vc, NSWindow *win, CGFloat expectedW,
                          NSString *tag, BOOL expectCover) {
    NSScrollView *scroll = FindRoomScrollView(vc.view);
    NSView *cDev = FindById(vc.view, @"room.device");
    NSView *cOut = FindById(vc.view, @"room.output");
    NSView *cPlay = FindById(vc.view, @"room.play");
    NSView *cStyle = FindById(vc.view, @"room.style");
    NSView *cardsContainer = vc.cardsContainer ?: cDev.superview;
    NSView *albumRowView = FindById(vc.view, @"room.albums") ?: vc.albumRow;
    NSView *npCard = FindById(vc.view, @"room.nowplaying");
    NSView *qCard = FindById(vc.view, @"room.queue");

    const CGFloat docW = scroll ? NSWidth(scroll.documentView.frame) : -1.0;
    const CGFloat clipW = scroll ? NSWidth(scroll.contentView.bounds) : -1.0;
    const CGFloat hostW = NSWidth(win.contentView.bounds);
    const CGFloat pageW = NSWidth(vc.view.bounds);

    CK(scroll && docW <= clipW + 1.0 && hostW <= expectedW + 1.0 && pageW <= expectedW + 1.0,
       [[NSString stringWithFormat:@"%@ scroll doc<=clip and host/page<=expected", tag] UTF8String],
       [NSString stringWithFormat:@"expected=%.1f host=%.1f page=%.1f clip=%.1f doc=%.1f",
        expectedW, hostW, pageW, clipW, docW]);

    BOOL fourCardsOk = (cardsContainer != nil && cDev && cOut && cPlay && cStyle);
    NSString *cardsDetail = @"";
    if (fourCardsOk) {
        const CGFloat ccW = NSWidth(cardsContainer.bounds);
        for (NSView *card in @[cDev, cOut, cPlay, cStyle]) {
            NSRect cr = [card convertRect:card.bounds toView:cardsContainer];
            NSRect pr = [card convertRect:card.bounds toView:vc.view];
            if (NSWidth(cr) <= 0 || NSMaxX(cr) > ccW + 1.0 || NSMaxX(pr) > pageW + 1.0) {
                fourCardsOk = NO;
                cardsDetail = [NSString stringWithFormat:@"id=%@ cr=%@ ccW=%.1f pr=%@ pageW=%.1f",
                               card.identifier, NSStringFromRect(cr), ccW, NSStringFromRect(pr), pageW];
                break;
            }
        }
    }
    CK(fourCardsOk, [[NSString stringWithFormat:@"%@ four cards maxX <= cardsContainer/page", tag] UTF8String], cardsDetail);

    BOOL albumsOk = ([albumRowView isKindOfClass:[NSStackView class]]);
    NSString *albumsDetail = @"";
    NSUInteger foundAlbumCards = 0;
    if (albumsOk) {
        NSStackView *ar = (NSStackView *)albumRowView;
        const CGFloat arW = NSWidth(ar.bounds);
        for (NSView *rowView in ar.arrangedSubviews) {
            if (![rowView isKindOfClass:[NSStackView class]]) continue;
            NSStackView *rs = (NSStackView *)rowView;
            NSRect rr = [rs convertRect:rs.bounds toView:ar];
            if (NSMaxX(rr) > arW + 1.0) {
                albumsOk = NO;
                albumsDetail = [NSString stringWithFormat:@"rowStack=%@ arW=%.1f", NSStringFromRect(rr), arW];
                break;
            }
            for (NSView *item in rs.arrangedSubviews) {
                NSRect ir = [item convertRect:item.bounds toView:ar];
                if (NSWidth(ir) <= 0 || NSMaxX(ir) > arW + 1.0) {
                    albumsOk = NO;
                    albumsDetail = [NSString stringWithFormat:@"item=%@ ir=%@ arW=%.1f", item.identifier ?: @"", NSStringFromRect(ir), arW];
                    break;
                }
                if ([item.identifier hasPrefix:@"room.albumcard."]) {
                    ++foundAlbumCards;
                    NSMutableArray<NSView *> *ivs = [NSMutableArray array];
                    CollectByIdPrefix(item, @"room.albumcover.", ivs);
                    for (NSView *v in ivs) {
                        if (![v isKindOfClass:[NSImageView class]]) continue;
                        NSImageView *iv = (NSImageView *)v;
                        NSRect ivr = [iv convertRect:iv.bounds toView:ar];
                        if (NSMaxX(ivr) > arW + 1.0) {
                            albumsOk = NO;
                            albumsDetail = [NSString stringWithFormat:@"cover=%@ ivr=%@ arW=%.1f", iv.identifier, NSStringFromRect(ivr), arW];
                            break;
                        }
                        if (expectCover && (!iv.image || iv.image.size.width < 512.0)) {
                            albumsOk = NO;
                            albumsDetail = [NSString stringWithFormat:@"cover=%@ missing 512 image", iv.identifier];
                            break;
                        }
                    }
                    if (!albumsOk) break;
                }
            }
            if (!albumsOk) break;
        }
    }
    CK(albumsOk && foundAlbumCards > 0,
       [[NSString stringWithFormat:@"%@ album cards maxX <= albumRow", tag] UTF8String],
       [NSString stringWithFormat:@"cards=%lu %@", (unsigned long)foundAlbumCards, albumsDetail]);

    BOOL npqOk = (npCard != nil && qCard != nil);
    NSString *npqDetail = @"";
    if (npqOk) {
        NSRect npr = [npCard convertRect:npCard.bounds toView:vc.view];
        NSRect qr = [qCard convertRect:qCard.bounds toView:vc.view];
        if (NSWidth(npr) <= 0 || NSMaxX(npr) > pageW + 1.0 ||
            NSWidth(qr) <= 0 || NSMaxX(qr) > pageW + 1.0) {
            npqOk = NO;
            npqDetail = [NSString stringWithFormat:@"np=%@ q=%@ pageW=%.1f",
                         NSStringFromRect(npr), NSStringFromRect(qr), pageW];
        }
    }
    CK(npqOk, [[NSString stringWithFormat:@"%@ nowplaying/queue maxX <= pageW", tag] UTF8String], npqDetail);
}

static void TestRoomCoverAndCacheFitB1B2B3() {
    // ---------- B1 & B3: 四档窗宽 × 封面未加载/512x512 加载后 ----------
    RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
    (void)vc.view;
    vc.albumsData = MakeTestAlbums(10);
    vc.npTitle.stringValue = @"Very Long Track Title In Listening Room That Must Truncate Cleanly Without Expanding Window Width";
    vc.npSub.stringValue = @"Very Long Orchestra & Soloist · Very Long Classical Album Title · 2024";
    [vc renderQueueFromJSON:SampleLongQueueJSON()];
    [vc rebuildAlbumGrid];

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1394, 880)
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
    MountVCInWindow(vc, win);

    NSArray<NSArray<NSNumber *> *> *sizes = @[
        @[@1394, @880],
        @[@1180, @760],
        @[@900, @600],
        @[@800, @600],
    ];
    NSImage *cover512 = MakeTestCover512();

    // B3a: 封面未加载状态
    for (NSArray<NSNumber *> *sz in sizes) {
        const CGFloat w = sz[0].doubleValue, h = sz[1].doubleValue;
        [win setContentSize:NSMakeSize(w, h)];
        [win.contentView layoutSubtreeIfNeeded];
        ApplyCoversToRoom(vc, nil);
        [win.contentView layoutSubtreeIfNeeded];
        VerifyRoomFit(vc, win, w, [NSString stringWithFormat:@"B3_nocover_%dx%d", (int)w, (int)h], NO);
    }

    // B1 & B3b: 加载 512x512 NSImage 封面后（先设 512x512 封面，再按四档检测）
    for (NSArray<NSNumber *> *sz in sizes) {
        const CGFloat w = sz[0].doubleValue, h = sz[1].doubleValue;
        [win setContentSize:NSMakeSize(w, h)];
        [win.contentView layoutSubtreeIfNeeded];
        const NSUInteger covCount = ApplyCoversToRoom(vc, cover512);
        [win.contentView layoutSubtreeIfNeeded];
        CK(covCount >= 8, [[NSString stringWithFormat:@"B1_%dx%d album covers populated", (int)w, (int)h] UTF8String],
           [NSString stringWithFormat:@"count=%lu", (unsigned long)covCount]);
        VerifyRoomFit(vc, win, w, [NSString stringWithFormat:@"B1_cover512_%dx%d", (int)w, (int)h], YES);
    }

    // ---------- B2: 同一缓存 VC 1180 挂载 -> 改宿主 900 -> remove/add 到新宿主 ----------
    RLPQuickStartViewController *cachedVC = [[RLPQuickStartViewController alloc] init];
    (void)cachedVC.view;
    cachedVC.albumsData = MakeTestAlbums(10);
    cachedVC.npTitle.stringValue = @"Very Long Cached Listening Room Title That Must Reflow On Host Reentry";
    cachedVC.npSub.stringValue = @"Long Artist · Long Album";
    [cachedVC renderQueueFromJSON:SampleLongQueueJSON()];
    [cachedVC rebuildAlbumGrid];

    NSWindow *w1180 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 760)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
    MountVCInWindow(cachedVC, w1180);
    [w1180.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w1180.contentView layoutSubtreeIfNeeded];
    CK(cachedVC.currentCardColumns == 4 && cachedVC.currentAlbumColumns == 5,
       "B2a cached VC at 1180 adopts 4 card cols / 5 album cols",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    VerifyRoomFit(cachedVC, w1180, 1180.0, @"B2a_1180", YES);

    // 改宿主 900
    [w1180 setContentSize:NSMakeSize(900, 600)];
    [w1180.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w1180.contentView layoutSubtreeIfNeeded];
    CK(cachedVC.currentCardColumns == 4 && cachedVC.currentAlbumColumns == 4,
       "B2b host resized to 900 adopts 4 card cols / 4 album cols",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    VerifyRoomFit(cachedVC, w1180, 900.0, @"B2b_resize_900", YES);

    // 复位到 1180 后 remove/add 到新宿主 900（先触发 viewWillMoveToSuperview:/viewDidMoveToWindow）
    [w1180 setContentSize:NSMakeSize(1180, 760)];
    [w1180.contentView layoutSubtreeIfNeeded];
    [cachedVC.view removeFromSuperview];

    NSWindow *w900 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered defer:NO];
    cachedVC.view.frame = w900.contentView.bounds;
    MountVCInWindow(cachedVC, w900);
    CK(cachedVC.currentCardColumns == 4 && cachedVC.currentAlbumColumns == 4,
       "B2c remove/add to 900 host updates responsive layout immediately on mount",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    [w900.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w900.contentView layoutSubtreeIfNeeded];
    VerifyRoomFit(cachedVC, w900, 900.0, @"B2c_reenter_900", YES);

    // 再验证 remove/add 到 2x2（720）与 1 列（380）新宿主，确保四卡 2x2/1 列与专辑列数对应且 doc<=clip
    [cachedVC.view removeFromSuperview];
    NSWindow *w720 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 600)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered defer:NO];
    cachedVC.view.frame = w720.contentView.bounds;
    MountVCInWindow(cachedVC, w720);
    CK(cachedVC.currentCardColumns == 2 && cachedVC.currentAlbumColumns == 3,
       "B2d remove/add to 720 host adopts 2x2 cards / 3 album cols immediately",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    [w720.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w720.contentView layoutSubtreeIfNeeded];
    VerifyRoomFit(cachedVC, w720, 720.0, @"B2d_reenter_720", YES);

    [cachedVC.view removeFromSuperview];
    NSWindow *w380 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 380, 600)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered defer:NO];
    cachedVC.view.frame = w380.contentView.bounds;
    MountVCInWindow(cachedVC, w380);
    CK(cachedVC.currentCardColumns == 1 && cachedVC.currentAlbumColumns == 2,
       "B2e remove/add to 380 host adopts 1x4 cards / 2 album cols immediately",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    [w380.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w380.contentView layoutSubtreeIfNeeded];
    VerifyRoomFit(cachedVC, w380, 380.0, @"B2e_reenter_380", YES);

    // 额外验证：保持旧 1180 frame 直接 remove/add 到 900 新宿主（不预设 frame），单次 layoutSubtreeIfNeeded 必须完成收敛
    [cachedVC.view removeFromSuperview];
    cachedVC.view.frame = NSMakeRect(0, 0, 1180, 760);
    NSWindow *w900b = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
    MountVCInWindow(cachedVC, w900b);
    [w900b.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w900b.contentView layoutSubtreeIfNeeded];
    CK(cachedVC.currentCardColumns == 4 && cachedVC.currentAlbumColumns == 4,
       "B2f stale 1180 frame remove/add to 900 host converges on layout",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    VerifyRoomFit(cachedVC, w900b, 900.0, @"B2f_stale_reenter_900", YES);
}

typedef void (*RLPContractGetJSONImp)(id, SEL, NSString *, RLPJSONCompletion);
static RLPContractGetJSONImp gContractOrigGetJSONImp = NULL;
static NSDictionary *gContractQueueMock = nil;
static NSDictionary *gContractStatusMock = nil;

static void RLPContractMockGetJSON(id self, SEL _cmd, NSString *path, RLPJSONCompletion done) {
    if ([path hasPrefix:@"/api/queue?meta=1"] && gContractQueueMock) {
        if (done) done(gContractQueueMock);
        return;
    }
    if ([path hasPrefix:@"/api/status"] && gContractStatusMock) {
        if (done) done(gContractStatusMock);
        return;
    }
    if (gContractOrigGetJSONImp) {
        gContractOrigGetJSONImp(self, _cmd, path, done);
    } else if (done) {
        done(@{@"ok": @NO});
    }
}

static void PumpContract(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static NSDictionary *MakeContractQueueJSON(NSArray<NSString *> *paths, NSString *curKey, id curVal) {
    NSMutableArray *metas = [NSMutableArray arrayWithCapacity:paths.count];
    NSMutableArray *cues = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSUInteger i = 0; i < paths.count; ++i) {
        [metas addObject:@{
            @"t": [NSString stringWithFormat:@"Song %c", (char)('A' + i)],
            @"a": @"Contract Artist",
            @"d": @(180.0 + i * 15.0),
        }];
        [cues addObject:@[@(-1), @(-1)]];
    }
    NSMutableDictionary *d = [@{
        @"ok": @YES,
        @"items": paths,
        @"metas": metas,
        @"cues": cues,
    } mutableCopy];
    if (curKey.length && curVal) d[curKey] = curVal;
    return d;
}

static void InspectQueueListState(RLPQuickStartViewController *vc,
                                  NSInteger *outRowCount,
                                  NSInteger *outHighlightedCount,
                                  NSInteger *outHighlightedIdx,
                                  NSString **outHighlightedPath) {
    NSArray<NSView *> *rows = vc.queueList.arrangedSubviews;
    *outRowCount = (NSInteger)rows.count;
    *outHighlightedCount = 0;
    *outHighlightedIdx = -1;
    *outHighlightedPath = nil;
    if (vc.queueEmptyLabel != nil) return;

    RLPTheme *t = [RLPTheme current];
    NSColor *accWeakSRGB = [t.accentWeak colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    for (NSUInteger k = 0; k < rows.count; ++k) {
        NSView *row = rows[k];
        NSButton *hit = nil;
        for (NSView *sub in row.subviews) {
            if ([sub isKindOfClass:[NSButton class]]) { hit = (NSButton *)sub; break; }
        }
        const BOOL flag = (k < vc.queueRowCurrentFlags.count) && vc.queueRowCurrentFlags[k].boolValue;
        BOOL bgMatches = NO;
        if (row.layer && row.layer.backgroundColor && accWeakSRGB) {
            NSColor *bg = [[NSColor colorWithCGColor:row.layer.backgroundColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (bg) {
                bgMatches = fabs(bg.redComponent - accWeakSRGB.redComponent) < 0.02 &&
                            fabs(bg.greenComponent - accWeakSRGB.greenComponent) < 0.02 &&
                            fabs(bg.blueComponent - accWeakSRGB.blueComponent) < 0.02;
            }
        }
        if (flag && bgMatches && hit) {
            ++(*outHighlightedCount);
            *outHighlightedIdx = hit.tag;
            *outHighlightedPath = hit.toolTip;
        }
    }
}

static void TestListeningQueueFollow() {
    Method m = class_getInstanceMethod([RLPCoreClient class], @selector(getJSON:completion:));
    gContractOrigGetJSONImp = (RLPContractGetJSONImp)method_getImplementation(m);
    method_setImplementation(m, (IMP)RLPContractMockGetJSON);

    NSArray<NSString *> *tracks5 = @[
        @"/tmp/rlp_q_A.flac",
        @"/tmp/rlp_q_B.flac",
        @"/tmp/rlp_q_C.flac",
        @"/tmp/rlp_q_D.flac",
        @"/tmp/rlp_q_E.flac",
    ];

    RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
    vc.view.frame = NSMakeRect(0, 0, 1100, 760);
    [vc.view layoutSubtreeIfNeeded];

    // 初始在曲 A（index=0）
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"index", @0);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[0]};
    [vc reloadQueue];
    [vc applyStatusJSON:gContractStatusMock];
    PumpContract(0.05);

    NSInteger rowCount = 0, hiCount = 0, hiIdx = -1;
    NSString *hiPath = nil;
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 0 && [hiPath isEqualToString:tracks5[0]],
       "Q1-precondition: 聆听室 queueList 初始高亮曲 A (index=0, 4行)",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);

    // Q1: 模拟状态从曲 A 切到曲 B（队列 JSON 使用 current=B）
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"current", tracks5[1]);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[1]};
    [vc applyStatusJSON:gContractStatusMock];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    std::printf("  [INFO] Q1 highlighted index=%ld path=%s (rows=%ld)\n",
                (long)hiIdx, hiPath.UTF8String ?: "(nil)", (long)rowCount);
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 1 && [hiPath isEqualToString:tracks5[1]] &&
       [vc.queuePaths isEqualToArray:tracks5],
       "Q1 切歌到 B 后聆听室 queueList 高亮行=B、行数不变且队列顺序不变",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);

    // Q3: 连续切 3 首（C -> D -> 轮询 E）仍跟随
    // 1) RLPPlaybackStatusNotification -> C (cur=C)
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"cur", tracks5[2]);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[2]};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackStatusNotification"
                                                        object:gContractStatusMock];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    std::printf("  [INFO] Q3-1 highlighted index=%ld path=%s\n", (long)hiIdx, hiPath.UTF8String ?: "(nil)");
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 2 && [hiPath isEqualToString:tracks5[2]] &&
       [vc.queuePaths isEqualToArray:tracks5],
       "Q3a 聆听室连续第 1 次切歌跟随到 C (index=2)",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);

    // 2) applyStatusJSON -> D (index=3)
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"index", @3);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[3]};
    [vc applyStatusJSON:gContractStatusMock];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    std::printf("  [INFO] Q3-2 highlighted index=%ld path=%s\n", (long)hiIdx, hiPath.UTF8String ?: "(nil)");
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 3 && [hiPath isEqualToString:tracks5[3]] &&
       [vc.queuePaths isEqualToArray:tracks5],
       "Q3b 聆听室连续第 2 次切歌跟随到 D (index=3)",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);

    // 3) activate + 1s 轮询定时器自动发现切到 E (current=@4，预览窗应滑到 1..4)
    [vc activate];
    PumpContract(0.05);
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"current", @4);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[4]};
    PumpContract(1.15);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    std::printf("  [INFO] Q3-3 (poll) highlighted index=%ld path=%s\n", (long)hiIdx, hiPath.UTF8String ?: "(nil)");
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 4 && [hiPath isEqualToString:tracks5[4]] &&
       [vc.queuePaths isEqualToArray:tracks5],
       "Q3c 聆听室连续第 3 次通过轮询跟随到 E (index=4)",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);
    [vc viewDidDisappear];

    // Q4: 当前不在队列 / 越界 / 空队列 -> 不崩、不高亮错行
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"current", @"/tmp/rlp_q_NOT_IN_QUEUE.flac");
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": @"/tmp/rlp_q_NOT_IN_QUEUE.flac"};
    [vc applyStatusJSON:gContractStatusMock];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    CK(rowCount == 4 && hiCount == 0 && hiIdx == -1 && vc.queueCurrentIndex == -1,
       "Q4a 聆听室当前曲目不在队列时不崩且不高亮任何行",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld curIdx=%ld",
        (long)rowCount, (long)hiCount, (long)hiIdx, (long)vc.queueCurrentIndex]);

    gContractQueueMock = MakeContractQueueJSON(tracks5, @"index", @99);
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:nil];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    CK(rowCount == 4 && hiCount == 0 && hiIdx == -1 && vc.queueCurrentIndex == -1,
       "Q4b 聆听室队列越界 index=99 时不崩且不高亮错行",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld curIdx=%ld",
        (long)rowCount, (long)hiCount, (long)hiIdx, (long)vc.queueCurrentIndex]);

    gContractQueueMock = @{@"ok": @YES, @"items": @[], @"metas": @[], @"cues": @[], @"current": tracks5[0]};
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:nil];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    CK(vc.queueEmptyLabel != nil && rowCount == 1 && hiCount == 0 && vc.queueCurrentIndex == -1,
       "Q4c 聆听室空队列时显示空态且不高亮错行",
       [NSString stringWithFormat:@"empty=%d rows=%ld curIdx=%ld",
        vc.queueEmptyLabel != nil, (long)rowCount, (long)vc.queueCurrentIndex]);

    gContractQueueMock = nil;
    gContractStatusMock = nil;
    method_setImplementation(m, (IMP)gContractOrigGetJSONImp);
    gContractOrigGetJSONImp = NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        TestMountedRoomGeometry();
        TestListeningRoomButtonAffordance();
        if (argc == 2 && std::strcmp(argv[1], "--geometry-only") == 0) return gFail ? 1 : 0;
        std::printf("=== test_native_listening_contract（聆听室 v3.3.11 契约 · 离线/null 核心）===\n");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-listen-contract-%d", (int)getpid()]];
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        NSString *lib = [root stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);

        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) {
            std::printf("  [FAIL] 核心启动失败\n");
            return 1;
        }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        // ---------- C1 真实注册表 + Windows 语义风格映射 ----------
        NSDictionary *fj = [core jsonWithMethod:@"GET" path:@"/api/filters" body:nil];
        NSArray<NSDictionary *> *items = [fj[@"items"] isKindOfClass:[NSArray class]] ? fj[@"items"] : @[];
        CK(items.count >= 50, "C1a /api/filters 返回真实注册表",
           [NSString stringWithFormat:@"count=%lu", (unsigned long)items.count]);

        NSString *warm = RLPFilterForToneStyle(RLPToneStyleWarm, items);
        NSString *bal  = RLPFilterForToneStyle(RLPToneStyleBalanced, items);
        NSString *sharp = RLPFilterForToneStyle(RLPToneStyleSharp, items);
        CK([warm isEqualToString:@"poly-sinc-gauss-long"],
           "C1b 温和档选用真实条目 poly-sinc-gauss-long（不再碰运气选 524k gauss-xl）", warm ?: @"nil");
        CK([bal isEqualToString:@"poly-sinc-short-lp"],
           "C1c 均衡档选用 Windows 语义 poly-sinc-short-lp", bal ?: @"nil");
        CK(sharp.length > 0 &&
           [sharp.lowercaseString rangeOfString:@"gauss"].location == NSNotFound &&
           ([sharp.lowercaseString rangeOfString:@"long"].location != NSNotFound ||
            [sharp.lowercaseString rangeOfString:@"ext"].location != NSNotFound ||
            [sharp.lowercaseString rangeOfString:@"tight"].location != NSNotFound),
           "C1d 锐利档选用注册表真实非 gauss 滤波（long/ext/tight）", sharp ?: @"nil");

        // ---------- C2 切风格同一次 POST 清旧手动覆盖 + 写后读回 ----------
        [core jsonWithMethod:@"POST" path:@"/api/settings"
            body:@"filter=poly-sinc-xl&filterNx=poly-sinc-gauss-hires-lp&taps=65535&mintapsperinput=512&atten=180&transition=0.05&phase=min"];
        NSDictionary<NSString *, NSString *> *patch = RLPSettingsPatchForToneStyle(RLPToneStyleWarm, items);
        CK(patch != nil &&
           [patch[@"filter"] isEqualToString:@"poly-sinc-gauss-long"] &&
           [patch[@"filterNx"] isEqualToString:@""] &&
           [patch[@"taps"] isEqualToString:@"0"] &&
           [patch[@"mintapsperinput"] isEqualToString:@"0"] &&
           [patch[@"atten"] isEqualToString:@"0"] &&
           [patch[@"transition"] isEqualToString:@"0"] &&
           [patch[@"phase"] isEqualToString:@""],
           "C2a 风格补丁同一次含 filter 与全部清除键", patch.description ?: @"nil");

        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in patch) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(patch[k])]];
        NSDictionary *postRes = [core jsonWithMethod:@"POST" path:@"/api/settings"
                                              body:[parts componentsJoinedByString:@"&"]];
        CK([postRes[@"ok"] boolValue], "C2b 单次 POST /api/settings 成功", postRes.description ?: @"nil");

        NSDictionary *kv = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
        CK([kv[@"filter"] isEqualToString:@"poly-sinc-gauss-long"], "C2c 读回 filter=poly-sinc-gauss-long", kv[@"filter"] ?: @"nil");
        CK([kv[@"taps"] isEqualToString:@"0"], "C2d 读回 taps 已清 0", kv[@"taps"] ?: @"nil");
        CK(!kv[@"mintapsperinput"] || [kv[@"mintapsperinput"] isEqualToString:@"0"],
           "C2e 读回 mintapsperinput 已清 0（或未写入旧覆盖）", kv[@"mintapsperinput"] ?: @"nil");
        CK([kv[@"atten"] isEqualToString:@"0"], "C2f 读回 atten 已清 0", kv[@"atten"] ?: @"nil");
        CK([kv[@"transition"] isEqualToString:@"0"], "C2g 读回 transition 已清 0", kv[@"transition"] ?: @"nil");
        CK(![kv[@"phase"] length], "C2h 读回 phase 已清空", kv[@"phase"] ?: @"nil");

        CK([RLPPlayModeFromSettings(@{@"rate": @"src", @"dsd": @"0", @"filter": @""}) isEqualToString:@"bitperfect"],
           "C2i PlayModeFromSettings: bitperfect", @"");
        CK([RLPPlayModeFromSettings(@{@"rate": @"176400", @"dsd": @"0"}) isEqualToString:@"pcm"],
           "C2j PlayModeFromSettings: pcm", @"");
        CK([RLPPlayModeFromSettings(@{@"rate": @"src", @"dsd": @"dop128"}) isEqualToString:@"dsd"],
           "C2k PlayModeFromSettings: dop128 -> dsd", @"");

        // ---------- C3 能力门控与禁用原因 ----------
        NSDictionary *caFull = @{
            @"ok": @YES,
            @"device": @{@"name": @"USB DAC", @"backend": @"coreaudio",
                         @"rates": @[@44100, @96000, @192000, @384000],
                         @"maxRate": @384000, @"dsdNative": @NO, @"dop": @YES, @"dopMax": @"dsd128"}
        };
        NSDictionary *stFull = [RLPQuickStartViewController presetStatusForCapsJSON:caFull
                                                                            settings:@{@"backend": @"coreaudio"}
                                                                             playing:NO paused:NO];
        CK([stFull[@"bitperfect"][@"enabled"] boolValue] &&
           [stFull[@"pcm"][@"enabled"] boolValue] &&
           [stFull[@"dsd"][@"enabled"] boolValue] &&
           [stFull[@"pcm2dsd"][@"enabled"] boolValue],
           "C3a CoreAudio+DoP 全四档可用", @"");

        NSDictionary *caShared = @{
            @"ok": @YES,
            @"device": @{@"name": @"Speakers", @"backend": @"coreaudio-shared",
                         @"rates": @[@44100, @48000], @"maxRate": @48000, @"dsdNative": @NO, @"dop": @NO}
        };
        NSDictionary *gShared = [RLPQuickStartViewController gatingForCapsJSON:caShared];
        CK(![gShared[@"pcmReady"] boolValue] && ![gShared[@"dsdReady"] boolValue],
           "C3b coreaudio-shared gating 禁用 PCM/DSD 升频", @"");
        NSDictionary *stShared = [RLPQuickStartViewController presetStatusForCapsJSON:caShared
                                                                              settings:@{@"backend": @"coreaudio-shared"}
                                                                               playing:NO paused:NO];
        CK([stShared[@"bitperfect"][@"enabled"] boolValue] &&
           ![stShared[@"pcm"][@"enabled"] boolValue] &&
           [stShared[@"pcm"][@"reason"] length] > 0 &&
           ![stShared[@"dsd"][@"enabled"] boolValue] &&
           [stShared[@"dsd"][@"reason"] length] > 0,
           "C3c shared 下 PCM/DSD 禁用且有原因说明", stShared[@"pcm"][@"reason"] ?: @"nil");

        NSDictionary *stBusy = [RLPQuickStartViewController presetStatusForCapsJSON:caFull
                                                                            settings:@{@"backend": @"coreaudio"}
                                                                             playing:YES paused:NO];
        CK([stBusy[@"bitperfect"][@"enabled"] boolValue] &&
           [stBusy[@"pcm"][@"enabled"] boolValue] &&
           [stBusy[@"dsd"][@"enabled"] boolValue] &&
           [stBusy[@"pcm2dsd"][@"enabled"] boolValue] &&
           ![stBusy[@"bitperfect"][@"reason"] length] &&
           ![stBusy[@"pcm"][@"reason"] length] &&
           ![stBusy[@"dsd"][@"reason"] length],
           "C3d 播放中硬件支持的全部预设仍可选（不因播放中全部禁用）", @"");

        NSDictionary *stPaused = [RLPQuickStartViewController presetStatusForCapsJSON:caFull
                                                                              settings:@{@"backend": @"coreaudio"}
                                                                               playing:NO paused:YES];
        CK([stPaused[@"bitperfect"][@"enabled"] boolValue] &&
           [stPaused[@"pcm"][@"enabled"] boolValue] &&
           [stPaused[@"dsd"][@"enabled"] boolValue] &&
           [stPaused[@"pcm2dsd"][@"enabled"] boolValue],
           "C3e 暂停中硬件支持的全部预设仍可选", @"");

        NSDictionary *stBusyShared = [RLPQuickStartViewController presetStatusForCapsJSON:caShared
                                                                                  settings:@{@"backend": @"coreaudio-shared"}
                                                                                   playing:YES paused:NO];
        CK([stBusyShared[@"bitperfect"][@"enabled"] boolValue] &&
           ![stBusyShared[@"pcm"][@"enabled"] boolValue] &&
           [stBusyShared[@"pcm"][@"reason"] length] > 0 &&
           ![stBusyShared[@"dsd"][@"enabled"] boolValue] &&
           [stBusyShared[@"dsd"][@"reason"] length] > 0,
           "C3f 播放中仍保留设备能力限制（shared 下禁用 PCM/DSD 升频）",
           stBusyShared[@"pcm"][@"reason"] ?: @"nil");

        NSDictionary *fbActive = [RLPQuickStartViewController playModeFeedbackForNotes:@[@"说明A"] playbackActive:YES];
        NSDictionary *fbStopped = [RLPQuickStartViewController playModeFeedbackForNotes:@[@"说明A"] playbackActive:NO];
        CK([fbActive[@"toast"] rangeOfString:@"下一首或重新播放时生效"].location != NSNotFound &&
           [fbActive[@"notes"] rangeOfString:@"下一首或重新播放时生效"].location != NSNotFound &&
           [fbActive[@"notes"] rangeOfString:@"说明A"].location != NSNotFound &&
           [fbStopped[@"toast"] isEqualToString:RLPTr(@"已应用")] &&
           [fbStopped[@"notes"] isEqualToString:@"说明A"],
           "C3g 播放/暂停时反馈明确提示下一首或重新播放生效，停播时提示已应用",
           fbActive.description ?: @"nil");

        // ---------- C3h~C3l UPnP remote caps gating / QuickStart 显示 / /api/preset/caps ----------
        {
            NSDictionary *upnp192 = @{
                @"ok": @YES,
                @"device": @{
                    @"name": @"Living Room DAC",
                    @"backend": @"upnp",
                    @"rates": @[@44100, @48000, @96000, @192000],
                    @"maxRate": @192000,
                    @"dsdNative": @NO,
                    @"dopMax": @"DSD64",
                }
            };
            NSDictionary *gUpnp = [RLPQuickStartViewController gatingForCapsJSON:upnp192];
            std::printf("  [CASTCAPS gating upnp192] backend=%s name=%s rates=[44100,48000,96000,192000] dopMax=DSD64 -> known=%d pcmReady=%d dsdReady=%d\n",
                        "upnp", "Living Room DAC",
                        [gUpnp[@"known"] boolValue], [gUpnp[@"pcmReady"] boolValue], [gUpnp[@"dsdReady"] boolValue]);
            CK([gUpnp[@"known"] boolValue] && [gUpnp[@"pcmReady"] boolValue] && [gUpnp[@"dsdReady"] boolValue],
               "C3h UPnP + rates [44100,48000,96000,192000] + dopMax=DSD64 -> known=1, pcmReady=1, dsdReady=1",
               gUpnp.description ?: @"nil");

            NSDictionary *stUpnp = [RLPQuickStartViewController presetStatusForCapsJSON:upnp192
                                                                                settings:@{@"backend": @"upnp"}
                                                                                 playing:NO paused:NO];
            CK([stUpnp[@"bitperfect"][@"enabled"] boolValue] &&
               [stUpnp[@"pcm"][@"enabled"] boolValue] &&
               [stUpnp[@"dsd"][@"enabled"] boolValue] &&
               [stUpnp[@"pcm2dsd"][@"enabled"] boolValue] &&
               [stUpnp[@"pcm"][@"result"] containsString:@"192.0"] &&
               [stUpnp[@"dsd"][@"result"] containsString:@"DSD64"],
               "C3i UPnP 192k + DoP64 下 PCM/DSD/PCM->DSD 全部可用且结果跟随渲染器",
               stUpnp.description ?: @"nil");

            NSDictionary *upnpNoDop = @{
                @"ok": @YES,
                @"device": @{
                    @"name": @"Living Room PCM DAC",
                    @"backend": @"upnp",
                    @"rates": @[@44100, @48000, @96000, @192000],
                    @"maxRate": @192000,
                    @"dsdNative": @NO,
                    @"dop": @NO,
                    @"dopMax": @"",
                }
            };
            NSDictionary *gNoDop = [RLPQuickStartViewController gatingForCapsJSON:upnpNoDop];
            NSDictionary *stNoDop = [RLPQuickStartViewController presetStatusForCapsJSON:upnpNoDop
                                                                                  settings:@{@"backend": @"upnp"}
                                                                                   playing:NO paused:NO];
            CK([gNoDop[@"known"] boolValue] && [gNoDop[@"pcmReady"] boolValue] && ![gNoDop[@"dsdReady"] boolValue] &&
               [stNoDop[@"pcm"][@"enabled"] boolValue] && ![stNoDop[@"dsd"][@"enabled"] boolValue] &&
               [stNoDop[@"dsd"][@"reason"] containsString:@"UPnP 渲染器未声明"] &&
               ![stNoDop[@"dsd"][@"reason"] containsString:@"不支持本机"],
               "C3i2 UPnP 仅有 PCM rates 无 DoP 时：PCM 可用、DSD 禁用且原因为 UPnP 渲染器未声明",
               stNoDop[@"dsd"][@"reason"] ?: @"nil");

            NSDictionary *upnpNoRates = @{
                @"ok": @YES,
                @"device": @{
                    @"name": @"",
                    @"backend": @"upnp",
                    @"rates": @[],
                    @"maxRate": @0,
                    @"dsdNative": @NO,
                    @"dop": @NO,
                },
                @"notes": @[@"UPnP 渲染器未声明支持的 WAV/PCM 采样率"]
            };
            NSDictionary *gUpnpEmpty = [RLPQuickStartViewController gatingForCapsJSON:upnpNoRates];
            NSDictionary *stUpnpEmpty = [RLPQuickStartViewController presetStatusForCapsJSON:upnpNoRates
                                                                                    settings:@{@"backend": @"upnp"}
                                                                                     playing:NO paused:NO];
            std::printf("  [CASTCAPS gating upnp-empty] known=%d pcmReady=%d dsdReady=%d pcmReason=%s dsdReason=%s\n",
                        [gUpnpEmpty[@"known"] boolValue], [gUpnpEmpty[@"pcmReady"] boolValue], [gUpnpEmpty[@"dsdReady"] boolValue],
                        [stUpnpEmpty[@"pcm"][@"reason"] UTF8String] ?: "",
                        [stUpnpEmpty[@"dsd"][@"reason"] UTF8String] ?: "");
            CK(![gUpnpEmpty[@"known"] boolValue] && ![gUpnpEmpty[@"pcmReady"] boolValue] && ![gUpnpEmpty[@"dsdReady"] boolValue] &&
               [stUpnpEmpty[@"bitperfect"][@"enabled"] boolValue] &&
               ![stUpnpEmpty[@"pcm"][@"enabled"] boolValue] && ![stUpnpEmpty[@"dsd"][@"enabled"] boolValue] &&
               ![stUpnpEmpty[@"pcm"][@"reason"] containsString:@"不支持本机升频"] &&
               ![stUpnpEmpty[@"dsd"][@"reason"] containsString:@"不支持本机 DoP 升频"] &&
               ([stUpnpEmpty[@"pcm"][@"reason"] containsString:@"UPnP 渲染器未声明"] ||
                [stUpnpEmpty[@"pcm"][@"reason"] containsString:@"能力未知"]),
               "C3j UPnP 无 rates 时 known=0, PCM/DSD reason 指向 UPnP 渲染器能力未知（非「不支持本机升频」）",
               stUpnpEmpty.description ?: @"nil");

            // 验证非 upnp 旧行为不变（coreaudio ready / null / airplay）
            NSDictionary *nullCaps = @{
                @"ok": @YES,
                @"device": @{@"name": @"Null", @"backend": @"null", @"rates": @[@44100], @"maxRate": @44100, @"dop": @YES}
            };
            NSDictionary *gNull = [RLPQuickStartViewController gatingForCapsJSON:nullCaps];
            NSDictionary *apCaps = @{
                @"ok": @YES,
                @"device": @{@"name": @"HomePod", @"backend": @"airplay", @"rates": @[@44100], @"maxRate": @44100, @"dop": @NO}
            };
            NSDictionary *gAp = [RLPQuickStartViewController gatingForCapsJSON:apCaps];
            CK([stFull[@"pcm"][@"enabled"] boolValue] &&
               ![gNull[@"known"] boolValue] && ![gNull[@"pcmReady"] boolValue] &&
               ![gAp[@"pcmReady"] boolValue] && ![gAp[@"dsdReady"] boolValue],
               "C3j2 非 upnp（CoreAudio/null/AirPlay）旧 gating 行为保持不变", @"");

            // C3k QuickStart 展示跟随 UPnP caps（不回落到本机 CoreAudio 名称）
            RLPQuickStartViewController *qvc = [[RLPQuickStartViewController alloc] init];
            qvc.view.frame = NSMakeRect(0, 0, 1100, 760);
            qvc.filters = items;
            qvc.defaultDeviceName = @"MacBook Pro Speakers (CoreAudio)";
            qvc.devices = @[@{@"id": @"101", @"name": @"MacBook Pro Speakers (CoreAudio)", @"default": @YES}];
            qvc.settings = @{
                @"backend": @"upnp",
                @"upnpdev": @"http://127.0.0.1:49999/desc.xml",
                @"rate": @"max",
                @"filter": @"poly-sinc-tight-lp",
                @"dsd": @"0",
                @"directsdm": @"0",
            };
            [qvc applyPresetCaps:@{
                @"ok": @YES,
                @"device": @{
                    @"name": @"Living Room DAC",
                    @"backend": @"upnp",
                    @"rates": @[@44100, @48000, @96000, @176400, @192000],
                    @"maxRate": @192000,
                    @"dsdNative": @NO,
                    @"dop": @YES,
                    @"dopMax": @"dsd64",
                }
            }];
            [qvc syncOutputSummary];
            std::printf("  [CASTCAPS QuickStart] info=\"%s\" pcmBadge=\"%s\" dsdBadge=\"%s\" playSub=\"%s\" outputValue=\"%s\"\n",
                        qvc.capsInfoLabel.stringValue.UTF8String ?: "",
                        qvc.capsPcmBadge.stringValue.UTF8String ?: "",
                        qvc.capsDsdBadge.stringValue.UTF8String ?: "",
                        qvc.playSub.stringValue.UTF8String ?: "",
                        qvc.outputValue.stringValue.UTF8String ?: "");
            CK([qvc.capsInfoLabel.stringValue containsString:@"Living Room DAC"] &&
               ![qvc.capsInfoLabel.stringValue containsString:@"MacBook Pro Speakers"] &&
               [qvc.capsInfoLabel.stringValue containsString:@"192000"] &&
               [qvc.capsPcmBadge.stringValue containsString:@"192"] &&
               [qvc.capsDsdBadge.stringValue containsString:@"DSD64"] &&
               [qvc.playSub.stringValue containsString:@"192"] &&
               [qvc.outputValue.stringValue containsString:@"Living Room DAC"],
               "C3k QuickStart 能力行/徽标/播放卡片/输出摘要显示 Living Room DAC 与 192k/DSD64，不显示本机 CoreAudio",
               [NSString stringWithFormat:@"info=%@ pcm=%@ dsd=%@ playSub=%@ out=%@",
                qvc.capsInfoLabel.stringValue ?: @"", qvc.capsPcmBadge.stringValue ?: @"",
                qvc.capsDsdBadge.stringValue ?: @"", qvc.playSub.stringValue ?: @"", qvc.outputValue.stringValue ?: @""]);

            // 探测失败 / 未确认 UPnP caps 不得回落到 defaultDeviceName，并显示「能力未知」
            [qvc applyPresetCaps:upnpNoRates];
            [qvc syncOutputSummary];
            std::printf("  [CASTCAPS QuickStart unknown] info=\"%s\" pcmBadge=\"%s\" dsdBadge=\"%s\"\n",
                        qvc.capsInfoLabel.stringValue.UTF8String ?: "",
                        qvc.capsPcmBadge.stringValue.UTF8String ?: "",
                        qvc.capsDsdBadge.stringValue.UTF8String ?: "");
            CK(![qvc.capsInfoLabel.stringValue containsString:@"MacBook Pro Speakers"] &&
               [qvc.capsInfoLabel.stringValue containsString:@"能力未知"] &&
               [qvc.capsPcmBadge.stringValue isEqualToString:@"PCM —"] &&
               [qvc.capsDsdBadge.stringValue isEqualToString:@"DSD —"],
               "C3k2 UPnP 探测失败时不回落到 CoreAudio 默认设备并显示「能力未知」",
               qvc.capsInfoLabel.stringValue ?: @"nil");

            // C3k3 UPnP + PCM + rate=max：卡面目标率随 caps 与 castCeiling 随动（与投放 compatible 决策一致）
            {
                NSDictionary *(^upnpCaps)(NSString *, NSArray *, NSNumber *) = ^NSDictionary *(NSString *nm, NSArray *rates, NSNumber *ceiling) {
                    NSMutableDictionary *j = [@{
                        @"ok": @YES,
                        @"device": @{@"name": nm, @"backend": @"upnp", @"rates": rates,
                                     @"maxRate": rates.lastObject, @"dop": @NO},
                    } mutableCopy];
                    if (ceiling) j[@"castCeiling"] = ceiling;
                    return j;
                };
                [qvc applyPresetCaps:upnpCaps(@"DAC-192", @[@44100, @192000], @192000)];
                CK([qvc.playSub.stringValue containsString:@"192"],
                   "C3k3a backend=upnp rate=max caps maxRate=192000 → playSub 含 192", qvc.playSub.stringValue ?: @"nil");
                [qvc applyPresetCaps:upnpCaps(@"DAC-96", @[@44100, @48000, @96000], @192000)];
                CK([qvc.playSub.stringValue containsString:@"96"] && ![qvc.playSub.stringValue containsString:@"192"],
                   "C3k3b apply 96000 caps → playSub 含 96（随动，不含 192）", qvc.playSub.stringValue ?: @"nil");
                [qvc applyPresetCaps:upnpCaps(@"DAC-384", @[@44100, @192000, @384000], @192000)];
                CK([qvc.playSub.stringValue containsString:@"192"] && ![qvc.playSub.stringValue containsString:@"384"],
                   "C3k3c caps 384k 但 castCeiling=192k → playSub 为 192（与实投一致）", qvc.playSub.stringValue ?: @"nil");
                [qvc applyPresetCaps:upnpCaps(@"DAC-mix", @[@44100, @176400, @192000], @192000)];
                CK([qvc.playSub.stringValue containsString:@"192"] && ![qvc.playSub.stringValue containsString:@"176"],
                   "C3k3d 声明 {176.4k,192k} → 卡面 192（禁止卡面 192 实投 176.4）", qvc.playSub.stringValue ?: @"nil");
            }

            // C3k4 旧设备 A 的 caps 回包延迟：切到 B，B 先回、A 后回 → 最终为 B，A 被丢弃
            {
                RLPQuickStartViewController *sq = [[RLPQuickStartViewController alloc] init];
                sq.view.frame = NSMakeRect(0, 0, 1100, 760);
                sq.filters = items;
                NSDictionary *(^kv)(NSString *) = ^NSDictionary *(NSString *dev) {
                    return @{@"backend": @"upnp", @"upnpdev": dev, @"rate": @"max",
                             @"filter": @"poly-sinc-tight-lp", @"dsd": @"0", @"directsdm": @"0"};
                };
                NSDictionary *(^capsFor)(NSString *, NSArray *) = ^NSDictionary *(NSString *nm, NSArray *rates) {
                    return @{@"ok": @YES, @"castCeiling": @192000,
                             @"device": @{@"name": nm, @"backend": @"upnp", @"rates": rates,
                                          @"maxRate": rates.lastObject, @"dop": @NO}};
                };
                sq.settings = kv(@"uuid:A");
                sq.presetCapsKey = [sq currentPresetCapsKey];
                NSString *keyA = sq.presetCapsKey;
                const NSUInteger seqA = [sq beginPresetCapsRequestWithKey:keyA];
                sq.settings = kv(@"uuid:B");
                sq.presetCapsKey = [sq currentPresetCapsKey];
                NSString *keyB = sq.presetCapsKey;
                const NSUInteger seqB = [sq beginPresetCapsRequestWithKey:keyB];
                const BOOL okB = [sq completePresetCaps:capsFor(@"Renderer-B", @[@44100, @96000]) seq:seqB key:keyB];
                const BOOL okA = [sq completePresetCaps:capsFor(@"Renderer-A", @[@44100, @192000]) seq:seqA key:keyA];
                CK(okB && !okA && [sq.presetCapsDevice isEqualToString:@"Renderer-B"] &&
                   [sq.capsInfoLabel.stringValue containsString:@"Renderer-B"] &&
                   ![sq.capsInfoLabel.stringValue containsString:@"Renderer-A"] &&
                   [sq.playSub.stringValue containsString:@"96"] && keyA.length && ![keyA isEqualToString:keyB],
                   "C3k4 B 先回 A 后回：最终 presetCapsDevice/capsInfoLabel/playSub 为 B，A 被丢弃",
                   [NSString stringWithFormat:@"okB=%d okA=%d dev=%@ info=%@ sub=%@", okB, okA,
                    sq.presetCapsDevice ?: @"nil", sq.capsInfoLabel.stringValue ?: @"", sq.playSub.stringValue ?: @""]);
                // 同一键下旧序号也必须丢弃（只认最新请求）
                const NSUInteger seqB1 = [sq beginPresetCapsRequestWithKey:keyB];
                const NSUInteger seqB2 = [sq beginPresetCapsRequestWithKey:keyB];
                const BOOL lateOld = [sq completePresetCaps:capsFor(@"Stale-B", @[@44100, @48000]) seq:seqB1 key:keyB];
                const BOOL newest = [sq completePresetCaps:capsFor(@"Renderer-B2", @[@44100, @96000]) seq:seqB2 key:keyB];
                CK(!lateOld && newest && [sq.presetCapsDevice isEqualToString:@"Renderer-B2"],
                   "C3k4b 同键旧序号回包丢弃、最新序号落地", sq.presetCapsDevice ?: @"nil");
            }

            // C3l 后端 GET /api/preset/caps：真实回环 mock UPnP 渲染器
            TestLoopbackUpnpRenderer mockRenderer(
                "Living Room DAC",
                "http-get:*:audio/L16:rate=44100,http-get:*:audio/L16:rate=48000,"
                "http-get:*:audio/L24:rate=96000,http-get:*:audio/wav:rate=176400,"
                "http-get:*:audio/L24:rate=192000");
            const BOOL startedMock = mockRenderer.start();
            CK(startedMock, "C3l-precondition 本地回环 UPnP mock 启动成功", @"");
            if (startedMock) {
                rlapp::reset_preset_probe_counts_for_test();
                NSString *descURL = [NSString stringWithUTF8String:mockRenderer.descURL().c_str()];
                NSString *postBody = [NSString stringWithFormat:@"backend=upnp&upnpdev=%@&volume=-120", RLPEnc(descURL)];
                [core jsonWithMethod:@"POST" path:@"/api/settings" body:postBody];
                NSDictionary *capsRes = [core jsonWithMethod:@"GET" path:@"/api/preset/caps" body:nil];
                const int caProbesL = rlapp::preset_coreaudio_probe_count_for_test();
                NSDictionary *cdev = [capsRes[@"device"] isKindOfClass:[NSDictionary class]] ? capsRes[@"device"] : @{};
                NSDictionary *cgate = [RLPQuickStartViewController gatingForCapsJSON:capsRes];
                std::printf("  [CASTCAPS /api/preset/caps] backend=%s name=%s rates=%s maxRate=%ld dop=%d dopMax=%s caProbes=%d descHits=%d cmHits=%d gating=(known=%d,pcm=%d,dsd=%d)\n",
                            [cdev[@"backend"] UTF8String] ?: "",
                            [cdev[@"name"] UTF8String] ?: "",
                            [[[cdev[@"rates"] description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String] ?: "",
                            (long)[cdev[@"maxRate"] integerValue],
                            [cdev[@"dop"] boolValue],
                            [cdev[@"dopMax"] UTF8String] ?: "",
                            caProbesL,
                            mockRenderer.descHits.load(),
                            mockRenderer.cmHits.load(),
                            [cgate[@"known"] boolValue],
                            [cgate[@"pcmReady"] boolValue],
                            [cgate[@"dsdReady"] boolValue]);
                NSArray *wantRates = @[@44100, @48000, @96000, @176400, @192000];
                CK([capsRes[@"ok"] boolValue] &&
                   [cdev[@"backend"] isEqualToString:@"upnp"] &&
                   [cdev[@"name"] isEqualToString:@"Living Room DAC"] &&
                   [cdev[@"rates"] isEqualToArray:wantRates] &&
                   [cdev[@"maxRate"] integerValue] == 192000 &&
                   [cdev[@"dop"] boolValue] &&
                   [cdev[@"dopMax"] isEqualToString:@"dsd64"] &&
                   caProbesL == 0 &&
                   mockRenderer.descHits.load() > 0 && mockRenderer.cmHits.load() > 0,
                   "C3l /api/preset/caps backend=upnp 探测选中 UPnP 渲染器 ProtocolInfo 且不调用 CoreAudio 探测",
                   capsRes.description ?: @"nil");

                // C3l2 caps JSON 新字段契约：probeKey / probeBackend / probeUpnpDev / castCeiling / refresh
                NSDictionary *capsRef = [core jsonWithMethod:@"GET" path:@"/api/preset/caps?refresh=1" body:nil];
                CK([capsRes[@"probeKey"] isKindOfClass:[NSString class]] &&
                   [capsRes[@"probeKey"] containsString:descURL] &&
                   [capsRes[@"probeBackend"] isEqualToString:@"upnp"] &&
                   [capsRes[@"probeUpnpDev"] isEqualToString:descURL] &&
                   // 2026-11-21：castCeiling 默认改为 `auto`（内部哨兵 0 = 跟随渲染器声明）。
                   // 所以这里不能再断言 > 0 —— 0 是**合法且默认**的取值。
                   // 仍要保证该字段存在且是数值（不是 null/缺失），并单独验「显式设了上限时如实回显」。
                   [capsRes[@"castCeiling"] respondsToSelector:@selector(unsignedIntegerValue)] &&
                   ![capsRes[@"refresh"] boolValue] &&
                   [capsRef[@"refresh"] boolValue] &&
                   [capsRef[@"probeKey"] isEqualToString:capsRes[@"probeKey"]] &&
                   [capsRef[@"device"][@"rates"] isEqualToArray:wantRates],
                   "C3l2 /api/preset/caps 回显 probeKey/probeBackend/probeUpnpDev/castCeiling，refresh=1 真实重探测",
                   capsRef.description ?: @"nil");
            }

            // C3m 可注入 UPnP probe hook：caps 与 /api/preset/apply 不走 CoreAudio 且按 UPnP caps 规划
            rlapp::set_upnp_caps_probe_override_for_test(
                true, true, "Mock Hook UPnP DAC",
                "http-get:*:audio/L16:rate=44100,http-get:*:audio/L24:rate=176400,http-get:*:audio/L24:rate=192000", "");
            rlapp::reset_preset_probe_counts_for_test();
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=upnp&upnpdev=http://127.0.0.1:1/mock&volume=-120"];
            NSDictionary *hookCaps = [core jsonWithMethod:@"GET" path:@"/api/preset/caps" body:nil];
            NSDictionary *hdev = [hookCaps[@"device"] isKindOfClass:[NSDictionary class]] ? hookCaps[@"device"] : @{};
            NSDictionary *applyPcm = [core jsonWithMethod:@"POST" path:@"/api/preset/apply?profile=pcm" body:nil];
            NSDictionary *applyDsd = [core jsonWithMethod:@"POST" path:@"/api/preset/apply?profile=pcm2dsd" body:nil];
            const int caProbesM = rlapp::preset_coreaudio_probe_count_for_test();
            std::printf("  [CASTCAPS hook-apply] backend=%s name=%s caProbes=%d applyPcmRate=%s applyDsd=%s\n",
                        [hdev[@"backend"] UTF8String] ?: "",
                        [hdev[@"name"] UTF8String] ?: "",
                        caProbesM,
                        [applyPcm[@"applied"][@"rate"] UTF8String] ?: "",
                        [applyDsd[@"applied"][@"dsd"] UTF8String] ?: "");
            CK([hookCaps[@"ok"] boolValue] &&
               [hdev[@"backend"] isEqualToString:@"upnp"] &&
               [hdev[@"name"] isEqualToString:@"Mock Hook UPnP DAC"] &&
               [hdev[@"rates"] isEqualToArray:@[@44100, @176400, @192000]] &&
               [hdev[@"dop"] boolValue] &&
               [hdev[@"dopMax"] isEqualToString:@"dsd64"] &&
               [applyPcm[@"ok"] boolValue] &&
               [applyPcm[@"applied"][@"rate"] isEqualToString:@"192000"] &&
               [applyPcm[@"applied"][@"filter"] isEqualToString:@"poly-sinc-tight-lp"] &&
               [applyDsd[@"ok"] boolValue] &&
               [applyDsd[@"applied"][@"dsd"] isEqualToString:@"64"] &&
               caProbesM == 0,
               "C3m UPnP caps hook 验证不调 CoreAudio 并按渲染器 192k/DoP64 执行 /api/preset/apply",
               [NSString stringWithFormat:@"pcm=%@ dsd=%@", applyPcm.description ?: @"", applyDsd.description ?: @""]);

            // C3n 探测失败与空 Sink 必须给出明确 probeNote 并按能力未知处理
            rlapp::set_upnp_caps_probe_override_for_test(true, false, "Offline Renderer", "", "SOAP GetProtocolInfo timeout");
            rlapp::reset_preset_probe_counts_for_test();
            NSDictionary *failCaps = [core jsonWithMethod:@"GET" path:@"/api/preset/caps" body:nil];
            NSDictionary *failGate = [RLPQuickStartViewController gatingForCapsJSON:failCaps];
            const int caProbesN = rlapp::preset_coreaudio_probe_count_for_test();
            CK([failCaps[@"ok"] boolValue] &&
               [failCaps[@"device"][@"backend"] isEqualToString:@"upnp"] &&
               [(NSArray *)failCaps[@"device"][@"rates"] count] == 0 &&
               [failCaps[@"device"][@"maxRate"] integerValue] == 0 &&
               [failCaps[@"probeNote"] containsString:@"SOAP GetProtocolInfo timeout"] &&
               ![failGate[@"known"] boolValue] && ![failGate[@"pcmReady"] boolValue] && ![failGate[@"dsdReady"] boolValue] &&
               caProbesN == 0,
               "C3n UPnP 探测失败返回明确 probeNote 且 known=0（不回落 CoreAudio）",
               failCaps.description ?: @"nil");

            // C3o 未选 upnpdev 时返回能力未知且给出明确选择提示
            rlapp::set_upnp_caps_probe_override_for_test(false, true, "", "", "");
            rlapp::reset_preset_probe_counts_for_test();
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=upnp&upnpdev=&volume=-120"];
            NSDictionary *unselCaps = [core jsonWithMethod:@"GET" path:@"/api/preset/caps" body:nil];
            NSDictionary *unselGate = [RLPQuickStartViewController gatingForCapsJSON:unselCaps];
            const int caProbesO = rlapp::preset_coreaudio_probe_count_for_test();
            CK([unselCaps[@"ok"] boolValue] &&
               [unselCaps[@"device"][@"backend"] isEqualToString:@"upnp"] &&
               [(NSArray *)unselCaps[@"device"][@"rates"] count] == 0 &&
               [unselCaps[@"probeNote"] containsString:@"未选择"] &&
               ![unselGate[@"known"] boolValue] &&
               caProbesO == 0,
               "C3o 未选 upnpdev 返回能力未知与明确 probeNote，不回落 CoreAudio",
               unselCaps.description ?: @"nil");

            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&upnpdev=&volume=-120"];
        }

        // ---------- C4 bitperfect 下风格禁用且不破坏直通 ----------
        RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
        vc.view.frame = NSMakeRect(0, 0, 1100, 760);
        vc.filters = items;
        vc.settings = @{@"backend": @"null", @"rate": @"src", @"dsd": @"0", @"filter": @"", @"directsdm": @"1"};
        [vc syncPlayAndStyleCards];
        CK([vc.styleValue.stringValue isEqualToString:RLPTr(@"保持原音")],
           "C4a bitperfect 下风格卡显示「保持原音」", vc.styleValue.stringValue ?: @"nil");
        CK(vc.styleCard.alphaValue < 0.9, "C4b bitperfect 下风格卡视觉置灰", @"");

        // C4c: 播放中切播放方式不中断播放、不改音量(-120)，且提示下一首/重新播放生效
        vc.playing = YES;
        vc.pausedNow = NO;
        NSButton *pickBpBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
        pickBpBtn.identifier = @"0";
        [vc onPickPlayMode:pickBpBtn];
        NSString *inflightNote = vc.presetNotes.stringValue ?: @"";
        for (int spin = 0; spin < 40; ++spin) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
            if ([vc.presetNotes.stringValue rangeOfString:@"正在保存"].location == NSNotFound) break;
        }
        NSDictionary *kvAfterPick = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
        CK(vc.playing && !vc.pausedNow &&
           [inflightNote rangeOfString:@"下一首或重新播放时生效"].location != NSNotFound &&
           [vc.presetNotes.stringValue rangeOfString:@"下一首或重新播放时生效"].location != NSNotFound &&
           [kvAfterPick[@"volume"] isEqualToString:@"-120"],
           "C4c 播放中 onPickPlayMode 不停播不改音量且明确提示下一首或重新播放生效",
           [NSString stringWithFormat:@"inflight=%@ final=%@ vol=%@",
            inflightNote, vc.presetNotes.stringValue ?: @"nil", kvAfterPick[@"volume"] ?: @"nil"]);

        // ---------- C5 真实几何自适应（宽4/中2/窄1 等宽 + 单层滚动 + 页头入口）----------
        CK(FindById(vc.view, @"room.folders") != nil, "C5a 页头存在音乐文件夹入口 room.folders", @"");

        // 统计垂直 NSScrollView 数量（必须恰好 1 个）
        NSMutableArray<NSView *> *allViews = [NSMutableArray array];
        CollectViews(vc.view, allViews);
        int vertScrolls = 0;
        for (NSView *v in allViews) {
            if ([v isKindOfClass:[NSScrollView class]] && ((NSScrollView *)v).hasVerticalScroller)
                ++vertScrolls;
        }
        CK(vertScrolls == 1, "C5b 页面只有一个垂直滚动容器（单层滚动）",
           [NSString stringWithFormat:@"vertScrolls=%d", vertScrolls]);

        NSView *c1 = FindById(vc.view, @"room.device");
        NSView *c2 = FindById(vc.view, @"room.output");
        NSView *c3 = FindById(vc.view, @"room.play");
        NSView *c4 = FindById(vc.view, @"room.style");

        // 宽窗：4 列等宽一行
        vc.view.frame = NSMakeRect(0, 0, 1100, 760);
        [vc updateResponsiveLayoutForWidth:1052.0];
        [vc.view layoutSubtreeIfNeeded];
        CK(std::fabs(c1.frame.size.width - c2.frame.size.width) <= 1.5 &&
           std::fabs(c2.frame.size.width - c3.frame.size.width) <= 1.5 &&
           std::fabs(c3.frame.size.width - c4.frame.size.width) <= 1.5 &&
           c1.frame.size.width > 150.0 &&
           std::fabs(c1.frame.origin.y - c4.frame.origin.y) <= 1.5,
           "C5c 宽窗 1100px -> 4 列等宽一行",
           [NSString stringWithFormat:@"w=[%.1f,%.1f,%.1f,%.1f]",
            c1.frame.size.width, c2.frame.size.width, c3.frame.size.width, c4.frame.size.width]);

        // 中窗：2 列等宽两行
        vc.view.frame = NSMakeRect(0, 0, 620, 760);
        [vc updateResponsiveLayoutForWidth:572.0];
        [vc.view layoutSubtreeIfNeeded];
        CK(std::fabs(c1.frame.size.width - c2.frame.size.width) <= 1.5 &&
           std::fabs(c1.frame.size.width - c3.frame.size.width) <= 1.5 &&
           std::fabs(c1.frame.origin.y - c2.frame.origin.y) <= 1.5 &&
           c3.frame.origin.y < c1.frame.origin.y - 10.0,
           "C5d 中窗 620px -> 2x2 等宽两行",
           [NSString stringWithFormat:@"y1=%.1f y2=%.1f y3=%.1f",
            c1.frame.origin.y, c2.frame.origin.y, c3.frame.origin.y]);

        // 窄窗：1 列四行等宽
        vc.view.frame = NSMakeRect(0, 0, 340, 760);
        [vc updateResponsiveLayoutForWidth:292.0];
        [vc.view layoutSubtreeIfNeeded];
        CK(std::fabs(c1.frame.size.width - c4.frame.size.width) <= 1.5 &&
           c1.frame.origin.y > c2.frame.origin.y + 10.0 &&
           c2.frame.origin.y > c3.frame.origin.y + 10.0 &&
           c3.frame.origin.y > c4.frame.origin.y + 10.0,
           "C5e 窄窗 340px -> 1 列四行等宽",
           [NSString stringWithFormat:@"y=[%.1f,%.1f,%.1f,%.1f]",
            c1.frame.origin.y, c2.frame.origin.y, c3.frame.origin.y, c4.frame.origin.y]);

        CK([RLPPlayModeFromSettings(@{@"dsd": @"dop256"}) isEqualToString:@"dsd"],
           "C6a legacy dop256 派生 dsd 播放方式", @"");
        CK([RLPPlayModeFromSettings(@{@"dsd": @"native128"}) isEqualToString:@"dsd"],
           "C6b legacy native128 派生 dsd 播放方式", @"");

        // C7 680/820/1180 几何防重叠（聆听室四卡）
        for (NSNumber *wn in @[@680, @820, @1180]) {
            const CGFloat w = wn.doubleValue;
            RLPQuickStartViewController *qvc = [[RLPQuickStartViewController alloc] init];
            qvc.view.frame = NSMakeRect(0, 0, w, 800);
            [qvc updateResponsiveLayoutForWidth:(w - 48.0)];
            [qvc.view layoutSubtreeIfNeeded];
            NSView *q1 = FindById(qvc.view, @"room.device");
            NSView *q2 = FindById(qvc.view, @"room.output");
            NSView *q3 = FindById(qvc.view, @"room.play");
            NSView *q4 = FindById(qvc.view, @"room.style");
            NSArray<NSView *> *cards = @[q1 ?: [NSView new], q2 ?: [NSView new], q3 ?: [NSView new], q4 ?: [NSView new]];
            BOOL overlap = NO;
            for (NSUInteger i = 0; i < cards.count; ++i) {
                NSRect r1 = [cards[i] convertRect:cards[i].bounds toView:qvc.view];
                for (NSUInteger j = i + 1; j < cards.count; ++j) {
                    NSRect r2 = [cards[j] convertRect:cards[j].bounds toView:qvc.view];
                    NSRect inter = NSIntersectionRect(r1, r2);
                    if (inter.size.width > 1.0 && inter.size.height > 1.0) overlap = YES;
                }
            }
            CK(!overlap && q1 && q2 && q3 && q4,
               [[NSString stringWithFormat:@"C7_%d 聆听室四卡无几何重叠", (int)w] UTF8String], @"");
        }

        // C8 聆听室 Hog 回退标签（hogAcquired=NO / fallbackWhy 非空时不得声称 · Hog）
        {
            RLPQuickStartViewController *qvc = [[RLPQuickStartViewController alloc] init];
            (void)qvc.view;
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=coreaudio&hogexcl=1"];
            [qvc reloadSettings];
            for (int spin = 0; spin < 30; ++spin) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            SEL applySel = NSSelectorFromString(@"applyStatusJSON:");
            BOOL hasApply = [qvc respondsToSelector:applySel];
            if (hasApply) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [qvc performSelector:applySel withObject:@{@"ok": @YES, @"hogAcquired": @NO, @"fallbackWhy": @"Device busy"}];
#pragma clang diagnostic pop
            }
            NSTextField *outVal = [qvc valueForKey:@"outputValue"];
            NSString *txt = outVal.stringValue ?: @"";
            CK(hasApply && [txt containsString:@"Hog（已回退）"],
               "C8a 快速开始在 hogAcquired=NO/fallbackWhy 非空时显示 Hog（已回退）", txt);

            if (hasApply) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [qvc performSelector:applySel withObject:@{@"ok": @YES, @"hogAcquired": @YES, @"fallbackWhy": @""}];
#pragma clang diagnostic pop
            }
            NSString *txtOk = outVal.stringValue ?: @"";
            CK(hasApply && [txtOk containsString:@"· Hog"] && ![txtOk containsString:@"已回退"],
               "C8b 快速开始在 hogAcquired=YES 时显示 · Hog", txtOk);
        }

        // ---------- C9 输出浮层 UPnP 发现/具体设备选择 + 切回本地保留本地设备 ----------
        {
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=coreaudio&device=USB-DAC-TEST&volume=-120"];
            RLPQuickStartViewController *ovc = [[RLPOfflineOutputController alloc] init];
            (void)ovc.view;
            [ovc reloadSettings];
            for (int spin = 0; spin < 30; ++spin) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            CK([ovc.localDevice isEqualToString:@"USB-DAC-TEST"],
               "C9a reloadSettings 记忆当前本地设备 USB-DAC-TEST", ovc.localDevice ?: @"nil");

            NSTextField *sub = (NSTextField *)FindById(ovc.view, @"room.subtitle");
            CK(sub != nil && [sub.stringValue rangeOfString:@"微调每一组声音"].location == NSNotFound,
               "C9b 聆听室副标题不是工作台文案", sub.stringValue ?: @"nil");

            [ovc onOpenOutput:nil];
            NSView *popView = ovc.popover.contentViewController.view;
            [popView layoutSubtreeIfNeeded];
            NSPopUpButton *upnpPop = (NSPopUpButton *)FindById(popView, @"output.upnpDevice");
            NSButton *upnpScan = (NSButton *)FindById(popView, @"output.upnpScan");
            NSButton *upnpApply = (NSButton *)FindById(popView, @"output.upnpApply");
            NSButton *hogChk = (NSButton *)FindById(popView, @"output.hogexcl");
            NSButton *caBtn = (NSButton *)FindById(popView, @"coreaudio");
            NSButton *upnpBtn = (NSButton *)FindById(popView, @"upnp");
            CK(popView != nil && upnpPop && upnpScan && upnpApply && hogChk && caBtn && upnpBtn,
               "C9c 输出浮层包含后端选项、UPnP 设备下拉、扫描/应用按钮与 Hog 开关（单层浮层不删功能）", @"");

            // 检查浮层内交互控件无几何重叠
            NSArray<NSView *> *popControls = @[caBtn ?: [NSView new], upnpBtn ?: [NSView new],
                                               upnpPop ?: [NSView new], upnpScan ?: [NSView new],
                                               upnpApply ?: [NSView new], hogChk ?: [NSView new]];
            BOOL popOverlap = NO;
            for (NSUInteger i = 0; i < popControls.count; ++i) {
                NSRect r1 = [popControls[i] convertRect:popControls[i].bounds toView:popView];
                for (NSUInteger j = i + 1; j < popControls.count; ++j) {
                    NSRect r2 = [popControls[j] convertRect:popControls[j].bounds toView:popView];
                    NSRect inter = NSIntersectionRect(r1, r2);
                    if (inter.size.width > 1.0 && inter.size.height > 1.0) popOverlap = YES;
                }
            }
            CK(!popOverlap, "C9d 输出浮层控件无几何重叠", @"");

            // 模拟点击「投放到局域网设备」并注入 /api/cast/devices 真实格式载荷（不触发真实网络扫描）
            [ovc onPickBackend:upnpBtn];
            [ovc applyCastDevicesPayload:@{
                @"ok": @YES,
                @"devices": @[
                    @{@"friendlyName": @"Living Room", @"model": @"Marantz", @"host": @"192.168.1.50",
                      @"location": @"http://192.168.1.50:49152/desc.xml", @"kind": @"upnp"},
                ]
            }];
            CK(upnpPop.enabled && upnpApply.enabled &&
               [[upnpPop.selectedItem representedObject] isEqualToString:@"http://192.168.1.50:49152/desc.xml"],
               "C9e 发现列表填充具体 UPnP 设备并选中 location", [upnpPop.selectedItem representedObject] ?: @"nil");

            [ovc onApplyUpnpOutput:upnpApply];
            for (int spin = 0; spin < 40; ++spin) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            NSDictionary *kvUpnp = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
            CK([kvUpnp[@"backend"] isEqualToString:@"upnp"] &&
               [kvUpnp[@"upnpdev"] isEqualToString:@"http://192.168.1.50:49152/desc.xml"] &&
               [ovc.outputValue.stringValue containsString:@"Living Room"],
               "C9f 应用后 /api/settings 落盘 backend=upnp 与 upnpdev，摘要显示设备名",
               [NSString stringWithFormat:@"bk=%@ upnpdev=%@ out=%@",
                kvUpnp[@"backend"] ?: @"nil", kvUpnp[@"upnpdev"] ?: @"nil", ovc.outputValue.stringValue ?: @"nil"]);

            // 切回本地（coreaudio-shared）：必须保留先前的本地设备 USB-DAC-TEST
            NSButton *sharedBtn = (NSButton *)FindById(popView, @"coreaudio-shared");
            [ovc onPickBackend:sharedBtn];
            for (int spin = 0; spin < 40; ++spin) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            NSDictionary *kvBack = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
            CK([kvBack[@"backend"] isEqualToString:@"coreaudio-shared"] &&
               [kvBack[@"device"] isEqualToString:@"USB-DAC-TEST"],
               "C9g 切回本地后保留先前本地设备 USB-DAC-TEST",
               [NSString stringWithFormat:@"bk=%@ dev=%@", kvBack[@"backend"] ?: @"nil", kvBack[@"device"] ?: @"nil"]);

            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];
        }

        // ---------- N4 聆听室底部入口改成「打开专辑页」，点击进入当前曲所属专辑详情而非曲目详情 ----------
        {
            RLPQuickStartViewController *n4vc = [[RLPQuickStartViewController alloc] init];
            (void)n4vc.view;
            NSButton *openBtn = (NSButton *)FindById(n4vc.view, @"room.openAlbum");
            CK(openBtn != nil && openBtn == n4vc.npOpenButton,
               "N4a 聆听室按钮暴露 room.openAlbum（并与 npOpenButton 一致）",
               openBtn.identifier ?: @"nil");
            CK(openBtn && [openBtn.title isEqualToString:RLPTr(@"打开专辑页")] &&
               ![openBtn.title isEqualToString:RLPTr(@"打开曲目详情")],
               "N4b 按钮标题为「打开专辑页」而非「打开曲目详情」",
               openBtn.title ?: @"nil");
            [n4vc applyLanguage];
            CK(openBtn && [openBtn.title isEqualToString:RLPTr(@"打开专辑页")],
               "N4c 语言刷新后标题仍为「打开专辑页」",
               openBtn.title ?: @"nil");

            __block NSInteger npFired = 0;
            NSMutableArray<NSString *> *openedAlbums = [NSMutableArray array];
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            id obNP = [nc addObserverForName:@"RLPOpenNowPlayingNotification" object:nil queue:nil
                                  usingBlock:^(NSNotification *note) {
                (void)note;
                ++npFired;
            }];
            id obAlb = [nc addObserverForName:RLPOpenAlbumNotification object:nil queue:nil
                                   usingBlock:^(NSNotification *note) {
                if ([note.object isKindOfClass:[NSString class]]) [openedAlbums addObject:note.object];
            }];

            n4vc.currentPath = @"/offline/ArtistA/SymphonyB/01.flac";
            n4vc.lastMetaDict = @{@"title": @"Mov I", @"album": @"Symphony Album B", @"artist": @"Conductor A"};
            RLPAlbum *alb0 = [[RLPAlbum alloc] init];
            alb0.key = @"alb-other"; alb0.name = @"Other Album"; alb0.artist = @"Someone";
            RLPAlbum *alb1 = [[RLPAlbum alloc] init];
            alb1.key = @"alb-sym-b"; alb1.name = @"Symphony Album B"; alb1.artist = @"Conductor A";
            n4vc.albumsData = @[alb0, alb1];

            CK(openBtn && openBtn.enabled && openBtn.target == n4vc && openBtn.action == @selector(onOpenCurrentAlbum:),
               "N4d openBtn 绑定 onOpenCurrentAlbum:",
               NSStringFromSelector(openBtn.action ?: NULL));
            [NSApp sendAction:openBtn.action to:openBtn.target from:openBtn];
            CK(npFired == 0 && openedAlbums.count == 1 && [openedAlbums.lastObject isEqualToString:@"alb-sym-b"],
               "N4e 点击打开当前曲所属专辑页（key=alb-sym-b）且不再打开 track detail",
               [NSString stringWithFormat:@"np=%ld albums=%@", (long)npFired, openedAlbums]);

            // direct albumKey 路径
            n4vc.albumsData = @[];
            n4vc.lastMetaDict = @{@"title": @"Mov I", @"album": @"Direct", @"albumKey": @"alb-direct-key"};
            [NSApp sendAction:openBtn.action to:openBtn.target from:openBtn];
            CK(npFired == 0 && openedAlbums.count == 2 && [openedAlbums.lastObject isEqualToString:@"alb-direct-key"],
               "N4f metadata 含 albumKey 时直接打开对应专辑详情",
               [NSString stringWithFormat:@"np=%ld albums=%@", (long)npFired, openedAlbums]);

            // albumsData 为空时走 /api/lib/albums?q= 查询回落
            n4vc.albumsData = @[];
            n4vc.lastMetaDict = @{@"title": @"Mov II", @"album": @"Fallback Album", @"artist": @"Fallback Artist"};
            Method getM = class_getInstanceMethod(RLPCoreClient.class, @selector(getJSON:completion:));
            IMP origGet = method_getImplementation(getM);
            __block NSString *queriedURL = nil;
            IMP mockGet = imp_implementationWithBlock(^(id selfObj, NSString *path, RLPJSONCompletion done) {
                (void)selfObj;
                queriedURL = path;
                if (done) {
                    done(@{@"ok": @YES,
                           @"albums": @[@{@"k": @"alb-fallback-k", @"name": @"Fallback Album", @"artist": @"Fallback Artist"}]});
                }
            });
            method_setImplementation(getM, mockGet);
            @try {
                [NSApp sendAction:openBtn.action to:openBtn.target from:openBtn];
            } @finally {
                method_setImplementation(getM, origGet);
                imp_removeBlock(mockGet);
            }
            CK(npFired == 0 && queriedURL && [queriedURL hasPrefix:@"/api/lib/albums?q="] &&
               openedAlbums.count == 3 && [openedAlbums.lastObject isEqualToString:@"alb-fallback-k"],
               "N4g 本地列表未命中时查询 /api/lib/albums?q= 并进入匹配专辑详情（key=alb-fallback-k）",
               [NSString stringWithFormat:@"url=%@ np=%ld albums=%@", queriedURL ?: @"nil", (long)npFired, openedAlbums]);

            [nc removeObserver:obNP];
            [nc removeObserver:obAlb];
        }

        // 隔离：B1/B2/B3 会在离屏主窗里创建额外 VC，放在核心契约全部跑完后避免污染 C9 的设备/设置状态。
        TestRoomCoverAndCacheFitB1B2B3();
        TestListeningQueueFollow();

        [core shutdown];
        [fm removeItemAtPath:root error:nil];
        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "native_listening_contract 全部通过" : "native_listening_contract 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
