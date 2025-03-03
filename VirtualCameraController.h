#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Controlador de câmera virtual para injetar o stream MJPEG
@interface VirtualCameraController : NSObject

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureConnection *videoConnection;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL debugMode;

+ (instancetype)sharedInstance;
- (BOOL)checkAndActivate;
- (void)startCapturing;
- (void)stopCapturing;
- (CMSampleBufferRef)getLatestSampleBuffer;
- (CMSampleBufferRef)getLatestSampleBufferForSubstitution;  // Novo método adicionado
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

// Interface para o substituidor de feed da câmera
@interface VirtualCameraFeedReplacer : NSObject
+ (CMSampleBufferRef)replaceCameraSampleBuffer:(CMSampleBufferRef)originalBuffer withMJPEGBuffer:(CMSampleBufferRef)mjpegBuffer;
@end
