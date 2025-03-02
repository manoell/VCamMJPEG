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
        
        // Configurar callback para frames MJPEG
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        
        // Armazenar self fraco para evitar retenção circular
        __weak typeof(self) weakSelf = self;
        reader.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
            [weakSelf processSampleBuffer:sampleBuffer];
        };
        
        writeLog(@"[CAMERA] VirtualCameraController inicializado e callback configurado");
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

- (BOOL)checkAndActivate {
    // Se já estiver ativo, apenas retornar TRUE
    if (self.isActive) {
        return YES;
    }
    
    // Ativar controlador
    [self startCapturing];
    
    // Verificar se agora está ativo
    return self.isActive;
}

- (void)startCapturing {
    if (self.isActive) {
        writeLog(@"[CAMERA] Captura virtual já está ativa");
        return;
    }
    
    writeLog(@"[CAMERA] Iniciando captura virtual");
    self.isActive = YES;
    writeLog(@"[CAMERA] Captura virtual iniciada com sucesso");
    
    // Verificar se o MJPEGReader está conectado
    MJPEGReader *reader = [MJPEGReader sharedInstance];
    if (!reader.isConnected) {
        writeLog(@"[CAMERA] MJPEGReader não está conectado, tentando conectar...");
        NSURL *url = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
        [reader startStreamingFromURL:url];
    }
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
            if (CMSampleBufferIsValid(_latestSampleBuffer)) {
                result = (CMSampleBufferRef)CFRetain(_latestSampleBuffer);
                writeLog(@"[CAMERA] Buffer disponível e válido para substituição");
            }
        }
    }
    
    if (!result) {
        writeLog(@"[CAMERA] Sem buffer disponível para substituição");
    }
    
    return result;
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.isActive) return;
    
    @try {
        // Verificar se o buffer é válido
        if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
            return;
        }
        
        // Armazenar o sample buffer mais recente com proteção
        @synchronized (self) {
            // Limpar o anterior com verificação
            if (_latestSampleBuffer) {
                CFRelease(_latestSampleBuffer);
                _latestSampleBuffer = NULL;
            }
            
            // Armazenar novo buffer
            _latestSampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
        }
    } @catch (NSException *exception) {
        writeLog(@"[CAMERA] Erro ao processar sampleBuffer: %@", exception);
    }
}

@end
