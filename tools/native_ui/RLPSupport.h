// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSupport.h — 原生 UI 的公共小工具（翻译/格式化/封面/提示/按钮/动作）
//
// 统一放在这里的目的：页面之间不各写一套格式化与封面缓存；i18n 只有一个入口
// （RLPTr），将来把 docs/i18n 的词表生成为原生表时，所有已包 RLPTr 的文案自动生效。
#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>

NS_ASSUME_NONNULL_BEGIN

/// 中文原文 → 当前语言。词表未命中时原样返回中文（与 web 版"回落中文"同口径）。
NSString *RLPTr(NSString *zh);
/// 设置语言（"zh"/"en"）。原生 UI 在设置读取后调用；未设置时按中文。
void RLPSetLanguage(NSString * _Nullable lang);
NSString *RLPLanguage(void);

/// 读**已落盘**的界面语言（state 目录 rlplayer-settings.conf 的 lang，"zh"/"en"）。
/// 缺失或非法返回 nil。与 web 同口径（src/net/ui_page.h 的 read_conf_value）：
/// 配置文件是语言优先级的唯一真相源，不靠后端 GET。
NSString * _Nullable RLPLanguageFromConf(void);
/// 启动早期（建菜单/建窗口之前）调用：把落盘语言应用到 RLPTr。
/// 那时核心还没起来，所以只读 conf —— 这也是"每次 RLPTr 都不打后端"的保证。
void RLPApplyLanguageFromConf(void);

/// 时长："m:ss" / "h:mm:ss"；非有限值返回 "0:00"。
NSString *RLPFmtDuration(double seconds);
/// 字节数："12.3 MB"。
NSString *RLPFmtBytes(double bytes);
/// URL query 编码（key/路径进 URL 时统一走这里）。
NSString *RLPEnc(NSString *s);

/// 专辑封面共享缓存（512px 缩略图由后端 /api/lib/cover 提供）。
@interface RLPCoverLoader : NSObject
+ (instancetype)shared;
/// completion 在主线程；失败回 nil（不重试、不阻塞）。
- (void)coverForAlbumKey:(NSString *)key completion:(void (^)(NSImage * _Nullable image))completion;
- (nullable NSImage *)cachedCoverForAlbumKey:(NSString *)key;
/// 流媒体封面（/api/src/cover?id=coverId）。与专辑封面同一缓存，key 加 src: 前缀避免撞。
- (void)coverForSourceId:(NSString *)coverId completion:(void (^)(NSImage * _Nullable image))completion;
@end

/// 封面视图：按 web `object-fit:cover` 语义绘制 —— 等比放大铺满并裁掉溢出，绝不 letterbox。
/// NSImageView 默认的 NSImageScaleProportionallyUpOrDown 在非正方形容器里会留白边
/// （用户实测：原生专辑页封面四边白条，web 版铺满无白边）。
@interface RLPCoverImageView : NSImageView
@end

/// 内层滚动容器：当自身在该方向上不可滚动时，把滚轮事件交给外层整页滚动。
/// 用户实测：专辑页鼠标停在曲目列表/其他作品条上时滚轮失灵 —— 内层 NSScrollView
/// 吃掉了事件却无处可滚。web 只有一个整页滚动容器（.main{overflow:auto}）。
@interface RLPForwardingScrollView : NSScrollView
@end

/// 轻提示（非模态，1.8s 淡出）。用于"已加入队列""已收藏"这类反馈。
void RLPToast(NSString *message);
/// 播放错误显示短摘要，完整诊断按需查看/复制。
void RLPPlaybackErrorToast(NSString *error);

/// 模态提示（必须让用户看见的失败；例如更新失败）。主线程调用。
void RLPAlert(NSString *title, NSString *message);

/// 文本输入对话框（web 版 askText 的原生对应：标题 / 输入框 + 占位符 / 提示小字 / 确定·取消）。
/// 返回 nil = 取消或输入为空（两侧都 trim）。主线程调用。
NSString * _Nullable RLPAskText(NSString *title, NSString *okTitle, NSString *value,
                                NSString * _Nullable placeholder, NSString * _Nullable hint);

/// 行悬停底色（web `.trow:hover`）：NSTableRowView 自己收 mouseEntered/Exited 并绘制底色。
/// 表格页只需在 `-tableView:rowViewForRow:` 返回它、给 hoverColor。
@interface RLPHoverRowView : NSTableRowView
@property (nonatomic, strong, nullable) NSColor *hoverColor;
/// 判据入口：直接设悬停态（真实路径是 tracking area 的 mouseEntered/Exited）。
- (void)setHoveredForAudit:(BOOL)hovered;
@property (nonatomic, readonly) BOOL hoveredForAudit;
@end

/// 系统符号按钮（无边框、模板着色）。
NSButton *RLPSymbolButton(NSString *symbol, NSString *tooltip, id _Nullable target, SEL _Nullable action);
/// 单行标签（默认 13px；颜色/字体可后改）。
NSTextField *RLPLabel(NSString *text, NSFont *font, NSColor *color);

/// 卡片式弹层（NSPopover 封装）：从 anchorView 下方弹出一张卡片，选完即时生效。
/// 用户要求「全部就在这一栏里用卡片式弹层完成」——不是模态 sheet、不是跳设置页。
/// content 由调用方搭好（自己负责约束与主题）；返回 popover 以便调用方主动关闭。
NSPopover *RLPShowCardPopover(NSView *anchorView, NSViewController *content, CGFloat width);
/// 便捷：把一个普通 NSView 包成弹层内容控制器（高度按约束自适应，给定最小高度）。
NSViewController *RLPCardController(NSView *card, CGFloat width, CGFloat minHeight);

/// 页面间导航（广播）：专辑详情 / 艺术家详情 / 返回。
/// 用通知而不是互相持有：页面只发意图，主窗口负责路由与返回栈。
extern NSNotificationName const RLPOpenAlbumNotification;   // object = album key(NSString)
extern NSNotificationName const RLPOpenArtistNotification;  // object = artist name(NSString)
extern NSNotificationName const RLPBackNotification;
/// 设置/预设/配置档成功保存后的跨页面同步通知（object = 发起保存的控制器，接收方忽略 object == self 防环）。
extern NSNotificationName const RLPSettingsChangedNotification;
/// 运行时界面语言变更通知（object = 发起切换的控制器或 nil）。
extern NSNotificationName const RLPLanguageDidChangeNotification;
/// 播放控制动作（play/lib/play/skip/pause/stop）开始通知：用于作废在途 /api/status 轮询。
extern NSNotificationName const RLPPlaybackActionStartedNotification;
/// 收藏状态变更后的跨页面同步通知（object = 发起变更的控制器或锚点视图，接收方忽略 object == self 防环）。
extern NSNotificationName const RLPFavoritesChangedNotification;
/// 队列内容变更后的跨页面同步通知（如单曲入队成功）。
extern NSNotificationName const RLPQueueChangedNotification;
/// 收藏路径规范化：统一 "\\" 与 "/" 以便与 /api/fav/list 准确比对。
NSString *RLPFavNormalizePath(NSString * _Nullable path);

/// 解析设置中的 dsd 值（支持纯数字 "0"/"64"/"256" 与 legacy "dop256"/"nat128"/"native64"）。
NSInteger RLPParseDsdRate(id _Nullable raw);
/// 判断文本框是否正在被用户编辑（通知刷新时跳过覆写，避免打断输入）。
BOOL RLPTextFieldIsEditing(NSTextField * _Nullable tf);
void RLPRequestOpenAlbum(NSString *albumKey);
void RLPRequestOpenArtist(NSString *artistName);
void RLPRequestBack(void);

/// 播放/入队动作（与 web 版同一 /api 契约，不复制播放逻辑）。
uint64_t RLPBeginPlaybackAction(void);
uint64_t RLPPlaybackActionEpoch(void);
BOOL RLPHandlePlaybackActionResponse(NSDictionary * _Nullable json, NSString * _Nullable fallbackError);
void RLPReportPlaybackStatusError(NSString * _Nullable error);
void RLPReportPlaybackStatusErrorForTrack(NSString * _Nullable error, NSString * _Nullable path);
void RLPResetPlaybackErrorState(void);
void RLPPlayPath(NSString *path);
/// CUE 分轨：cs/ce >= 0 时带区间（web playPath(file, cs, ce) 同契约），否则退化为整轨。
void RLPPlayPathCue(NSString *path, double cs, double ce);
void RLPPlayAlbum(NSString *albumKey, NSInteger startIndex);
void RLPEnqueuePath(NSString *path);
/// CUE 分轨（tools/rtaweb.cpp parseForm 契约：cue_start / cue_end）。cs < 0 时退化为整首。
void RLPPlayPathCueRange(NSString *path, double cs, double ce);
void RLPPlayAlbumCue(NSString *albumKey, NSInteger startIndex, double cs, double ce);
void RLPEnqueuePathCue(NSString *path, double cs, double ce);
void RLPPostJSON(NSString *path, NSString * _Nullable body);

/// v3.3.11 `toggleVolumeMute` 的**唯一状态**（web `volumeRestore` 是全局单例）。
/// 播放页与底栏两个静音键必须共用同一份记忆值，否则「在播放页静音、到底栏取消静音」会恢复成错误值。
/// 返回应下发的 dB；返回 **NAN** 表示上游语义的「什么都不做」（当前已 -120 且无恢复值）。
double RLPVolumeMuteNextDb(double currentDb);
/// 窗口收敛的显式状态：converged=NO 表示可用区无效（如 <=1pt 或缺失），frame 未被压成 0/负或畸形尺寸。
typedef struct {
    NSRect frame;
    BOOL converged;
} RLPWindowClampResult;

static inline BOOL RLPScreenRectIsValid(NSRect r, CGFloat minExtent) {
    return isfinite((double)r.origin.x) && isfinite((double)r.origin.y) &&
           isfinite((double)r.size.width) && isfinite((double)r.size.height) &&
           r.size.width > minExtent && r.size.height > minExtent;
}

/// 把窗口 frame 收敛到当前屏幕可见区（带显式收敛状态）：
///   - 可用区 <= 1pt（或非有限）时明确返回 converged=NO 且保留合法正尺寸 frame；
///     若输入 frame 本身是 0/负/NaN 等畸形尺寸，兜底修正为正尺寸（优先 minSize，否则 >=2pt），绝不返回 0 宽/0 高/负值。
///   - **minSize 任一维 <= 0（或缺省）表示「没有下限」**：NSWindow.minSize 的默认值就是 0×0，
///     面板/工具窗也常不设。旧实现把 <=0 当成「可见区全尺寸」，于是没设下限的窗口会被撑满整块屏
///     （2026-11-18 夜间评审：minSize<=0 —— 一个只该改 origin 的收敛把 300×200 的窗口撑成了 1920×1050）。
static inline RLPWindowClampResult RLPClampWindowFrameToVisibleChecked(NSRect frame,
                                                                       NSRect visible,
                                                                       NSSize minSize) {
    RLPWindowClampResult res;
    NSSize min = minSize;
    if (!isfinite((double)min.width) || !(min.width > 0)) min.width = 0;    // <=0 或 NaN：没有下限，**不是**"撑满可见区"
    if (!isfinite((double)min.height) || !(min.height > 0)) min.height = 0;

    NSRect safeFrame = frame;
    const BOOL visibleValid = RLPScreenRectIsValid(visible, 1.0);
    if (!isfinite((double)safeFrame.origin.x)) safeFrame.origin.x = visibleValid ? visible.origin.x : 0.0;
    if (!isfinite((double)safeFrame.origin.y)) safeFrame.origin.y = visibleValid ? visible.origin.y : 0.0;
    if (!isfinite((double)safeFrame.size.width) || !(safeFrame.size.width > 0)) {
        safeFrame.size.width = (min.width > 0) ? min.width : 2.0;
    }
    if (!isfinite((double)safeFrame.size.height) || !(safeFrame.size.height > 0)) {
        safeFrame.size.height = (min.height > 0) ? min.height : 2.0;
    }

    if (!visibleValid) {
        res.frame = safeFrame;
        res.converged = NO;
        return res;
    }

    if (min.width > visible.size.width) min.width = visible.size.width;     // 小屏：下限只能到可见区
    if (min.height > visible.size.height) min.height = visible.size.height;
    safeFrame.size.width = MAX(MIN(safeFrame.size.width, visible.size.width), min.width);
    safeFrame.size.height = MAX(MIN(safeFrame.size.height, visible.size.height), min.height);
    if (NSMinX(safeFrame) < NSMinX(visible)) safeFrame.origin.x = NSMinX(visible);
    if (NSMaxX(safeFrame) > NSMaxX(visible)) safeFrame.origin.x = NSMaxX(visible) - safeFrame.size.width;
    if (NSMinY(safeFrame) < NSMinY(visible)) safeFrame.origin.y = NSMinY(visible);
    if (NSMaxY(safeFrame) > NSMaxY(visible)) safeFrame.origin.y = NSMaxY(visible) - safeFrame.size.height;
    res.frame = safeFrame;
    res.converged = YES;
    return res;
}

static inline NSRect RLPClampWindowFrameToVisible(NSRect frame, NSRect visible, NSSize minSize) {
    return RLPClampWindowFrameToVisibleChecked(frame, visible, minSize).frame;
}

typedef struct {
    double a;
    double b;
} RLPInterval1D;

static inline void RLPSortDoubles(double *arr, size_t n) {
    for (size_t i = 1; i < n; ++i) {
        const double key = arr[i];
        size_t j = i;
        while (j > 0 && arr[j - 1] > key) {
            arr[j] = arr[j - 1];
            --j;
        }
        arr[j] = key;
    }
}

static inline void RLPSortIntervals(RLPInterval1D *arr, size_t n) {
    for (size_t i = 1; i < n; ++i) {
        const RLPInterval1D key = arr[i];
        size_t j = i;
        while (j > 0 && (arr[j - 1].a > key.a || (arr[j - 1].a == key.a && arr[j - 1].b > key.b))) {
            arr[j] = arr[j - 1];
            --j;
        }
        arr[j] = key;
    }
}

/// 精确判定矩形 `rect` 是否 100% 落在 `visibles[0..count-1]` 的并集之内（不含任何屏外/屏间死区）。
static inline BOOL RLPRectCoveredByScreens(NSRect rect, const NSRect *visibles, size_t count) {
    if (!visibles || count == 0 || !RLPScreenRectIsValid(rect, 0.0)) return NO;
    const double rx0 = (double)NSMinX(rect);
    const double rx1 = (double)NSMaxX(rect);
    const double ry0 = (double)NSMinY(rect);
    const double ry1 = (double)NSMaxY(rect);
    const double eps = 1e-6;

    enum { kStackCap = 32 };
    double xsStack[2 * kStackCap + 2];
    RLPInterval1D ysStack[kStackCap];
    double *xs = xsStack;
    RLPInterval1D *ys = ysStack;
    BOOL heapAlloc = NO;
    if (count > kStackCap) {
        xs = (double *)malloc(sizeof(double) * (2 * count + 2));
        ys = (RLPInterval1D *)malloc(sizeof(RLPInterval1D) * count);
        if (!xs || !ys) {
            free(xs);
            free(ys);
            return NO;
        }
        heapAlloc = YES;
    }

    size_t xCount = 0;
    xs[xCount++] = rx0;
    xs[xCount++] = rx1;
    for (size_t i = 0; i < count; ++i) {
        if (!RLPScreenRectIsValid(visibles[i], 0.0)) continue;
        const double sx0 = (double)NSMinX(visibles[i]);
        const double sx1 = (double)NSMaxX(visibles[i]);
        if (sx1 <= rx0 + eps || sx0 >= rx1 - eps) continue;
        xs[xCount++] = sx0 < rx0 ? rx0 : sx0;
        xs[xCount++] = sx1 > rx1 ? rx1 : sx1;
    }
    RLPSortDoubles(xs, xCount);

    BOOL covered = YES;
    for (size_t xi = 0; xi + 1 < xCount; ++xi) {
        const double xa = xs[xi];
        const double xb = xs[xi + 1];
        if (xb - xa <= eps) continue;
        const double xm = 0.5 * (xa + xb);
        size_t yCount = 0;
        for (size_t i = 0; i < count; ++i) {
            if (!RLPScreenRectIsValid(visibles[i], 0.0)) continue;
            const double sx0 = (double)NSMinX(visibles[i]);
            const double sx1 = (double)NSMaxX(visibles[i]);
            if (sx0 > xm || sx1 < xm) continue;
            const double sy0 = (double)NSMinY(visibles[i]);
            const double sy1 = (double)NSMaxY(visibles[i]);
            const double cy0 = sy0 < ry0 ? ry0 : sy0;
            const double cy1 = sy1 > ry1 ? ry1 : sy1;
            if (cy1 - cy0 > eps) {
                ys[yCount].a = cy0;
                ys[yCount].b = cy1;
                ++yCount;
            }
        }
        if (yCount == 0) { covered = NO; break; }
        RLPSortIntervals(ys, yCount);
        double curY = ry0;
        for (size_t yi = 0; yi < yCount; ++yi) {
            if (ys[yi].a > curY + eps) { covered = NO; break; }
            if (ys[yi].b > curY) curY = ys[yi].b;
            if (curY >= ry1 - eps) break;
        }
        if (!covered || curY < ry1 - eps) { covered = NO; break; }
    }

    if (heapAlloc) {
        free(xs);
        free(ys);
    }
    return covered;
}

static inline double RLPIntersectionAreaRect(NSRect a, NSRect b) {
    const double x0 = MAX((double)NSMinX(a), (double)NSMinX(b));
    const double x1 = MIN((double)NSMaxX(a), (double)NSMaxX(b));
    const double y0 = MAX((double)NSMinY(a), (double)NSMinY(b));
    const double y1 = MIN((double)NSMaxY(a), (double)NSMaxY(b));
    if (x1 <= x0 || y1 <= y0) return 0.0;
    return (x1 - x0) * (y1 - y0);
}

static inline double RLPClampedAreaForCandidate(NSRect frame, NSRect cand) {
    const double w = (double)frame.size.width > 0 ? MIN((double)frame.size.width, (double)cand.size.width) : 0.0;
    const double h = (double)frame.size.height > 0 ? MIN((double)frame.size.height, (double)cand.size.height) : 0.0;
    return w * h;
}

static inline double RLPRectDistanceSq(NSRect a, NSRect b) {
    const double dx = MAX(MAX((double)NSMinX(b) - (double)NSMaxX(a),
                              (double)NSMinX(a) - (double)NSMaxX(b)), 0.0);
    const double dy = MAX(MAX((double)NSMinY(b) - (double)NSMaxY(a),
                              (double)NSMinY(a) - (double)NSMaxY(b)), 0.0);
    return dx * dx + dy * dy;
}

static inline double RLPClampDisplacementSq(NSRect frame, NSRect cand) {
    NSRect r = frame;
    if (r.size.width > cand.size.width) r.size.width = cand.size.width;
    if (r.size.height > cand.size.height) r.size.height = cand.size.height;
    if (NSMinX(r) < NSMinX(cand)) r.origin.x = NSMinX(cand);
    if (NSMaxX(r) > NSMaxX(cand)) r.origin.x = NSMaxX(cand) - r.size.width;
    if (NSMinY(r) < NSMinY(cand)) r.origin.y = NSMinY(cand);
    if (NSMaxY(r) > NSMaxY(cand)) r.origin.y = NSMaxY(cand) - r.size.height;
    const double dx = (double)r.origin.x - (double)frame.origin.x;
    const double dy = (double)r.origin.y - (double)frame.origin.y;
    return dx * dx + dy * dy;
}

/// 多屏下「用哪块屏收敛」的唯一判据（纯函数，便于离线判据）。
///   0) 过滤掉 <= 1pt（或非有限）的退化可见区；若全部不可用返回 NSZeroRect（明确不收敛）。
///   1) 窗口**完全落在某一块合法屏**的可见区 → 用该屏；
///   2) 窗口跨屏时，仅构造**100% 落在合法屏并集内、绝不含死区/空隙**的无缝跨屏矩形
///      （水平无缝带取公共 Y 交集、垂直无缝带取公共 X 交集，并经 `RLPRectCoveredByScreens` 验真），
///      且仅当跨屏矩形严格覆盖更多窗口面积且不会把窗口压得比单屏更小时才采用；
///      若不同屏高错位太大或存在屏间空隙导致跨屏不可行，自动收敛到交集最大/最近的单屏。
///   3) 窗口一块屏都没碰到（拔屏死区 / 空隙 / 离屏坐标）→ 用**最近**的那块合法单屏。
static inline NSRect RLPWindowUsableScreenRect(NSRect windowFrame, const NSRect *visibles, size_t count) {
    if (!visibles || count == 0) return NSZeroRect;
    const double eps = 1e-6;

    enum { kStackCap = 32 };
    NSRect validStack[kStackCap];
    NSRect touchedStack[kStackCap];
    RLPInterval1D intsStack[kStackCap];
    NSRect *valid = validStack;
    NSRect *touched = touchedStack;
    RLPInterval1D *ints = intsStack;
    BOOL heapAlloc = NO;
    if (count > kStackCap) {
        valid = (NSRect *)malloc(sizeof(NSRect) * count);
        touched = (NSRect *)malloc(sizeof(NSRect) * count);
        ints = (RLPInterval1D *)malloc(sizeof(RLPInterval1D) * count);
        if (!valid || !touched || !ints) {
            free(valid);
            free(touched);
            free(ints);
            return NSZeroRect;
        }
        heapAlloc = YES;
    }

    size_t validCount = 0;
    for (size_t i = 0; i < count; ++i) {
        if (RLPScreenRectIsValid(visibles[i], 1.0)) valid[validCount++] = visibles[i];
    }
    if (validCount == 0) {
        if (heapAlloc) { free(valid); free(touched); free(ints); }
        return NSZeroRect;
    }

    if (!isfinite((double)windowFrame.origin.x) || !isfinite((double)windowFrame.origin.y) ||
        !isfinite((double)windowFrame.size.width) || !isfinite((double)windowFrame.size.height)) {
        const NSRect fallback = valid[0];
        if (heapAlloc) { free(valid); free(touched); free(ints); }
        return fallback;
    }

    for (size_t i = 0; i < validCount; ++i) {
        if (NSContainsRect(valid[i], windowFrame)) {
            const NSRect hit = valid[i];
            if (heapAlloc) { free(valid); free(touched); free(ints); }
            return hit;
        }
    }

    size_t tCount = 0;
    size_t bestSingleIdx = 0;
    double bestSingleInter = -1.0;
    double bestSingleClamped = -1.0;
    double bestSingleDisp2 = -1.0;
    for (size_t i = 0; i < validCount; ++i) {
        const double inter = RLPIntersectionAreaRect(windowFrame, valid[i]);
        if (inter > 0.0) {
            touched[tCount++] = valid[i];
            const double clampedA = RLPClampedAreaForCandidate(windowFrame, valid[i]);
            const double disp2 = RLPClampDisplacementSq(windowFrame, valid[i]);
            if (bestSingleInter < 0.0 ||
                inter > bestSingleInter + eps ||
                (fabs(inter - bestSingleInter) <= eps &&
                 (clampedA > bestSingleClamped + eps ||
                  (fabs(clampedA - bestSingleClamped) <= eps && disp2 < bestSingleDisp2 - eps)))) {
                bestSingleIdx = i;
                bestSingleInter = inter;
                bestSingleClamped = clampedA;
                bestSingleDisp2 = disp2;
            }
        }
    }

    if (tCount == 0) {
        // 一块屏都没碰到：取离窗口最近的合法单屏（矩形间距平方最小；并列取面积保全更大者，再取主屏）。
        size_t nearest = 0;
        double nearestDist = -1.0;
        double nearestClamped = -1.0;
        for (size_t i = 0; i < validCount; ++i) {
            const double dist = RLPRectDistanceSq(windowFrame, valid[i]);
            const double clampedA = RLPClampedAreaForCandidate(windowFrame, valid[i]);
            if (nearestDist < 0.0 ||
                dist < nearestDist - eps ||
                (fabs(dist - nearestDist) <= eps && clampedA > nearestClamped + eps)) {
                nearestDist = dist;
                nearestClamped = clampedA;
                nearest = i;
            }
        }
        const NSRect hit = valid[nearest];
        if (heapAlloc) { free(valid); free(touched); free(ints); }
        return hit;
    }

    NSRect best = valid[bestSingleIdx];
    double bestInter = bestSingleInter;
    double bestClamped = bestSingleClamped;
    double bestDisp2 = bestSingleDisp2;
    double bestArea = (double)best.size.width * (double)best.size.height;

    if (tCount >= 2) {
        #define RLP_TRY_MULTI_CANDIDATE(candRect) do { \
            const NSRect _c = (candRect); \
            if (RLPScreenRectIsValid(_c, 1.0) && RLPRectCoveredByScreens(_c, valid, validCount)) { \
                const double _ci = RLPIntersectionAreaRect(windowFrame, _c); \
                const double _cc = RLPClampedAreaForCandidate(windowFrame, _c); \
                if (_ci > bestSingleInter + eps && _cc >= bestSingleClamped - eps) { \
                    const double _cd = RLPClampDisplacementSq(windowFrame, _c); \
                    const double _ca = (double)_c.size.width * (double)_c.size.height; \
                    if (_ci > bestInter + eps || \
                        (fabs(_ci - bestInter) <= eps && \
                         (_cc > bestClamped + eps || \
                          (fabs(_cc - bestClamped) <= eps && \
                           (_cd < bestDisp2 - eps || \
                            (fabs(_cd - bestDisp2) <= eps && _ca < bestArea - eps)))))) { \
                        best = _c; bestInter = _ci; bestClamped = _cc; bestDisp2 = _cd; bestArea = _ca; \
                    } \
                } \
            } \
        } while (0)

        // 1) 若接触屏的整体包围盒本身无任何死区（如等高无缝双屏/三屏），直接作为候选。
        NSRect touchedUnion = touched[0];
        for (size_t i = 1; i < tCount; ++i) touchedUnion = NSUnionRect(touchedUnion, touched[i]);
        RLP_TRY_MULTI_CANDIDATE(touchedUnion);

        // 2) 水平跨屏无缝带：枚举所有 [yLo, yHi]，合并在 X 方向无缝相连且纵向上完整覆盖 [yLo, yHi] 的屏。
        for (size_t a = 0; a < tCount; ++a) {
            const double yLo = (double)NSMinY(touched[a]);
            for (size_t b = 0; b < tCount; ++b) {
                const double yHi = (double)NSMaxY(touched[b]);
                if (yHi - yLo <= 1.0) continue;
                size_t intCount = 0;
                for (size_t k = 0; k < tCount; ++k) {
                    if ((double)NSMinY(touched[k]) <= yLo + eps && (double)NSMaxY(touched[k]) >= yHi - eps) {
                        ints[intCount].a = (double)NSMinX(touched[k]);
                        ints[intCount].b = (double)NSMaxX(touched[k]);
                        ++intCount;
                    }
                }
                if (intCount < 2) continue;
                RLPSortIntervals(ints, intCount);
                double curA = ints[0].a;
                double curB = ints[0].b;
                for (size_t k = 1; k <= intCount; ++k) {
                    if (k < intCount && ints[k].a <= curB + eps) {
                        if (ints[k].b > curB) curB = ints[k].b;
                    } else {
                        RLP_TRY_MULTI_CANDIDATE(NSMakeRect((CGFloat)curA, (CGFloat)yLo,
                                                           (CGFloat)(curB - curA), (CGFloat)(yHi - yLo)));
                        if (k < intCount) { curA = ints[k].a; curB = ints[k].b; }
                    }
                }
            }
        }

        // 3) 垂直跨屏无缝带：枚举所有 [xLo, xHi]，合并在 Y 方向无缝相连且横向上完整覆盖 [xLo, xHi] 的屏。
        for (size_t a = 0; a < tCount; ++a) {
            const double xLo = (double)NSMinX(touched[a]);
            for (size_t b = 0; b < tCount; ++b) {
                const double xHi = (double)NSMaxX(touched[b]);
                if (xHi - xLo <= 1.0) continue;
                size_t intCount = 0;
                for (size_t k = 0; k < tCount; ++k) {
                    if ((double)NSMinX(touched[k]) <= xLo + eps && (double)NSMaxX(touched[k]) >= xHi - eps) {
                        ints[intCount].a = (double)NSMinY(touched[k]);
                        ints[intCount].b = (double)NSMaxY(touched[k]);
                        ++intCount;
                    }
                }
                if (intCount < 2) continue;
                RLPSortIntervals(ints, intCount);
                double curA = ints[0].a;
                double curB = ints[0].b;
                for (size_t k = 1; k <= intCount; ++k) {
                    if (k < intCount && ints[k].a <= curB + eps) {
                        if (ints[k].b > curB) curB = ints[k].b;
                    } else {
                        RLP_TRY_MULTI_CANDIDATE(NSMakeRect((CGFloat)xLo, (CGFloat)curA,
                                                           (CGFloat)(xHi - xLo), (CGFloat)(curB - curA)));
                        if (k < intCount) { curA = ints[k].a; curB = ints[k].b; }
                    }
                }
            }
        }
        #undef RLP_TRY_MULTI_CANDIDATE
    }

    if (heapAlloc) { free(valid); free(touched); free(ints); }
    return best;
}

/// 解析 NSWindow autosave 的 frame 字符串（"x y w h"，末尾可能带空格/屏幕描述）。
/// 纯 C 解析：不依赖 locale、不做本地化数字格式猜测；任何一段读不出来就判无效（不猜默认值）。
/// 另外两种"读得出但是坏值"也必须判无效，否则它们会穿过收敛函数变成更离谱的 frame：
///   - 非有限值（"inf"/"1e999" 能被 strtod 读出来，旧实现只挡了 NaN）；
///   - 非正的宽/高（"300 200 0 0" 会收敛成 0×0 的不可见窗口）。
static inline BOOL RLPParseSavedWindowFrame(const char *saved, NSRect *outRect) {
    if (!saved || !outRect) return NO;
    const char *p = saved;
    double v[4] = { 0, 0, 0, 0 };
    for (int i = 0; i < 4; ++i) {
        while (*p == ' ' || *p == '\t') ++p;
        if (!*p) return NO;
        char *end = NULL;
        v[i] = strtod(p, &end);
        if (end == p || !isfinite(v[i])) return NO;   // 读不出 / NaN / ±inf 都判无效（autosave 可能被写坏）
        p = end;
    }
    if (!(v[2] > 0.0) || !(v[3] > 0.0)) return NO;     // 窗口不可能没有宽高：0×0 / 负尺寸 = 坏记录
    *outRect = NSMakeRect((CGFloat)v[0], (CGFloat)v[1], (CGFloat)v[2], (CGFloat)v[3]);
    return YES;
}

/// 启动时的窗口 frame 决策（纯函数）：
/// 有合法保存值 → 用它并向可见区收敛、**不居中**（居中会把副屏/任意位置的 origin 覆盖成主屏中心）；
/// 没有保存值（首次启动或记录损坏）→ 默认尺寸 + 居中，**默认尺寸同样先按当前屏收敛**。
/// 后者是"小屏撑破/漏夹"的补丁：旧实现把默认尺寸原样交回调用方，纯函数判据里看不出
/// 1180×760 在 1024×768 屏上已经超出可见区（再靠调用方补一次收敛并不是同一个判据）。
/// converged=NO 表示没有可用屏幕（count==0 或全为 <=1pt 退化屏），此时 frame 保持安全正尺寸而不被压扁。
typedef struct {
    NSRect frame;
    BOOL center;
    BOOL converged;
} RLPWindowStartupFrame;

static inline RLPWindowStartupFrame RLPWindowStartupFrameForSavedState(const char *savedFrame,
                                                                      NSRect defaultFrame,
                                                                      const NSRect *visibles,
                                                                      size_t count,
                                                                      NSSize minSize) {
    RLPWindowStartupFrame out;
    out.frame = RLPClampWindowFrameToVisibleChecked(defaultFrame, NSZeroRect, minSize).frame;
    out.center = YES;
    out.converged = NO;
    NSRect saved = NSZeroRect;
    if (!RLPParseSavedWindowFrame(savedFrame, &saved)) {
        if (visibles && count > 0) {
            const NSRect usable = RLPWindowUsableScreenRect(defaultFrame, visibles, count);
            if (!NSIsEmptyRect(usable)) {
                const RLPWindowClampResult r = RLPClampWindowFrameToVisibleChecked(defaultFrame, usable, minSize);
                out.frame = r.frame;
                out.converged = r.converged;
            }
        }
        return out;
    }
    out.center = NO;
    if (visibles && count > 0) {
        const NSRect usable = RLPWindowUsableScreenRect(saved, visibles, count);
        const RLPWindowClampResult r = RLPClampWindowFrameToVisibleChecked(saved, usable, minSize);
        out.frame = r.frame;
        out.converged = r.converged;
    } else {
        out.frame = RLPClampWindowFrameToVisibleChecked(saved, NSZeroRect, minSize).frame;
    }
    return out;
}

/// 当前是否有可恢复的记忆值（判据与 UI 可用；对应 web `volumeRestore !== null`）。
BOOL RLPVolumeMuteHasRestore(void);
/// 清空记忆值（上游在「重置/丢弃」路径上会置 null）。
void RLPVolumeMuteReset(void);
/// 静音记忆快照（仅主线程使用）。
typedef struct {
    double restoreDb;
    uint64_t revision;
} RLPVolumeMuteSnapshot;
/// 捕获当前静音恢复记忆（restoreDb 允许为 NAN）与单调 revision（仅主线程使用）。
RLPVolumeMuteSnapshot RLPVolumeMuteCapture(void);
/// 当前全局静音状态 revision（仅主线程使用）。
uint64_t RLPVolumeMuteRevision(void);
/// 条件回滚静音记忆：仅当当前 revision == expectedRevision 且快照不来自未来时，
/// 恢复 snapshot.restoreDb 并递增 revision 返回 YES；否则不修改并返回 NO。
/// 仅恢复内存中的静音记忆状态，不写音频设备、不发网络请求（仅主线程使用）。
BOOL RLPVolumeMuteRollback(RLPVolumeMuteSnapshot snapshot, uint64_t expectedRevision);
/// 播放/暂停的**唯一决策**（与 web playOrPause 同语义）：
///   播放中（playing && !paused）→ /api/pause?on=1
///   暂停中（paused）             → /api/pause?on=0
///   已停止但知道当前曲目         → /api/play（只发 pause 不会有任何反应，web 同口径重播）
///   以上都不是                   → 不发请求
/// 底栏、播放页、菜单/媒体键三入口都必须走这里，避免各自维护一份会漂移的判定。
void RLPPlaybackToggle(BOOL playing, BOOL paused, NSString * _Nullable currentPath);
/// 显式暂停（系统 pauseCommand 的语义）：永远发 /api/pause?on=1，不看 UI 状态快照。
/// 为什么不能用复选框判定：状态轮询 0.5s 一拍，后台被 App Nap 降频/某次请求丢失时快照可能是旧的，
/// 「用户明确要求暂停」不能因为旧快照而静默不发请求。
void RLPPlaybackPauseExplicit(void);
/// 显式继续/重播（系统 playCommand 的语义）：已在播→什么都不做；暂停中→on=0；已停止且有曲目→重播。
void RLPPlaybackResumeOrReplay(BOOL playing, BOOL paused, NSString * _Nullable currentPath);

/// 整列顺序播放（对齐 web playWholeListFrom）：先用 /api/queue/set 以给定路径列表建队列，
/// 成功后从 start 起播。files 为空不做任何事；单曲循环模式（2）先切回列表循环（1），
/// 否则播完第一首会一直重复，与"顺序播放整列"的心智相悖（web ensureSequentialMode 同口径）。
/// 供「我的最爱」双击等"从某行起播整个列表"的场景使用。
void RLPPlayWholeListFrom(NSArray<NSString *> *files, NSInteger start);

/// web ensureSequentialMode 的共享守卫：起播整列之前先读 /api/playmode，
/// 是单曲循环（mode==2）就切回列表循环（mode=1）；其余模式原样不动。
/// then 在主线程恰好回调一次（无需回调时传 nil）。最爱页/队列页/歌单页共用同一实现，
/// 避免各页面各写一套导致某页漏掉（P3：歌单页在单曲循环下整列播成一首）。
void RLPEnsureSequentialMode(void (^ _Nullable then)(void));
/// 带意图守卫的 ensureSequentialMode：每次异步回调前先问 shouldContinue()，
/// 为 NO 时立刻中止后续 /api/playmode?mode=1 与 then()，防止旧意图在被取代后抢跑。
void RLPEnsureSequentialModeWhile(BOOL (^ _Nullable shouldContinue)(void), void (^ _Nullable then)(void));

/// 「古典作品」判定与检索参数（web ui_script.h npIsClassical / npGuessComposer / npWorkTarget 的逐条移植）。
/// 为什么放在公共层：播放页第 4 张卡、作品抽屉、整页入口、右键菜单四处都要用同一套判定，
/// 各写一份必然漂移（web 也只有一个真源）。
BOOL RLPNPIsClassical(NSDictionary * _Nullable meta);
NSString *RLPNPGuessComposer(NSDictionary * _Nullable meta);
/// 返回 @{@"title": 去译名后的作品名, @"composer": 作曲家}；两者都可为空串。
NSDictionary<NSString *, NSString *> *RLPNPWorkTarget(NSDictionary * _Nullable meta);

/// v3.3.11 `parseTransportM3u` 的 macOS/POSIX 适配（上游是 Windows 反斜杠路径）。
/// 返回 @{@"items": NSArray<NSString*>, @"needsFolder": NSNumber(BOOL)}；
/// 非法歌单（HLS / 孤立 CUE / 空 / 控制字符）返回 nil。folder 传 nil 表示未知。
/// 纯函数：不读文件、不弹面板，供队列页与判据共用同一份解析。
NSDictionary<NSString *, id> * _Nullable RLPParseM3U(NSString *text, NSString * _Nullable folder);

/// 诊断遥测（/api/ui/events）：异步批量上报关键原生动作/路由/接口错误。
/// 严格脱敏，绝不写入正文、文件路径、标题、token 或密码；带去重冷却与限流，失败静默不阻塞 UI。
void RLPDiagEvent(NSString * _Nullable kind,
                  NSString * _Nullable name,
                  NSString * _Nullable route,
                  NSString * _Nullable path,
                  NSInteger status,
                  double dur,
                  NSString * _Nullable code);
/// 判据专用：同步清空遥测队列与限流计数，隔离同进程先后测试之间的状态。
void RLPDiagTelemetryResetForAudit(void);

/// 为 NSOpenPanel 配置文件扩展名过滤（macOS 11+ 走 UTType allowedContentTypes，避免 allowedFileTypes 弃用告警）。
void RLPConfigureOpenPanelFileTypes(NSOpenPanel *panel, NSArray<NSString *> *extensions);

NS_ASSUME_NONNULL_END
