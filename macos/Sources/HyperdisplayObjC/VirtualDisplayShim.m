#import "HyperdisplayObjC.h"
#import "CGVirtualDisplayPrivate.h"

static NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *gDisplays;
static dispatch_queue_t gQueue;

static void ensureInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gDisplays = [NSMutableDictionary dictionary];
        gQueue = dispatch_queue_create("hyperdisplay.virtual-display-shim", DISPATCH_QUEUE_SERIAL);
    });
}

CGDirectDisplayID hyperdisplayCreateVirtualDisplay(uint32_t width, uint32_t height,
                                                    double refreshRate, NSString *name,
                                                    uint32_t serialNum, uint8_t hiDPI) {
    ensureInit();

    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.queue = gQueue;
    descriptor.name = name ?: @"Hyperdisplay";
    descriptor.maxPixelsWide = 16384;
    descriptor.maxPixelsHigh = 16384;
    // 物理尺寸申报：实测对模式列表无影响（237DPI 也不生成 HiDPI 档——CGVirtualDisplay
    // 无驱动支持，2x 渲染不可达），保持大屏口径即可
    // 密度申报：与极简复现工具完全一致（判责工具上默认 2x 渲染的变量对齐）
    descriptor.sizeInMillimeters = CGSizeMake(600.0, 400.0);
    descriptor.vendorID = 0x1A2B;
    descriptor.productID = 0x0001;
    // EDID serial 恒定：macOS 按 (vendor,product,serial) 记忆显示器——排列位置、
    // 窗口归属都挂在它上面。随机值 = 每次都是「新显示器」（位置乱、窗口不归位）。
    descriptor.serialNum = serialNum;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (display == nil) {
        return 0;
    }

    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:width
                                                                      height:height
                                                                 refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.modes = @[ mode ];
    // hiDPI 语义（2026-08-21 极简复现修正）：
    //   0  = 显式 1x（老行为；1x 屏上 applySettings 换模式不生效）
    //   2  = 不设该属性 → 系统 2x 渲染（逻辑 WxH → 物理 2Wx2H），且模式切换生效
    //        （旧结论"HiDPI 2x 不可达"系显式 settings.hiDPI=2 只出 1x 档所致）
    if (hiDPI == 0) {
        settings.hiDPI = 0;
    } // hiDPI==2：留空，系统默认即 2x

    if (![display applySettings:settings]) {
        return 0;
    }
    CGDirectDisplayID displayID = display.displayID;
    if (displayID == 0) {
        return 0;
    }
    @synchronized (gDisplays) {
        gDisplays[@(displayID)] = display;
    }
    return displayID;
}

void hyperdisplayDestroyVirtualDisplay(CGDirectDisplayID displayID) {
    if (displayID == 0) {
        return;
    }
    @synchronized (gDisplays) {
        [gDisplays removeObjectForKey:@(displayID)];
    }
}

BOOL hyperdisplayResizeVirtualDisplay(CGDirectDisplayID displayID,
                                      uint32_t width, uint32_t height) {
    @synchronized (gDisplays) {
        CGVirtualDisplay *display = gDisplays[@(displayID)];
        if (display == nil || width == 0 || height == 0) {
            return NO;
        }
        CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:width
                                                                          height:height
                                                                     refreshRate:60.0];
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.modes = @[ mode ];
        // 档位切换 = 模式切换：同一显示器实例/EDID，windowserver 走模式变更路径
        // （排列位置与窗口归属保留），绝不销毁重建（新 SCStream 必死）
        if (![display applySettings:settings]) {
            return NO;
        }
    }
    return YES;
}

void hyperdisplayDestroyAllVirtualDisplays(void) {
    @synchronized (gDisplays) {
        [gDisplays removeAllObjects];
    }
}

NSUInteger hyperdisplayVirtualDisplayCount(void) {
    @synchronized (gDisplays) {
        return gDisplays.count;
    }
}
