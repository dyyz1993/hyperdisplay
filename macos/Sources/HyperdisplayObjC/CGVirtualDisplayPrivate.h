// CGVirtualDisplay 私有 API 的 ObjC 声明（class-dump 接口）。
// 接口来源：DeskPad（https://github.com/Stengo/DeskPad，MIT License），
// 其声明源自 Khaos Tian 的 VirtualDisplayExp dump。macOS 26 SDK 的
// CoreGraphics.tbd 仍导出这些类，接口稳定可用。

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplayDescriptor;

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) CGFloat refreshRate;
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
- (instancetype)initWithWidth:(NSUInteger)arg1 height:(NSUInteger)arg2 refreshRate:(CGFloat)arg3;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) NSArray *modes;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) id terminationHandler;
@property (readonly, nonatomic) dispatch_queue_t queue;
@property (readonly, nonatomic) unsigned int maxPixelsHigh;
@property (readonly, nonatomic) unsigned int maxPixelsWide;
@property (readonly, nonatomic) CGSize sizeInMillimeters;
@property (readonly, nonatomic) NSString *name;
@property (readonly, nonatomic) unsigned int serialNum;
@property (readonly, nonatomic) unsigned int productID;
@property (readonly, nonatomic) unsigned int vendorID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)arg1;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)arg1;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
