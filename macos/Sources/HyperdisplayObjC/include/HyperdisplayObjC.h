#ifndef HYPERDISPLAY_OBJC_H
#define HYPERDISPLAY_OBJC_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 创建一块虚拟显示器。成功返回 CGDirectDisplayID（>0），失败返回 0。
/// 实例由 shim 内部持有，进程退出时全部自动销毁。
CGDirectDisplayID hyperdisplayCreateVirtualDisplay(uint32_t width, uint32_t height,
                                                    double refreshRate, NSString *name);

/// 销毁一块由本进程创建的虚拟显示器。
void hyperdisplayDestroyVirtualDisplay(CGDirectDisplayID displayID);

/// 销毁全部（正常退出路径调用；异常退出由进程死亡兜底）。
void hyperdisplayDestroyAllVirtualDisplays(void);

/// 当前存活数量
NSUInteger hyperdisplayVirtualDisplayCount(void);

NS_ASSUME_NONNULL_END

#endif
