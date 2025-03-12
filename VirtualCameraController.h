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
@property (nonatomic, assign) BOOL isRecordingVideo; // Nova propriedade para rastrear gravação de vídeo
@property (nonatomic, assign) BOOL optimizedForVideo; // Nova propriedade para modo de vídeo
@property (nonatomic, strong) NSURL *currentURL; // Armazenar URL atual para reconexão
@property (nonatomic, assign) uint32_t preferredPixelFormat; // Formato de pixel preferido
@property (nonatomic, assign) int currentVideoOrientation; // Orientação atual

+ (instancetype)sharedInstance;
- (BOOL)checkAndActivate;
- (void)startCapturing;
- (void)stopCapturing;
- (CMSampleBufferRef)getLatestSampleBuffer;
- (CMSampleBufferRef)getLatestSampleBufferForSubstitution;
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)setPreferDisplayLayerInjection:(BOOL)prefer; // Método para configurar preferência
- (void)setOptimizedForVideo:(BOOL)optimized; // Método para otimização de vídeo
- (void)setPreferredPixelFormat:(uint32_t)format; // Método para definir formato de pixel
- (void)setCurrentVideoOrientation:(int)orientation; // Método para definir orientação

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

// Adicionado - Proxy para gravação de vídeo
@interface VideoRecordingProxy : NSObject <AVCaptureFileOutputRecordingDelegate>
@property (nonatomic, strong) id<AVCaptureFileOutputRecordingDelegate> originalDelegate;
+ (instancetype)proxyWithDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate;
@end
