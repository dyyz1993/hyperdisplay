#ifndef HYPERDISPLAY_OBJC_H
#define HYPERDISPLAY_OBJC_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 创建一块虚拟显示器。成功返回 CGDirectDisplayID（>0），失败返回 0。
/// width/height 为逻辑尺寸；hiDPI=2 时物理像素翻倍（逻辑 1400x920 → 物理 2800x1840），
/// macOS 以 2x 渲染——UI 元素常规大小、文字达到视网膜级锐度。
/// 实例由 shim 内部持有，进程退出时全部自动销毁。
CGDirectDisplayID hyperdisplayCreateVirtualDisplay(uint32_t width, uint32_t height,
                                                    double refreshRate, NSString *name,
                                                    uint32_t serialNum, uint8_t hiDPI);

/// 销毁一块由本进程创建的虚拟显示器。
void hyperdisplayDestroyVirtualDisplay(CGDirectDisplayID displayID);

/// 销毁全部（正常退出路径调用；异常退出由进程死亡兜底）。
void hyperdisplayDestroyAllVirtualDisplays(void);

/// 当前存活数量
NSUInteger hyperdisplayVirtualDisplayCount(void);

NS_ASSUME_NONNULL_END

#endif
