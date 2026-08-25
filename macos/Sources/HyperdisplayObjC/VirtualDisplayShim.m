#import "HyperdisplayObjC.h"
#import "CGVirtualDisplayPrivate.h"
#import <dlfcn.h>
#import <math.h>

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
                                                    uint32_t productID, uint32_t serialNum, uint8_t hiDPI) {
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
    descriptor.productID = productID;
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
    // hiDPI 语义（2026-08-21 干净系统复核）：
    //   0 = 显式 1x，当前唯一生产路径。
    //   非 0 留空曾读回更大像素画布，但 CGDisplayBounds 同样变大，实际仍是
    //   大画布 1x，不是真 Retina 2x；只保留给隔离实验。
    if (hiDPI == 0) {
        settings.hiDPI = 0;
    } // 非 0：实验路径，留空该属性

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

// MARK: - 可选的 WindowServer 光标图像读取
//
// 这组符号没有链接依赖：运行时/系统版本不支持时直接返回 nil。它与
// CGVirtualDisplay、ScreenCaptureKit 完全无关，不创建对象、不建流，也没有任何
// WindowServer 写入操作。桥接层把未知 ABI 严格收敛在一个小的、可熔断的读取点。
typedef uint32_t (*HDMainConnectionIDFn)(void);
typedef int32_t (*HDGetGlobalCursorDataSizeFn)(uint32_t connection, size_t *size);
typedef int32_t (*HDGetGlobalCursorDataFn)(uint32_t connection, void *bytes, size_t *inOutSize,
                                           void *optional0, void *outMetadata32, void *optional1,
                                           void *optional2, void *optional3, void *optional4);

static HDMainConnectionIDFn gMainConnectionID;
static HDGetGlobalCursorDataSizeFn gGetGlobalCursorDataSize;
static HDGetGlobalCursorDataFn gGetGlobalCursorData;
static BOOL gCursorReaderAvailable;

static void ensureCursorReader(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *framework = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL);
        if (framework == NULL) return;
        gMainConnectionID = (HDMainConnectionIDFn)dlsym(framework, "CGSMainConnectionID");
        gGetGlobalCursorDataSize = (HDGetGlobalCursorDataSizeFn)dlsym(framework, "CGSGetGlobalCursorDataSize");
        gGetGlobalCursorData = (HDGetGlobalCursorDataFn)dlsym(framework, "CGSGetGlobalCursorData");
        gCursorReaderAvailable = gMainConnectionID != NULL && gGetGlobalCursorDataSize != NULL &&
            gGetGlobalCursorData != NULL;
    });
}

static uint64_t hashCursorBytes(const uint8_t *bytes, size_t length, uint16_t width, uint16_t height) {
    uint64_t hash = UINT64_C(1469598103934665603);
    const uint8_t dimensions[] = { (uint8_t)width, (uint8_t)(width >> 8), (uint8_t)height, (uint8_t)(height >> 8) };
    for (size_t i = 0; i < sizeof(dimensions); i++) { hash = (hash ^ dimensions[i]) * UINT64_C(1099511628211); }
    for (size_t i = 0; i < length; i++) { hash = (hash ^ bytes[i]) * UINT64_C(1099511628211); }
    return hash;
}

NSData * _Nullable hyperdisplayCopyCurrentCursorImage(uint16_t *width, uint16_t *height,
                                                       int16_t *hotX, int16_t *hotY,
                                                       uint64_t *pixelHash) {
    if (width) *width = 0;
    if (height) *height = 0;
    if (hotX) *hotX = 0;
    if (hotY) *hotY = 0;
    if (pixelHash) *pixelHash = 0;
    ensureCursorReader();
    if (!gCursorReaderAvailable) return nil;

    size_t byteCount = 0;
    const uint32_t connection = gMainConnectionID();
    if (connection == 0 || gGetGlobalCursorDataSize(connection, &byteCount) != 0 ||
        byteCount == 0 || byteCount > 32 * 1024) return nil;

    NSMutableData *pixels = [NSMutableData dataWithLength:byteCount];
    uint8_t optional0[64] = {0}, metadata[32] = {0}, optional1[64] = {0}, optional2[64] = {0};
    uint8_t optional3[64] = {0}, optional4[64] = {0};
    if (gGetGlobalCursorData(connection, pixels.mutableBytes, &byteCount, optional0, metadata,
                             optional1, optional2, optional3, optional4) != 0 ||
        byteCount != pixels.length) return nil;

    // 当前系统实测 metadata 是小端 CGRect {hotX, hotY, width, height}（4 个 f64）。
    // 即使未来系统改变返回格式，下列严格校验也会安全回退，而不是绘制损坏内存。
    double rect[4] = {0};
    memcpy(rect, metadata, sizeof(rect));
    if (!isfinite(rect[0]) || !isfinite(rect[1]) || !isfinite(rect[2]) || !isfinite(rect[3])) return nil;
    const long w = lround(rect[2]), h = lround(rect[3]);
    if (w <= 0 || h <= 0 || w > 256 || h > 256 || (size_t)w * (size_t)h * 4 != byteCount) return nil;
    const long hx = lround(rect[0]), hy = lround(rect[1]);
    if (hx < INT16_MIN || hx > INT16_MAX || hy < INT16_MIN || hy > INT16_MAX) return nil;

    if (width) *width = (uint16_t)w;
    if (height) *height = (uint16_t)h;
    if (hotX) *hotX = (int16_t)hx;
    if (hotY) *hotY = (int16_t)hy;
    if (pixelHash) *pixelHash = hashCursorBytes(pixels.bytes, byteCount, (uint16_t)w, (uint16_t)h);
    return pixels;
}
