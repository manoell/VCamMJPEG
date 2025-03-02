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
        _debugMode = YES;
        
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
    
    // Inicializar a fila de processamento se não existir
    if (!_processingQueue) {
        _processingQueue = dispatch_queue_create("com.vcam.mjpeg.virtual-camera", DISPATCH_QUEUE_SERIAL);
    }
    
    // Definir como ativo
    self.isActive = YES;
    writeLog(@"[CAMERA] Captura virtual iniciada com sucesso");
    
    // Verificar se o MJPEGReader está conectado
    MJPEGReader *reader = [MJPEGReader sharedInstance];
    if (!reader.isConnected) {
        writeLog(@"[CAMERA] MJPEGReader não está conectado, tentando conectar...");
        NSURL *url = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
        [reader startStreamingFromURL:url];
    }
    
    // Configurar o callback do reader se ainda não foi configurado
    if (!reader.sampleBufferCallback) {
        __weak typeof(self) weakSelf = self;
        reader.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
            [weakSelf processSampleBuffer:sampleBuffer];
        };
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
        if (_latestSampleBuffer && CMSampleBufferIsValid(_latestSampleBuffer)) {
            // Aumentar a contagem de referência para o chamador
            result = (CMSampleBufferRef)CFRetain(_latestSampleBuffer);
            
            // Limitar logs a cada 100 frames
            static int bufferCount = 0;
            if (_debugMode && (++bufferCount % 100 == 0)) {
                writeLog(@"[CAMERA] Buffer #%d disponível e válido para substituição", bufferCount);
            }
        }
    }
    
    // Limitar logs de erros também
    static int errorCount = 0;
    if (!result && _debugMode && (++errorCount % 100 == 0)) {
        writeLog(@"[CAMERA] Sem buffer disponível para substituição (ocorrência #%d)", errorCount);
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
            
            // Retenha o buffer (aumente a contagem de referência)
            _latestSampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
        }
    } @catch (NSException *exception) {
        writeLog(@"[CAMERA] Erro ao processar sampleBuffer: %@", exception);
    }
}

@end

// Implementação do substituidor de feed da câmera
@implementation VirtualCameraFeedReplacer

// Método para substituir o buffer da câmera com um buffer de MJPEG
+ (CMSampleBufferRef)replaceCameraSampleBuffer:(CMSampleBufferRef)originalBuffer withMJPEGBuffer:(CMSampleBufferRef)mjpegBuffer {
    if (!mjpegBuffer || !CMSampleBufferIsValid(mjpegBuffer)) {
        return originalBuffer;
    }
    
    // Obter o CVPixelBuffer do buffer MJPEG
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(mjpegBuffer);
    if (!pixelBuffer) {
        return originalBuffer;
    }
    
    // Obter as propriedades do buffer original para replicar no novo buffer
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(originalBuffer);
    CMTime duration = CMSampleBufferGetDuration(originalBuffer);
    
    // Criar uma descrição de formato para o novo buffer
    CMFormatDescriptionRef formatDescription = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    
    // Criar um novo sample buffer com as propriedades corretas
    CMSampleBufferRef outputBuffer = NULL;
    CMSampleTimingInfo timing = {
        .duration = duration,
        .presentationTimeStamp = presentationTime,
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    OSStatus status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        true,
        NULL,
        NULL,
        formatDescription,
        &timing,
        &outputBuffer
    );
    
    if (formatDescription) {
        CFRelease(formatDescription);
    }
    
    // Verificar se a criação foi bem-sucedida
    if (status != noErr || outputBuffer == NULL) {
        writeLog(@"[CAMERA] Falha ao criar buffer de substituição: %d", (int)status);
        return originalBuffer;
    }
    
    // Transferir as propriedades relevantes e attachments do buffer original
    // Este é um passo crítico que estava faltando
    CFArrayRef attachmentKeys = CMSampleBufferGetSampleAttachmentsArray(originalBuffer, true);
    if (attachmentKeys && CFArrayGetCount(attachmentKeys) > 0) {
        CFDictionaryRef attachments = (CFDictionaryRef)CFArrayGetValueAtIndex(attachmentKeys, 0);
        CFArrayRef outputAttachmentKeys = CMSampleBufferGetSampleAttachmentsArray(outputBuffer, true);
        
        if (attachments && outputAttachmentKeys && CFArrayGetCount(outputAttachmentKeys) > 0) {
            CFDictionaryRef outputAttachments = (CFDictionaryRef)CFArrayGetValueAtIndex(outputAttachmentKeys, 0);
            
            if (outputAttachments) {
                // Copiar flags importantes
                const void *keys[] = {CFSTR("CoreMediaIODiscontinuityFlags"), CFSTR("CoreMediaIOContinuityFlags")};
                const int numKeys = sizeof(keys) / sizeof(keys[0]);
                
                for (int i = 0; i < numKeys; i++) {
                    if (CFDictionaryContainsKey(attachments, keys[i])) {
                        CFTypeRef value = CFDictionaryGetValue(attachments, keys[i]);
                        CMSetAttachment(outputBuffer, keys[i], value, kCMAttachmentMode_ShouldPropagate);
                    }
                }
            }
        }
    }
    
    return outputBuffer;
}

@end
