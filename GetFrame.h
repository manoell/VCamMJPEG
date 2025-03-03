#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>

// Singleton para substituição de frames - seguindo o modelo do tweak decompilado
@interface GetFrame : NSObject

+ (instancetype)sharedInstance;
+ (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)inputBuffer replace:(BOOL)replace;
- (UIImage *)getDisplayImage;
- (void)processNewMJPEGFrame:(CMSampleBufferRef)sampleBuffer;

@end
