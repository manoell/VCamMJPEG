#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Controlador de câmera virtual para injetar o stream MJPEG
@interface VirtualCameraController : NSObject

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureConnection *videoConnection;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL debugMode;
@property (nonatomic, assign) BOOL preferDisplayLayerInjection; // Nova propriedade para preferir injeção via DisplayLayer

+ (instancetype)sharedInstance;
- (BOOL)checkAndActivate;
- (void)startCapturing;
- (void)stopCapturing;
- (CMSampleBufferRef)getLatestSampleBuffer;
- (CMSampleBufferRef)getLatestSampleBufferForSubstitution;
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)setPreferDisplayLayerInjection:(BOOL)prefer; // Novo método para configurar preferência

@end

// Interface para o substituidor de feed da câmera
@interface VirtualCameraFeedReplacer : NSObject
+ (CMSampleBufferRef)replaceCameraSampleBuffer:(CMSampleBufferRef)originalBuffer withMJPEGBuffer:(CMSampleBufferRef)mjpegBuffer;
@end
