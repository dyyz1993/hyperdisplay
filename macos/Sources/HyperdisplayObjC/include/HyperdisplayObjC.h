#ifndef HYPERDISPLAY_OBJC_H
#define HYPERDISPLAY_OBJC_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 创建一块虚拟显示器。成功返回 CGDirectDisplayID（>0），失败返回 0。
/// pixelWidth/pixelHeight 是 ScreenCaptureKit 应采集的完整物理像素；
/// logicalWidth/logicalHeight 是 macOS 排版使用的逻辑点。两者相同为 1x，
/// 物理像素恰好为逻辑点 2 倍时启用真正的 Retina 2x。
/// 实例由 shim 内部持有，进程退出时全部自动销毁。
CGDirectDisplayID hyperdisplayCreateVirtualDisplay(uint32_t pixelWidth, uint32_t pixelHeight,
                                                    uint32_t logicalWidth, uint32_t logicalHeight,
                                                    double refreshRate, NSString *name,
                                                    uint32_t productID, uint32_t serialNum);

/// 销毁一块由本进程创建的虚拟显示器。
void hyperdisplayDestroyVirtualDisplay(CGDirectDisplayID displayID);

/// 销毁全部（正常退出路径调用；异常退出由进程死亡兜底）。
void hyperdisplayDestroyAllVirtualDisplays(void);

/// 当前存活数量
NSUInteger hyperdisplayVirtualDisplayCount(void);

/// 只读当前 macOS 光标的实际 BGRA 图像及热点。此能力使用运行时解析的
/// WindowServer 符号：任一符号缺失、数据不合法或调用失败都返回 nil；调用方必须
/// 自动回退到本地箭头，绝不能影响视频流或虚拟显示器生命周期。
NSData * _Nullable hyperdisplayCopyCurrentCursorImage(uint16_t *width, uint16_t *height,
                                                       int16_t *hotX, int16_t *hotY,
                                                       uint64_t *pixelHash);

NS_ASSUME_NONNULL_END

#endif
