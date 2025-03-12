#import "VirtualCameraController.h"
#import "MJPEGReader.h"
#import "logger.h"
#import "GetFrame.h"
#import "Globals.h"
#import "MJPEGPreviewWindow.h"

// Variável global para rastrear se a captura está ativa em todo o sistema
static BOOL gCaptureSystemActive = NO;

// Definição para verificação de versão do iOS
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)

@interface VirtualCameraController ()
{
    // Usar variáveis de instância para tipos C
    dispatch_queue_t _processingQueue;
    dispatch_queue_t _highPriorityQueue;
    
    // Contador para limitar logs
    int _frameCounter;
    
    // Timestamp para medição de FPS
    CFTimeInterval _lastFrameTime;
    int _framesThisSecond;
    float _currentFPS;
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
        _highPriorityQueue = dispatch_queue_create("com.vcam.mjpeg.high-priority", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_highPriorityQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        
        _isActive = NO;
        _debugMode = YES;
        _frameCounter = 0;
        _preferDisplayLayerInjection = YES; // Por padrão, preferir injeção via DisplayLayer
        _lastFrameTime = 0;
        _framesThisSecond = 0;
        _currentFPS = 0;
        
        // Configurar callbacks apenas se não estivermos no SpringBoard
        if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
            // Configurar callback para frames MJPEG
            MJPEGReader *reader = [MJPEGReader sharedInstance];
            
            // Configurar para modo de alta prioridade
            [reader setHighPriority:YES];
            
            // Armazenar self fraco para evitar retenção circular
            __weak typeof(self) weakSelf = self;
            reader.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
                [weakSelf processSampleBuffer:sampleBuffer];
            };
        }
        
        writeLog(@"[CAMERA] VirtualCameraController inicializado e callback configurado");
    }
    return self;
}

- (void)dealloc {
    [self stopCapturing];
}

- (void)setPreferDisplayLayerInjection:(BOOL)prefer {
    _preferDisplayLayerInjection = prefer;
    writeLog(@"[CAMERA] Modo de injeção definido para: %@",
             prefer ? @"AVSampleBufferDisplayLayer" : @"AVCaptureOutput");
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
    // Verificar se estamos no SpringBoard - limitar funcionalidade
    BOOL isSpringBoard = [[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"];
    
    if (isSpringBoard) {
        writeLog(@"[CAMERA] Detectado SpringBoard - modo limitado de operação");
        return;
    }
    
    if (self.isActive) {
        writeLog(@"[CAMERA] Captura virtual já está ativa");
        return;
    }
    
    writeLog(@"[CAMERA] Iniciando captura virtual (Modo: %@)",
             self.preferDisplayLayerInjection ? @"DisplayLayer" : @"CaptureOutput");
    
    // Inicializar a fila de processamento se não existir
    if (!_processingQueue) {
        _processingQueue = dispatch_queue_create("com.vcam.mjpeg.virtual-camera", DISPATCH_QUEUE_SERIAL);
    }
    
    // Inicializar fila de alta prioridade
    if (!_highPriorityQueue) {
        _highPriorityQueue = dispatch_queue_create("com.vcam.mjpeg.high-priority", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_highPriorityQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    }
    
    // Definir como ativo globalmente
    gCaptureSystemActive = YES;
    self.isActive = YES;
    writeLog(@"[CAMERA] Captura virtual iniciada com sucesso");
    
    // Verificar se o MJPEGReader está conectado
    MJPEGReader *reader = [MJPEGReader sharedInstance];
    if (!reader.isConnected) {
        writeLog(@"[CAMERA] MJPEGReader não está conectado, tentando conectar...");
        NSURL *url = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
        [reader startStreamingFromURL:url];
    }
    
    // Garantir que o callback esteja configurado
    if (!reader.sampleBufferCallback) {
        __weak typeof(self) weakSelf = self;
        reader.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
            [weakSelf processSampleBuffer:sampleBuffer];
        };
    }
    
    // Detectar aplicativo atual para configurações específicas
    NSString *processName = [NSProcessInfo processInfo].processName;
    
    // Configurações específicas para aplicativos conhecidos
    if ([processName isEqualToString:@"Camera"]) {
        // App nativo de câmera - preferir DisplayLayer
        [reader setHighPriority:YES];
        self.preferDisplayLayerInjection = YES;
        writeLog(@"[CAMERA] Configurações otimizadas para app de Câmera nativo");
    } else if ([processName isEqualToString:@"Telegram"]) {
        // Telegram - ajustes específicos
        [reader setHighPriority:YES];
        self.preferDisplayLayerInjection = NO; // Telegram funciona melhor com a abordagem de saída direta
        writeLog(@"[CAMERA] Configurações otimizadas para Telegram");
    } else if ([processName isEqualToString:@"MobileSlideShow"]) {
        // App de Fotos
        [reader setHighPriority:YES];
        self.preferDisplayLayerInjection = YES;
        writeLog(@"[CAMERA] Configurações otimizadas para app de Fotos");
    } else {
        // Modo padrão para outros apps
        [reader setHighPriority:YES];
        writeLog(@"[CAMERA] Usando configurações padrão para %@", processName);
    }
}

- (void)stopCapturing {
    if (!self.isActive) return;
    
    writeLog(@"[CAMERA] Parando captura virtual");
    self.isActive = NO;
    gCaptureSystemActive = NO;
    
    // Configurar MJPEGReader para modo normal
    [[MJPEGReader sharedInstance] setHighPriority:NO];
    
    // Vamos também limpar a instância GetFrame para liberar buffers
    [GetFrame cleanupResources];
}

// Método para obter o latest sample buffer (implementado para compatibilidade)
- (CMSampleBufferRef)getLatestSampleBuffer {
    static int callCount = 0;
    
    // Log limitado
    if (++callCount % 200 == 0) {
        writeLog(@"[CAMERA] getLatestSampleBuffer chamado %d vezes", callCount);
    }
    
    // Usar o GetFrame para obter o buffer atual
    return [GetFrame getCurrentFrame:NULL replace:NO];
}

// Implementação específica para substituição de câmera
- (CMSampleBufferRef)getLatestSampleBufferForSubstitution {
    static int callCount = 0;
    
    // Log menos frequente
    if (++callCount % 300 == 0) {
        writeLog(@"[CAMERA] getLatestSampleBufferForSubstitution chamado #%d", callCount);
    }
    
    // Usar o GetFrame para obter o buffer para substituição
    return [GetFrame getCurrentFrame:NULL replace:YES];
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.isActive) return;
    
    @try {
        // Verificar se o buffer é válido
        if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
            return;
        }
        
        // Calcular FPS
        CFTimeInterval currentTime = CACurrentMediaTime();
        _framesThisSecond++;
        
        if (currentTime - _lastFrameTime >= 1.0) {
            _currentFPS = _framesThisSecond / (currentTime - _lastFrameTime);
            _framesThisSecond = 0;
            _lastFrameTime = currentTime;
            
            if (_debugMode) {
                writeLog(@"[CAMERA] FPS atual: %.1f", _currentFPS);
            }
        }
        
        // Enviar para o GetFrame para armazenamento e uso na substituição
        [[GetFrame sharedInstance] processNewMJPEGFrame:sampleBuffer];
        
        // Atualizar a imagem na interface de preview, se estiver disponível e visível
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updatePreviewImage];
            });
        } else {
            [self updatePreviewImage];
        }
        
        // Log periódico
        if (_debugMode && (++_frameCounter % 300 == 0)) {
            writeLog(@"[CAMERA] Frame MJPEG #%d processado pelo VirtualCameraController", _frameCounter);
            
            // Debug info - formato do buffer
            CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
            if (formatDesc) {
                FourCharCode mediaType = CMFormatDescriptionGetMediaType(formatDesc);
                FourCharCode mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc);
                char typeStr[5] = {0};
                char subTypeStr[5] = {0};
                
                // Convertendo FourCharCode para string legível
                typeStr[0] = (char)((mediaType >> 24) & 0xFF);
                typeStr[1] = (char)((mediaType >> 16) & 0xFF);
                typeStr[2] = (char)((mediaType >> 8) & 0xFF);
                typeStr[3] = (char)(mediaType & 0xFF);
                
                subTypeStr[0] = (char)((mediaSubType >> 24) & 0xFF);
                subTypeStr[1] = (char)((mediaSubType >> 16) & 0xFF);
                subTypeStr[2] = (char)((mediaSubType >> 8) & 0xFF);
                subTypeStr[3] = (char)(mediaSubType & 0xFF);
                
                writeLog(@"[CAMERA] Media Type: %s, SubType: %s", typeStr, subTypeStr);
            }
            
            // Debug info - dimensões do frame
            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (imageBuffer) {
                size_t width = CVPixelBufferGetWidth(imageBuffer);
                size_t height = CVPixelBufferGetHeight(imageBuffer);
                writeLog(@"[CAMERA] Frame dimensões: %zu x %zu", width, height);
            }
        }
    } @catch (NSException *exception) {
        writeLog(@"[CAMERA] Erro ao processar sampleBuffer: %@", exception);
    }
}

// Método para atualizar a interface de preview
- (void)updatePreviewImage {
    // Verificar se a janela de preview está disponível e o preview está ativo
    Class previewWindowClass = NSClassFromString(@"MJPEGPreviewWindow");
    if (previewWindowClass) {
        id previewWindow = [previewWindowClass sharedInstance];
        if ([previewWindow respondsToSelector:@selector(updatePreviewImage:)]) {
            // Obter a imagem para o preview
            UIImage *previewImage = [[GetFrame sharedInstance] getDisplayImage];
            if (previewImage) {
                [(MJPEGPreviewWindow *)previewWindow updatePreviewImage:previewImage];
            }
        }
    }
}

@end

@implementation VirtualCameraFeedReplacer

// Método para substituir o buffer da câmera com um buffer de MJPEG
+ (CMSampleBufferRef)replaceCameraSampleBuffer:(CMSampleBufferRef)originalBuffer withMJPEGBuffer:(CMSampleBufferRef)mjpegBuffer {
    if (!mjpegBuffer || !CMSampleBufferIsValid(mjpegBuffer)) {
        return originalBuffer;
    }
    
    // Verificar se o buffer MJPEG tem uma imagem válida
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(mjpegBuffer);
    if (imageBuffer == NULL) {
        return originalBuffer;
    }
    
    // Criar uma cópia do buffer MJPEG para garantir segurança de memória
    CMSampleBufferRef resultBuffer = NULL;
    OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, mjpegBuffer, &resultBuffer);
    
    if (status != noErr || resultBuffer == NULL) {
        return originalBuffer;
    }
    
    // Se o originalBuffer for válido, transferir informações de timing
    if (originalBuffer && CMSampleBufferIsValid(originalBuffer)) {
        @try {
            // Copiar timing do buffer original
            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(originalBuffer);
            CMTime duration = CMSampleBufferGetDuration(originalBuffer);
            
            // Criar timing info para sincronização
            CMSampleTimingInfo timing = {0};
            timing.duration = duration;
            timing.presentationTimeStamp = presentationTime;
            timing.decodeTimeStamp = kCMTimeInvalid;
            
            // Criar novo buffer com timing sincronizado
            CMSampleBufferRef syncedBuffer = NULL;
            status = CMSampleBufferCreateCopyWithNewTiming(
                kCFAllocatorDefault,
                resultBuffer,
                1,
                &timing,
                &syncedBuffer
            );
            
            if (status == noErr && syncedBuffer != NULL) {
                // Liberar o buffer anterior
                CFRelease(resultBuffer);
                resultBuffer = syncedBuffer;
            }
            
            // Transferir metadados importantes
            // Orientação
            CFTypeRef orientationAttachment = CMGetAttachment(originalBuffer, CFSTR("VideoOrientation"), NULL);
            if (orientationAttachment) {
                CMSetAttachment(resultBuffer, CFSTR("VideoOrientation"),
                               orientationAttachment, kCMAttachmentMode_ShouldPropagate);
            }
            
            // Outros metadados comuns - Corrigido para usar @[] ao invés de CFStringRef direto
            NSArray *metadataKeys = @[
                (id)CFSTR("CVImageBufferYCbCrMatrix"),
                (id)CFSTR("CVImageBufferColorPrimaries"),
                (id)CFSTR("CVImageBufferTransferFunction"),
                (id)CFSTR("CVFieldCount"),
                (id)CFSTR("CVFieldDetail")
            ];
            
            for (id key in metadataKeys) {
                CFTypeRef attachment = CMGetAttachment(originalBuffer, (CFStringRef)key, NULL);
                if (attachment) {
                    CMSetAttachment(resultBuffer, (CFStringRef)key,
                                  attachment, kCMAttachmentMode_ShouldPropagate);
                }
            }
        } @catch (NSException *e) {
            // Em caso de erro, continuar com o buffer não sincronizado
            writeLog(@"[CAMERA] Erro ao sincronizar buffer: %@", e);
        }
    }
    
    // Retornar a cópia do buffer MJPEG (possivelmente com timing atualizado)
    return resultBuffer;
}

@end

@implementation AVCapturePhotoProxy

+ (instancetype)proxyWithDelegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    AVCapturePhotoProxy *proxy = [[AVCapturePhotoProxy alloc] init];
    proxy.originalDelegate = delegate;
    return proxy;
}

#pragma mark - AVCapturePhotoCaptureDelegate Methods

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// iOS 10+
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)photoSampleBuffer previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings bracketSettings:(AVCaptureBracketedStillImageSettings *)bracketSettings error:(NSError *)error {
    
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:)]) {
        
        writeLog(@"[PHOTOPROXY] Interceptando didFinishProcessingPhotoSampleBuffer");
        
        // Obter buffer de substituição
        CMSampleBufferRef mjpegBuffer = photoSampleBuffer ? [GetFrame getCurrentFrame:photoSampleBuffer replace:YES] : nil;
        
        if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
            writeLog(@"[PHOTOPROXY] Substituindo buffer na finalização da captura de foto");
            
            // Transferir metadados críticos se existirem
            if (photoSampleBuffer) {
                @try {
                    // Copiar timestamp de apresentação
                    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(photoSampleBuffer);
                    CMTime duration = CMSampleBufferGetDuration(photoSampleBuffer);
                    
                    // Criar timing info baseado no buffer original
                    CMSampleTimingInfo timing = {0};
                    timing.duration = duration;
                    timing.presentationTimeStamp = presentationTime;
                    timing.decodeTimeStamp = kCMTimeInvalid;
                    
                    // Criar novo buffer com timing sincronizado
                    CMSampleBufferRef syncedBuffer = NULL;
                    OSStatus status = CMSampleBufferCreateCopyWithNewTiming(
                        kCFAllocatorDefault,
                        mjpegBuffer,
                        1,
                        &timing,
                        &syncedBuffer
                    );
                    
                    if (status == noErr && syncedBuffer != NULL) {
                        // Liberar o buffer anterior
                        CFRelease(mjpegBuffer);
                        mjpegBuffer = syncedBuffer;
                        
                        // Copiar metadados importantes
                        NSArray *metadataKeys = @[
                            (id)CFSTR("VideoOrientation"),
                            (id)CFSTR("{Exif}"),
                            (id)CFSTR("{TIFF}"),
                            (id)CFSTR("{DNG}"),
                            (id)CFSTR("{GPS}")
                        ];
                        
                        for (id key in metadataKeys) {
                            CFTypeRef attachment = CMGetAttachment(photoSampleBuffer, (CFStringRef)key, NULL);
                            if (attachment) {
                                CMSetAttachment(mjpegBuffer, (CFStringRef)key,
                                              attachment, kCMAttachmentMode_ShouldPropagate);
                            }
                        }
                    }
                } @catch (NSException *e) {
                    writeLog(@"[PHOTOPROXY] Erro ao copiar metadados: %@", e);
                }
            }
            
            [self.originalDelegate captureOutput:output
                didFinishProcessingPhotoSampleBuffer:mjpegBuffer
                       previewPhotoSampleBuffer:previewPhotoSampleBuffer
                             resolvedSettings:resolvedSettings
                              bracketSettings:bracketSettings
                                       error:error];
            
            // Liberar o buffer MJPEG
            CFRelease(mjpegBuffer);
        } else {
            [self.originalDelegate captureOutput:output
                didFinishProcessingPhotoSampleBuffer:photoSampleBuffer
                       previewPhotoSampleBuffer:previewPhotoSampleBuffer
                             resolvedSettings:resolvedSettings
                              bracketSettings:bracketSettings
                                       error:error];
        }
    }
}
#pragma clang diagnostic pop

// iOS 11+
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
        
        writeLog(@"[PHOTOPROXY] Interceptando didFinishProcessingPhoto");
        
        // Como não podemos modificar o AVCapturePhoto diretamente,
        // apenas passamos para o delegate original
        [self.originalDelegate captureOutput:output didFinishProcessingPhoto:photo error:error];
        
        // Notificar que a foto foi capturada para liberar os recursos extras
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            g_isCapturingPhoto = NO;
            writeLog(@"[PHOTOPROXY] Captura de foto concluída");
        });
    }
}

// Implementações para outros métodos do protocolo AVCapturePhotoCaptureDelegate
// Adicione conforme necessário

// Método para encaminhar mensagens desconhecidas para o delegate original
- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.originalDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.originalDelegate respondsToSelector:aSelector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:aSelector];
}

@end
