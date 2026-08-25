#ifndef HYPERDISPLAY_OBJC_H
#define HYPERDISPLAY_OBJC_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 创建一块虚拟显示器。成功返回 CGDirectDisplayID（>0），失败返回 0。
/// width/height 为 1x 逻辑尺寸；hiDPI 非零只保留给隔离实验，生产传 0。
/// 实例由 shim 内部持有，进程退出时全部自动销毁。
CGDirectDisplayID hyperdisplayCreateVirtualDisplay(uint32_t width, uint32_t height,
                                                    double refreshRate, NSString *name,
                                                    uint32_t productID, uint32_t serialNum, uint8_t hiDPI);

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
