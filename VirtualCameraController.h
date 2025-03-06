#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Controlador de câmera virtual para injetar o stream MJPEG
@interface VirtualCameraController : NSObject

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureConnection *videoConnection;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL debugMode;
@property (nonatomic, assign) BOOL preferDisplayLayerInjection; // Propriedade para preferir injeção via DisplayLayer

+ (instancetype)sharedInstance;
- (BOOL)checkAndActivate;
- (void)startCapturing;
- (void)stopCapturing;
- (CMSampleBufferRef)getLatestSampleBuffer;
- (CMSampleBufferRef)getLatestSampleBufferForSubstitution;
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)setPreferDisplayLayerInjection:(BOOL)prefer; // Método para configurar preferência

@end

// Interface para o substituidor de feed da câmera
@interface VirtualCameraFeedReplacer : NSObject
+ (CMSampleBufferRef)replaceCameraSampleBuffer:(CMSampleBufferRef)originalBuffer withMJPEGBuffer:(CMSampleBufferRef)mjpegBuffer;
@end

// Adicionado - Proxy para captura de foto
@interface AVCapturePhotoProxy : NSObject <AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id<AVCapturePhotoCaptureDelegate> originalDelegate;
+ (instancetype)proxyWithDelegate:(id<AVCapturePhotoCaptureDelegate>)delegate;
@end
