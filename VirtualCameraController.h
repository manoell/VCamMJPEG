#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Controlador de câmera virtual para injetar o stream MJPEG
@interface VirtualCameraController : NSObject

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureConnection *videoConnection;
@property (nonatomic, assign) BOOL isActive;

+ (instancetype)sharedInstance;
- (void)startCapturing;
- (void)stopCapturing;
- (CMSampleBufferRef)getLatestSampleBuffer;
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end
