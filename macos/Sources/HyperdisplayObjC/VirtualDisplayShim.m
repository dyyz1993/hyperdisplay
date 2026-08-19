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
                                                    uint32_t serialNum) {
    ensureInit();

    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.queue = gQueue;
    descriptor.name = name ?: @"Hyperdisplay";
    descriptor.maxPixelsWide = 16384;
    descriptor.maxPixelsHigh = 16384;
    descriptor.sizeInMillimeters = CGSizeMake(600.0 * width / 1920.0, 340.0 * height / 1200.0);
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
    settings.hiDPI = 0;

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
