#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenCVSegmentationBridge : NSObject

+ (nullable NSData *)regionLabelsFromGrayscale:(NSData *)grayscale
                                   subjectMask:(nullable NSData *)subjectMask
                                         width:(NSInteger)width
                                        height:(NSInteger)height;

+ (nullable NSData *)refinedForegroundMaskFromRGBA:(NSData *)rgba
                                          seedMask:(nullable NSData *)seedMask
                                          hintMask:(nullable NSData *)hintMask
                                             width:(NSInteger)width
                                            height:(NSInteger)height;

@end

FOUNDATION_EXPORT NSData * _Nullable OpenCVRegionLabelsFromGrayscale(
    NSData *grayscale,
    NSData * _Nullable subjectMask,
    NSInteger width,
    NSInteger height
);

FOUNDATION_EXPORT NSData * _Nullable OpenCVRefinedForegroundMaskFromRGBA(
    NSData *rgba,
    NSData * _Nullable seedMask,
    NSData * _Nullable hintMask,
    NSInteger width,
    NSInteger height
);

NS_ASSUME_NONNULL_END
