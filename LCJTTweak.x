// LCJTTweak.x - 龙城军团(com.lcjt.ios) 助手 v1
// 引擎实证: Cocos2d-x 3.x(C++) + tolua + LuaJIT (__text 内含 \x1bLJ\x02 版本标记)
// 主二进制已 strip: 46674 函数 / 导出符号仅 3 个
// 资源 dxd/pwvm/zue 全加密(前18字节固定头+变密钥流) -> 游戏 Lua 逻辑由服务器下发
// 本版: [1]精确时间变速(主二进制调用者过滤) [2]LuaJIT堆内存探针 [3]悬浮球面板
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <sys/time.h>
#import <time.h>
#import <stdarg.h>
#include "fishhook.h"
#import <objc/message.h>
#include <signal.h>
#include <unistd.h>
#include <execinfo.h>
static const uint64_t kTextLo = 0x100005b30ULL;
static const uint64_t kTextHi = 0x100bbff08ULL;
static BOOL g_enableTs = NO;
static double g_tsMul = 2.0;
static uint64_t g_tsApplied = 0;
static uintptr_t g_gameBase = 0;
static id g_winDelegate = nil;
static id g_helper = nil;
static NSString *g_note = @"待机";
static NSString *LCJTDocPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}
static void LCJTLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s];
    NSString *p = [LCJTDocPath() stringByAppendingPathComponent:@"lcjt.log"];
    FILE *f = fopen(p.UTF8String, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
    NSLog(@"[LCJT] %@", s);
}
static inline BOOL LCJTIsGameCode(void *ret) {
    if (!g_gameBase) return NO;
    uintptr_t r = (uintptr_t)ret;
    return (r >= g_gameBase + (kTextLo - 0x100000000ULL) &&
            r <  g_gameBase + (kTextHi - 0x100000000ULL));
}
static void LCJTFindGameImage(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && (strstr(nm, "yougu3neigou") || strstr(nm, "longchengju"))) {
            g_gameBase = (uintptr_t)_dyld_get_image_header(i);
            LCJTLog(@"主二进制 %s base=%p", nm, (void *)g_gameBase);
            return;
        }
    }
    g_gameBase = (uintptr_t)_dyld_get_image_header(0);
    LCJTLog(@"兜底 base=%p", (void *)g_gameBase);
}
typedef int (*ft_gtod)(struct timeval *, void *);
typedef time_t (*ft_time)(time_t *);
typedef int (*ft_cgt)(clockid_t, struct timespec *);
typedef double (*ft_media)(void);
typedef uint64_t (*ft_mach)(void);
static ft_gtod o_gtod = NULL;
static ft_time o_time = NULL;
static ft_cgt o_cgt = NULL;
static ft_media o_media = NULL;
static ft_mach o_mach = NULL;
static double g_t0_us = 0, g_t0_media = 0, g_t0_mach = 0;
// ---- clock / std::chrono (日志实证: 游戏用 clock + steady_clock 取时间) ----
typedef clock_t (*ft_clock)(void);
typedef long long (*ft_steady)(void);
static ft_clock  o_clock = NULL;
static ft_steady o_steady = NULL;
static double g_t0_clock = 0, g_t0_steady = 0;

static void LCJTCaptureT0(void) {
    struct timeval tv = {0};
    if (o_gtod) o_gtod(&tv, NULL);
    g_t0_us = (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
    if (o_media)  g_t0_media  = o_media();
    if (o_mach)   g_t0_mach   = (double)o_mach();
    if (o_clock)  g_t0_clock  = (double)o_clock();
    if (o_steady) g_t0_steady = (double)o_steady();
    g_tsApplied = 0;
    LCJTLog(@"变速开启 x%.1f t0=%f", g_tsMul, g_t0_us);
}
static int m_gtod(struct timeval *tv, void *tz) {
    int r = o_gtod(tv, tz);
    if (g_enableTs && tv && LCJTIsGameCode(__builtin_return_address(0))) {
        double t  = (double)tv->tv_sec + (double)tv->tv_usec / 1e6;
        double vt = t * g_tsMul + g_t0_us * (1.0 - g_tsMul);
        if (vt > 0) {
            tv->tv_sec  = (time_t)vt;
            tv->tv_usec = (suseconds_t)((vt - (double)tv->tv_sec) * 1e6);
            g_tsApplied++;
        }
    }
    return r;
}
static time_t m_time(time_t *t) {
    time_t real = o_time(NULL);
    if (g_enableTs && LCJTIsGameCode(__builtin_return_address(0))) {
        double vt = (double)real * g_tsMul + g_t0_us * (1.0 - g_tsMul);
        time_t v = (time_t)vt; if (t) *t = v; g_tsApplied++; return v;
    }
    if (t) *t = real;
    return real;
}
static int m_cgt(clockid_t cid, struct timespec *ts) {
    int r = o_cgt(cid, ts);
    if (g_enableTs && ts && LCJTIsGameCode(__builtin_return_address(0))) {
        if (cid == CLOCK_MONOTONIC || cid == CLOCK_MONOTONIC_RAW || cid == CLOCK_UPTIME_RAW) {
            double t  = (double)ts->tv_sec + (double)ts->tv_nsec / 1e9;
            double vt = t * g_tsMul + g_t0_media * (1.0 - g_tsMul);
            if (vt > 0) {
                ts->tv_sec  = (time_t)vt;
                ts->tv_nsec = (long)((vt - (double)ts->tv_sec) * 1e9);
                g_tsApplied++;
            }
        }
    }
    return r;
}
static double m_media(void) {
    double r = o_media();
    if (g_enableTs && LCJTIsGameCode(__builtin_return_address(0))) {
        r = r * g_tsMul + g_t0_media * (1.0 - g_tsMul);
        g_tsApplied++;
    }
    return r;
}
static uint64_t m_mach(void) {
    uint64_t r = o_mach();
    if (g_enableTs && LCJTIsGameCode(__builtin_return_address(0))) {
        double v = (double)r * g_tsMul + g_t0_mach * (1.0 - g_tsMul);
        r = (uint64_t)(v > 0 ? v : 0);
        g_tsApplied++;
    }
    return r;
}

static clock_t m_clock(void) {
    clock_t r = o_clock();
    if (g_enableTs && LCJTIsGameCode(__builtin_return_address(0))) {
        double v = (double)r * g_tsMul + g_t0_clock * (1.0 - g_tsMul);
        r = (clock_t)(v > 0 ? v : 0);
        g_tsApplied++;
    }
    return r;
}
// std::chrono::steady_clock::now() (arm64: x0 返回 int64 纳秒)
static long long m_steady(void) {
    long long r = o_steady();
    if (g_enableTs && LCJTIsGameCode(__builtin_return_address(0))) {
        double v = (double)r * g_tsMul + g_t0_steady * (1.0 - g_tsMul);
        r = (long long)(v > 0 ? v : 0);
        g_tsApplied++;
    }
    return r;
}

static void LCJTScanBuf(uint8_t *buf, size_t got, FILE *out,
                        uint64_t *pStr, uint64_t *pLJ, NSMutableArray *samples) {
    size_t i = 0;
    while (i + 8 < got) {
        uint8_t c = buf[i];
        if (c >= 0x20 && c < 0x7f) {
            size_t j = i;
            while (j < got && buf[j] >= 0x20 && buf[j] < 0x7f && (j - i) < 64) j++;
            if (j - i >= 4 && j < got && buf[j] == 0 && i >= 4) {
                uint32_t l4; memcpy(&l4, buf + i - 4, 4);
                if (l4 == (uint32_t)(j - i)) {
                    (*pStr)++;
                    if (out) { fwrite(buf + i, 1, j - i, out); fputc('\n', out); }
                    if (samples && samples.count < 30)
                        [samples addObject:[NSString stringWithFormat:@"%s", (char *)(buf + i)]];
                }
            }
            i = j;
        } else if (c == 0x1b && i + 3 < got && buf[i+1] == 'L' && buf[i+2] == 'J') {
            (*pLJ)++; i += 4;
        } else i++;
    }
}
static void LCJTDumpAllASCII(FILE *out);
static void LCJTProbeLua(void) {
    LCJTLog(@"=== Lua 探针开始 ===");
    g_note = @"探针运行中";
    NSString *sp = [LCJTDocPath() stringByAppendingPathComponent:@"lcjt_lua_strings.txt"];
    FILE *out = fopen(sp.UTF8String, "w");
    if (out) fputs("# LuaJIT GCstr 明文串 (校验 data-4 == len)\n", out);
    uint64_t nStr = 0, nLJ = 0, nBytes = 0;
    NSMutableArray *samples = [NSMutableArray array];
    const size_t kChunk = 1 << 22;
    uint8_t *buf = malloc(kChunk + 8);
    if (!buf) { if (out) fclose(out); return; }
    vm_address_t addr = 0; vm_size_t vsz = 0; uint32_t depth = 0;
    while (nBytes < (uint64_t)384 * 1024 * 1024) {
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        vm_size_t isz = sizeof(info);
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &addr, &vsz, &depth,
                                                (vm_region_info_t)&info, &cnt);
        if (kr != KERN_SUCCESS || vsz == 0) break;
        if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE)) {
            size_t off = 0;
            while (off < vsz && nBytes < (uint64_t)384 * 1024 * 1024) {
                size_t want = vsz - off; if (want > kChunk) want = kChunk;
                vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), addr + off, (vm_size_t)want,
                                      (vm_address_t)buf, &got) == KERN_SUCCESS && got > 8) {
                    LCJTScanBuf(buf, got, out, &nStr, &nLJ, samples);
                    nBytes += got; off += got;
                } else off += want;
            }
        }
        addr += vsz;
        if (!addr) break;
    }
    free(buf);
    if (out) fclose(out);
    LCJTLog(@"探针完成 扫描%lluMB 串=%llu 块=%llu -> %@", nBytes/1024/1024, nStr, nLJ, sp);
    for (NSString *s in samples) LCJTLog(@"  样本 %@", s);
    g_note = [NSString stringWithFormat:@"探针完成 串%llu 块%llu", nStr, nLJ];
    // 兜底: 全量可读串
    NSString *ap = [LCJTDocPath() stringByAppendingPathComponent:@"lcjt_ascii_all.txt"];
    FILE *a = fopen(ap.UTF8String, "w");
    if (a) { LCJTDumpAllASCII(a); fclose(a); }
    LCJTLog(@"兜底 ASCII dump -> %@", ap);
}
// 兜底: 统计可读串密度(不依赖 LuaJIT 内部布局), 便于确认是否已加载脚本
static void LCJTDumpAllASCII(FILE *out) {
    const size_t kChunk = 1 << 22;
    uint8_t *buf = malloc(kChunk + 8);
    if (!buf) return;
    vm_address_t addr = 0; vm_size_t vsz = 0; uint32_t depth = 0;
    uint64_t total = 0;
    while (total < (uint64_t)384 * 1024 * 1024) {
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        vm_size_t isz = sizeof(info);
        if (vm_region_recurse_64(mach_task_self(), &addr, &vsz, &depth,
                                 (vm_region_info_t)&info, &cnt) != KERN_SUCCESS || vsz == 0) break;
        if ((info.protection & 3) == 3) {
            size_t off = 0;
            while (off < vsz && total < (uint64_t)384 * 1024 * 1024) {
                size_t want = vsz - off; if (want > kChunk) want = kChunk;
                vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), addr + off, (vm_size_t)want,
                                      (vm_address_t)buf, &got) == KERN_SUCCESS && got > 8) {
                    size_t i = 0;
                    while (i + 6 < got) {
                        if (buf[i] >= 0x20 && buf[i] < 0x7f) {
                            size_t j = i;
                            while (j < got && buf[j] >= 0x20 && buf[j] < 0x7f && (j - i) < 48) j++;
                            if (j - i >= 6 && (j == got || buf[j] == 0)) {
                                if (out) { fwrite(buf + i, 1, j - i, out); fputc('\n', out); }
                            }
                            i = j;
                        } else i++;
                    }
                    total += got; off += got;
                } else off += want;
            }
        }
        addr += vsz;
        if (!addr) break;
    }
    free(buf);
}

static void LCJTProbeAsync(void) {
    static BOOL running = NO;
    if (running) return; running = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool { LCJTProbeLua(); }
        running = NO;
    });
}
static UIView *g_overlay = nil;
static UIWindow *g_hostWin = nil;
static UIView *g_panel = nil;
static UILabel *g_status = nil;
static BOOL g_panelOpen = NO;
static UIColor *CGreen(void) { return [UIColor colorWithRed:0.18 green:0.78 blue:0.35 alpha:1]; }
static UIColor *CGray(void)  { return [UIColor colorWithWhite:0.30 alpha:1]; }
static void LCJTDumpHotUpdateAsync(void);
static void LCJTAnalyzeCombatAsync(void);

@interface LCJTUI : NSObject
+ (void)refresh;
+ (void)onToggleTs:(id)b;
+ (void)onToggleProbe:(id)b;
+ (void)onCycleMul:(id)b;
+ (void)onClose:(id)b;
+ (void)placePanel;
+ (void)onScanFiles:(id)b;
+ (void)onAnalyze:(id)b;
@end
@interface LCJTHelper : NSObject
- (void)onBallTap:(id)g;
- (void)onBallPan:(id)g;
@end
@interface LCJTWinDelegate : NSObject
- (void)onBallTap:(id)s;
- (void)onBallPan:(id)s;
- (void)onToggleTs:(id)s;
- (void)onToggleProbe:(id)s;
- (void)onCycleMul:(id)s;
- (void)onClose:(id)s;
@end
@implementation LCJTUI
+ (void)refresh {
    g_status.text = [NSString stringWithFormat:@"变速: %@  x%.1f  命中%llu\n探针: %@\n%@",
                     g_enableTs ? @"开" : @"关", g_tsMul, g_tsApplied, g_note,
                     @"秒杀/无敌/移速/攻速 待探针接入"];
    [g_status sizeToFit];
}
+ (void)onToggleTs:(id)b {
    LCJTLog(@"面板: 点变速");
    g_enableTs = !g_enableTs;
    if (g_enableTs) LCJTCaptureT0();
    UIButton *btn = (UIButton *)b;
    [btn setTitle:[NSString stringWithFormat:@"%@ 变速  x%.0f", g_enableTs ? @"v" : @"o", g_tsMul]
         forState:UIControlStateNormal];
    btn.backgroundColor = g_enableTs ? CGreen() : CGray();
    [self refresh];
}
+ (void)onToggleProbe:(id)b {
    LCJTLog(@"面板: 点探针");
    LCJTProbeAsync();
    UIButton *btn = (UIButton *)b;
    [btn setTitle:@"v Lua探针" forState:UIControlStateNormal];
    btn.backgroundColor = CGreen();
    g_note = @"探针运行中";
    [self refresh];
}
+ (void)onCycleMul:(id)b {
    LCJTLog(@"面板: 点倍率");
    static const double muls[] = {2, 3, 5, 8, 1};
    static int idx = 0;
    idx = (idx + 1) % 5; g_tsMul = muls[idx];
    if (g_enableTs) LCJTCaptureT0();
    [(UIButton *)b setTitle:[NSString stringWithFormat:@"变速倍率: x%.0f", g_tsMul]
                   forState:UIControlStateNormal];
    [self refresh];
}
+ (void)onClose:(id)b { LCJTLog(@"面板: 点关闭"); g_panelOpen = NO; g_panel.hidden = YES; }
+ (void)onAnalyze:(id)b {
    LCJTLog(@"面板: 点源码摘要");
    g_note = @"分析战斗源码…";
    [self refresh];
    LCJTAnalyzeCombatAsync();
}
+ (void)onScanFiles:(id)b {
    LCJTLog(@"面板: 点扫描热更");
    g_note = @"扫描热更文件…";
    [self refresh];
    LCJTDumpHotUpdateAsync();
}
+ (void)placePanel {
    if (!g_panel || !g_overlay) return;
    CGRect ob = g_overlay.bounds;
    CGPoint c = g_panel.center;
    // 面板默认显示在球右侧, 越界则翻到左侧
    CGPoint bc = CGPointZero;
    for (UIView *v in g_overlay.subviews) {
        if ([v isKindOfClass:NSClassFromString(@"LCJTBallView")]) { bc = v.center; break; }
    }
    if (bc.x == 0 && bc.y == 0) bc = CGPointMake(48, 148);
    CGFloat pw = g_panel.bounds.size.width, ph = g_panel.bounds.size.height;
    CGFloat x = bc.x + 40 + pw / 2;
    if (x + pw / 2 > ob.size.width - 8) x = bc.x - 40 - pw / 2;
    if (x - pw / 2 < 8) x = pw / 2 + 8;
    CGFloat y = bc.y + ph / 2;
    if (y + ph / 2 > ob.size.height - 8) y = ob.size.height - ph / 2 - 8;
    if (y - ph / 2 < 8) y = ph / 2 + 8;
    g_panel.center = CGPointMake(x, y);
}
@end
@implementation LCJTHelper
- (void)onBallTap:(id)g {
    g_panelOpen = !g_panelOpen;
    g_panel.hidden = !g_panelOpen;
    [LCJTUI refresh];
}
- (void)onBallPan:(id)g {
    UIView *ball = ((UIPanGestureRecognizer *)g).view;
    CGPoint p = [(UIPanGestureRecognizer *)g translationInView:ball.superview];
    ball.center = CGPointMake(ball.center.x + p.x, ball.center.y + p.y);
    [(UIPanGestureRecognizer *)g setTranslation:CGPointZero inView:ball.superview];
    if (g_panelOpen) g_panel.center = CGPointMake(ball.center.x + 150, ball.center.y + 100);
}
@end
@implementation LCJTWinDelegate
- (void)onBallTap:(id)s { [(LCJTHelper *)g_helper onBallTap:s]; }
- (void)onBallPan:(id)s { [(LCJTHelper *)g_helper onBallPan:s]; }
- (void)onToggleTs:(id)s { [LCJTUI onToggleTs:s]; }
- (void)onToggleProbe:(id)s { [LCJTUI onToggleProbe:s]; }
- (void)onCycleMul:(id)s { [LCJTUI onCycleMul:s]; }
- (void)onClose:(id)s { [LCJTUI onClose:s]; }
- (void)onScanFiles:(id)s { [LCJTUI onScanFiles:s]; }
- (void)onAnalyze:(id)s { [LCJTUI onAnalyze:s]; }
@end

// ★ target 绝不能为 nil: UIControl 事件在 target=nil 时被静默丢弃(不报错不崩溃)
static id LCJTDelegate(void) {
    if (!g_winDelegate) g_winDelegate = [[LCJTWinDelegate alloc] init];
    if (!g_helper)      g_helper      = [[LCJTHelper alloc] init];
    return g_winDelegate;
}
// ==================== 触摸透传容器 ====================
// 关键: 全屏 UIWindow 若用普通 UIView, 会吞掉所有触摸 → 游戏无法操作。
// 解决: 重写 hitTest, 只命中子视图(悬浮球/面板), 命中自身则返回 nil
//       → 空白区域的触摸透传到下层(游戏)窗口
// ★ 关键: 透传必须实现在【UIWindow 自身】, 只加在子视图上无效!
//   原因: UIWindow.hitTest 若返回自身, 整窗会吞掉所有触摸(游戏也点不了)。
@interface LCJTPassThroughWindow : UIWindow
@end
@implementation LCJTPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;                        // 空白区 → 透传下层窗口
    if (hit == self.rootViewController.view) return nil;
    return hit;                                          // 只命中真实控件
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *v in self.subviews) {
        if (!v.hidden && v.alpha > 0.01 &&
            [v pointInside:[v convertPoint:point fromView:self] withEvent:event]) return YES;
    }
    return NO;
}
@end

@interface LCJTPassThroughView : UIView
@end
@implementation LCJTPassThroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;      // 自身不接收 → 透传
    return hit;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *v in self.subviews) {
        if (!v.hidden && [v pointInside:[v convertPoint:point fromView:self] withEvent:event])
            return YES;
    }
    return NO;                         // 空白区不拦截
}
@end

static UILabel *MkLabel(CGRect r, NSString *t, CGFloat sz, UIColor *c) {
    UILabel *l = [[UILabel alloc] initWithFrame:r];
    l.text = t; l.font = [UIFont systemFontOfSize:sz weight:UIFontWeightMedium];
    l.textColor = c; l.backgroundColor = UIColor.clearColor;
    return l;
}
static UIButton *MkBtn(NSString *t, SEL sel, BOOL on, CGFloat y, CGFloat W) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(12, y, W - 24, 34);
    b.layer.cornerRadius = 8; b.layer.masksToBounds = YES;
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = on ? CGreen() : CGray();
    [b addTarget:LCJTDelegate() action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}


// ==================== 热更文件扫描 (明文 Lua 源码在此) ====================
// 依据探针导出: gm_cache/ / gm_assets / HotUpdateGMAssets / GetGMCachePath
static void LCJTDumpHotUpdate(void) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableString *idx = [NSMutableString stringWithString:@"# 路径\t字节数\n"];
        NSString *outDir = [LCJTDocPath() stringByAppendingPathComponent:@"lcjt_lua"];
        [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:home];
        int ndir = 0, found = 0, copied = 0;
        while (stack.count > 0 && ndir < 30000) {
            NSString *dir = stack.lastObject; [stack removeLastObject]; ndir++;
            if ([dir containsString:@"/lcjt_lua"]) continue;
            NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
            for (NSString *it in items) {
                NSString *full = [dir stringByAppendingPathComponent:it];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
                if (isDir) { [stack addObject:full]; continue; }
                NSString *ext = full.pathExtension.lowercaseString;
                if ([ext isEqualToString:@"lua"] || [ext isEqualToString:@"luac"] ||
                    [ext isEqualToString:@"manifest"]) {
                    NSDictionary *at = [fm attributesOfItemAtPath:full error:nil];
                    unsigned long long sz = [[at objectForKey:NSFileSize] unsignedLongLongValue];
                    found++;
                    [idx appendFormat:@"%@\t%llu\n", full, sz];
                    if (sz > 0 && sz < 4000000 && copied < 4000) {
                        NSData *d = [NSData dataWithContentsOfFile:full];
                        if (d) {
                            NSString *dest = [outDir stringByAppendingPathComponent:
                                              [NSString stringWithFormat:@"%04d_%@", found, it]];
                            if ([d writeToFile:dest atomically:YES]) copied++;
                        }
                    }
                }
            }
        }
        NSString *ip = [LCJTDocPath() stringByAppendingPathComponent:@"lcjt_files.txt"];
        [idx writeToFile:ip atomically:YES encoding:NSUTF8StringEncoding error:nil];
        g_note = [NSString stringWithFormat:@"热更扫描: 命中%d 复制%d", found, copied];
        LCJTLog(@"热更扫描完成: 遍历%d目录 命中%d 复制%d -> %@ (目录 %@)", ndir, found, copied, ip, outDir);
    }
}
static void LCJTDumpHotUpdateAsync(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ LCJTDumpHotUpdate(); });
}


// ==================== 战斗源码摘要器 ====================
// 读取 Documents/files/ 下的 .lua 明文, 提取与
// 移速/攻速/血量/伤害/死亡/无敌 相关的代码行 → 单文件回传(体积小)
static BOOL LCJTLineHit(NSString *ln) {
    static NSArray *kws = nil;
    if (!kws) kws = @[@"speed", @"Speed", @"move", @"Move", @"walkSpeed", @"runSpeed",
                      @"attack", @"Attack", @"atkSpeed", @"interval", @"Interval",
                      @"cd ", @"CD ", @"coolDown", @"cool", @"fps", @"frameRate",
                      @"hp", @"Hp", @"HP", @"blood", @"Blood", @"health", @"Health",
                      @"hurt", @"Hurt", @"damage", @"Damage", @"harm",
                      @"die", @"Die", @"dead", @"Dead", @"Death", @"death",
                      @"invinc", @"Invinc", @"immune", @"Immune", @"god", @"God",
                      @"无敌", @"免伤", @"免疫", @"速度", @"攻速", @"血量", @"伤害", @"死亡", @"间隔"];
    for (NSString *k in kws) if ([ln containsString:k]) return YES;
    return NO;
}

static void LCJTAnalyzeCombat(void) {
    @autoreleasepool {
        NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/files"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableString *rep = [NSMutableString string];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        int nfile = 0, nline = 0;
        while (stack.count && nfile < 4000) {
            NSString *dir = stack.lastObject; [stack removeLastObject];
            for (NSString *it in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                NSString *full = [dir stringByAppendingPathComponent:it];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
                if (isDir) { [stack addObject:full]; continue; }
                if (![full.pathExtension.lowercaseString isEqualToString:@"lua"]) continue;
                NSString *b = full.lastPathComponent.lowercaseString;
                // 优先关键文件
                BOOL key = ([b containsString:@"gameactor"] || [b containsString:@"moveable"] ||
                            [b containsString:@"attack"] || [b containsString:@"skill"] ||
                            [b containsString:@"buff"] || [b containsString:@"damage"] ||
                            [b containsString:@"die"] || [b containsString:@"dead"] ||
                            [b containsString:@"constant"] || [b containsString:@"setup"] ||
                            [b containsString:@"magicinfo"] || [b containsString:@"main.lua"] ||
                            [b containsString:@"state"] || [b containsString:@"hud"]);
                if (!key) continue;
                NSString *txt = [NSString stringWithContentsOfFile:full encoding:NSUTF8StringEncoding error:nil];
                if (!txt) continue;
                nfile++;
                [rep appendFormat:@"\n\n===== %@ (%lu B) =====\n", full, (unsigned long)txt.length];
                NSArray *lines = [txt componentsSeparatedByString:@"\n"];
                for (NSUInteger i = 0; i < lines.count; i++) {
                    NSString *ln = (NSString *)[lines objectAtIndex:i];
                    if ([ln containsString:@"速度"] || [ln containsString:@"攻速"] ||
                        [ln containsString:@"血量"] || [ln containsString:@"伤害"] ||
                        [ln containsString:@"无敌"] || [ln containsString:@"免伤"] ||
                        [ln containsString:@"间隔"] || [ln containsString:@"死亡"] ||
                        LCJTLineHit(ln)) {
                        [rep appendFormat:@"%5lu| %@\n", (unsigned long)(i+1), ln];
                        nline++;
                    }
                }
            }
        }
        // 额外: 完整导出几个体积小但最关键的文件
        NSArray *must = @[@"actor/gameActor.lua", @"actor/gameActorMoveable.lua",
                          @"actor/gameActorStatePlayerAttack.lua", @"actor/gameActorStateMoveBase.lua",
                          @"actor/gameActorStateMonsterDie.lua", @"skill/skillManager.lua",
                          @"config/ConstantConfig.lua", @"actor/gameActorStatePlayerDie.lua"];
        for (NSString *rel in must) {
            NSString *f1 = [root stringByAppendingPathComponent:
                            [@"mod_fgcq/stab/scripts" stringByAppendingPathComponent:rel]];
            NSString *f2 = [root stringByAppendingPathComponent:
                            [@"mod_fgcq/cqwl_218435/scripts" stringByAppendingPathComponent:rel]];
            for (NSString *f in @[f1, f2]) {
                NSString *t = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil];
                if (!t) continue;
                [rep appendFormat:@"\n\n########## FULL %@ (%lu B) ##########\n%@\n", f, (unsigned long)t.length, t];
            }
        }
        NSString *out = [LCJTDocPath() stringByAppendingPathComponent:@"lcjt_战斗源码摘要.txt"];
        [rep writeToFile:out atomically:YES encoding:NSUTF8StringEncoding error:nil];
        g_note = [NSString stringWithFormat:@"源码摘要: %d文件 %d行", nfile, nline];
        LCJTLog(@"战斗源码摘要完成: 文件%d 命中行%d -> %@", nfile, nline, out);
    }
}
static void LCJTAnalyzeCombatAsync(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ LCJTAnalyzeCombat(); });
}

// ==================== 自绘悬浮球 ====================
// 不用 UIButton: UIControl 事件链依赖 window 状态, 自绘 touches 更可靠
static BOOL g_ballMoved = NO;
static CGPoint g_ballStart, g_ballOrigin;

@interface LCJTBallView : UIView
@end
@implementation LCJTBallView
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)e {
    g_ballMoved = NO;
    UITouch *t = [touches anyObject];
    g_ballStart  = [t locationInView:self.superview];
    g_ballOrigin = self.center;
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)e {
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self.superview];
    CGFloat dx = p.x - g_ballStart.x, dy = p.y - g_ballStart.y;
    CGFloat dist = dx*dx + dy*dy;
    if (!g_ballMoved && dist < 100.0) return;   // ★ 10pt 以内不算拖动(消除手抖误判)
    g_ballMoved = YES;
    self.center = CGPointMake(g_ballOrigin.x + dx, g_ballOrigin.y + dy);
    if (g_panelOpen) [LCJTUI placePanel];
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)e {
    if (!g_ballMoved) {                          // ★ 是点击 → 切换面板
        g_panelOpen = !g_panelOpen;
        g_panel.hidden = !g_panelOpen;
        if (g_panelOpen) [LCJTUI placePanel];
        [LCJTUI refresh];
    }
}
- (void)touchesCancelled:(NSSet *)t withEvent:(UIEvent *)e {}
@end

// 找当前活跃的 UIWindowScene (iOS 13+ 必须绑定 windowScene, 否则触摸路由异常)
static id LCJTActiveScene(void) {
    if (@available(iOS 13.0, *)) {
        id app = [UIApplication sharedApplication];
        if ([app respondsToSelector:@selector(connectedScenes)]) {
            NSSet *scenes = [app connectedScenes];
            for (id sc in scenes) {
                if ([sc respondsToSelector:@selector(activationState)] && [sc activationState] != 0)
                    return sc;
            }
            for (id sc in scenes) return sc;
        }
    }
    return nil;
}

// 挂载悬浮层
// ★ 必须用【独立 UIWindow】而不是挂到游戏窗口:
//   游戏在自身窗口装了全屏 UIPanGestureRecognizer(cancelsTouchesInView=YES),
//   手势识别器能看到子视图的触摸 → 悬浮球一碰就被游戏手势取消。
//   跨窗口则互不干扰: 我们的 window 在高 windowLevel, 未命中时 hitTest 返回 nil
//   → UIKit 自动把触摸交给下层(游戏)窗口。
static void LCJTEnsureOverlay(void) {
    LCJTDelegate();                       // ★ 必须先实例化 target
    if (g_overlay && g_overlay.window) return;

    UIWindow *w = nil;
    id scene = LCJTActiveScene();
    w = [[LCJTPassThroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    if (@available(iOS 13.0, *)) {
        if (scene) w.windowScene = (UIWindowScene *)scene;   // ★ 显式绑定(必须!)
    }
    if (!w) { LCJTLog(@"无法创建悬浮窗口"); return; }
    LCJTLog(@"窗口 scene绑定=%d scene=%p ws=%p", (scene != nil),
            (void *)(__bridge void *)scene, (__bridge void *)w.windowScene);
    w.windowLevel = 100000;   // 远高于游戏窗口
    w.backgroundColor = UIColor.clearColor;
    w.hidden = YES;   // 稍后统一 setHidden:NO

    // 透传容器: 空白区域不拦截 → 触摸落到下层游戏窗口
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view = [[LCJTPassThroughView alloc] initWithFrame:w.bounds];
    vc.view.backgroundColor = UIColor.clearColor;
    vc.view.userInteractionEnabled = YES;
    w.rootViewController = vc;
    g_hostWin = w;

    if (!g_overlay) g_overlay = [[LCJTPassThroughView alloc] initWithFrame:w.bounds];
    g_overlay.frame = w.bounds;
    g_overlay.backgroundColor = UIColor.clearColor;
    g_overlay.userInteractionEnabled = YES;
    g_overlay.autoresizingMask = 0x1 | 0x2;

    LCJTBallView *ball = [[LCJTBallView alloc] initWithFrame:CGRectMake(20, 120, 56, 56)];
    ball.layer.cornerRadius = 28; ball.layer.masksToBounds = YES;
    ball.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    ball.layer.borderWidth = 2; ball.layer.borderColor = CGreen().CGColor;
    ball.userInteractionEnabled = YES;
    UILabel *bl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    bl.text = @"昆"; bl.textAlignment = 1;
    bl.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    bl.textColor = CGreen(); bl.backgroundColor = UIColor.clearColor;
    [ball addSubview:bl];
    [g_overlay addSubview:ball];

    CGFloat W = 260, H = 308;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
    g_panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    g_panel.layer.cornerRadius = 14; g_panel.layer.masksToBounds = YES;
    g_panel.layer.borderWidth = 1; g_panel.layer.borderColor = CGreen().CGColor;
    g_panel.center = CGPointMake(w.bounds.size.width - 150, 200);
    [g_panel addSubview:MkLabel(CGRectMake(12, 8, W - 48, 22), @"昆哥儿科技 · 龙城军团", 14, CGreen())];
    UIButton *cb = [UIButton buttonWithType:UIButtonTypeCustom];
    cb.frame = CGRectMake(W - 36, 6, 28, 28);
    [cb setTitle:@"x" forState:UIControlStateNormal];
    [cb setTitleColor:[UIColor colorWithWhite:0.75 alpha:1] forState:UIControlStateNormal];
    [cb addTarget:LCJTDelegate() action:@selector(onClose:) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:cb];
    [g_panel addSubview:MkBtn(@"o 变速  x2", @selector(onToggleTs:), NO, 38, W)];
    [g_panel addSubview:MkBtn(@"变速倍率: x2", @selector(onCycleMul:), YES, 78, W)];
    [g_panel addSubview:MkBtn(@"Lua探针(导出游戏符号)", @selector(onToggleProbe:), NO, 118, W)];
    [g_panel addSubview:MkBtn(@"扫描热更(dump Lua源码)", @selector(onScanFiles:), NO, 152, W)];
    [g_panel addSubview:MkBtn(@"分析战斗源码(出摘要)", @selector(onAnalyze:), NO, 186, W)];
    UILabel *hint = MkLabel(CGRectMake(12, 224, W - 24, 28),
                            @"秒杀/无敌/移速/攻速 需探针结果后接入", 9.5,
                            [UIColor colorWithWhite:0.62 alpha:1]);
    hint.numberOfLines = 2;
    [g_panel addSubview:hint];
    g_status = MkLabel(CGRectMake(12, 246, W - 24, 54), @"", 10, [UIColor colorWithWhite:0.85 alpha:1]);
    g_status.numberOfLines = 4;
    [g_panel addSubview:g_status];
    g_panel.hidden = YES;
    [g_overlay addSubview:g_panel];

    [vc.view addSubview:g_overlay];
    [w makeKeyAndVisible];     // 必须: 否则 window 不参与触摸派发链(球点不动)
    [LCJTUI refresh];
    LCJTLog(@"悬浮层已挂载 scene=%p win=%p bounds=%.0fx%.0f", scene, w,
            w.bounds.size.width, w.bounds.size.height);
}


static void LCJTCrashHandler(int sig);
static void LCJTInstallCrashHandler(void);
// ==================== 崩溃捕获 ====================
static void LCJTCrashHandler(int sig) {
    void *bt[48];
    int n = backtrace(bt, 48);
    NSString *p = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
                   stringByAppendingPathComponent:@"lcjt_crash.txt"];
    FILE *f = fopen(p.UTF8String, "a");
    if (f) {
        fprintf(f, "=== SIGNAL %d ===\n", sig);
        backtrace_symbols_fd(bt, n, fileno(f));
        fclose(f);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}
static void LCJTInstallCrashHandler(void) {
    signal(SIGSEGV, LCJTCrashHandler);
    signal(SIGBUS,  LCJTCrashHandler);
    signal(SIGABRT, LCJTCrashHandler);
    signal(SIGILL,  LCJTCrashHandler);
    signal(SIGTRAP, LCJTCrashHandler);
}

// ==================== 时间 hook 安装 (fishhook) ====================
static void LCJTFaultTolerantInstall(void) {
    if (!g_gameBase) LCJTFindGameImage();
    if (!g_gameBase) { LCJTLog(@"未找到主二进制, 跳过时间hook"); return; }
    struct rebinding rb[7] = {
        { "gettimeofday",                (void *)m_gtod,   (void **)&o_gtod   },
        { "time",                        (void *)m_time,   (void **)&o_time   },
        { "clock_gettime",               (void *)m_cgt,    (void **)&o_cgt    },
        { "CACurrentMediaTime",          (void *)m_media,  (void **)&o_media  },
        { "mach_absolute_time",          (void *)m_mach,   (void **)&o_mach   },
        { "clock",                       (void *)m_clock,  (void **)&o_clock  },
        { "_ZNSt3__16chrono12steady_clock3nowEv", (void *)m_steady, (void **)&o_steady },
    };
    intptr_t slide = 0;
    uint32_t nimgs = _dyld_image_count();
    for (uint32_t i = 0; i < nimgs; i++) {
        if ((uintptr_t)_dyld_get_image_header(i) == g_gameBase) {
            slide = _dyld_get_image_vmaddr_slide(i); break;
        }
    }
    int r = rebind_symbols_image((void *)g_gameBase, slide, rb, 7);
    LCJTLog(@"时间hook r=%d slide=%#lx gtod=%p time=%p cgt=%p media=%p mach=%p clock=%p steady=%p",
            r, (unsigned long)slide, o_gtod, o_time, o_cgt, o_media, o_mach, o_clock, o_steady);
}

%ctor {
    @autoreleasepool {
        LCJTInstallCrashHandler();          // ★ 最先安装
        LCJTFaultTolerantInstall();
        LCJTLog(@"LCJT v1.1 加载 base=%p", (void *)g_gameBase);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ LCJTEnsureOverlay(); });
    }
}
