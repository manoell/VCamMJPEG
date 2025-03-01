#import "VirtualCameraController.h"
#import "MJPEGReader.h"
#import "logger.h"

@interface VirtualCameraController ()
{
    // Usar variáveis de instância em vez de propriedades para tipos C
    CMSampleBufferRef _latestSampleBuffer;
    dispatch_queue_t _processingQueue;
}
@end

@implementation VirtualCameraController

+ (instancetype)sharedInstance {
    static VirtualCameraController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _processingQueue = dispatch_queue_create("com.vcam.mjpeg.virtual-camera", DISPATCH_QUEUE_SERIAL);
        _isActive = NO;
        _latestSampleBuffer = NULL;
        
        // Configurar callback para frames recebidos
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        __weak typeof(self) weakSelf = self;
        reader.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
            [weakSelf processSampleBuffer:sampleBuffer];
        };
        
        writeLog(@"[CAMERA] VirtualCameraController inicializado");
    }
    return self;
}

- (void)dealloc {
    [self cleanupBuffer];
}

- (void)cleanupBuffer {
    @synchronized (self) {
        if (_latestSampleBuffer) {
            CFRelease(_latestSampleBuffer);
            _latestSampleBuffer = NULL;
        }
    }
}

- (void)startCapturing {
    if (self.isActive) return;
    
    writeLog(@"[CAMERA] Iniciando captura virtual");
    self.isActive = YES;
}

- (void)stopCapturing {
    if (!self.isActive) return;
    
    writeLog(@"[CAMERA] Parando captura virtual");
    self.isActive = NO;
    [self cleanupBuffer];
}

- (CMSampleBufferRef)getLatestSampleBuffer {
    CMSampleBufferRef result = NULL;
    
    @synchronized (self) {
        if (_latestSampleBuffer) {
            result = (CMSampleBufferRef)CFRetain(_latestSampleBuffer);
        }
    }
    
    return result;
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.isActive) return;
    
    // Armazenar o sample buffer mais recente
    @synchronized (self) {
        // Limpar o anterior antes de substituir
        [self cleanupBuffer];
        
        // Armazenar novo buffer
        _latestSampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
    }
}

@end
