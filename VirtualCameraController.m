#import "VirtualCameraController.h"
#import "MJPEGReader.h"
#import "logger.h"
#import "GetFrame.h"
#import "Globals.h"
#import "MJPEGPreviewWindow.h"

// Variável global para rastrear se a captura está ativa em todo o sistema
static BOOL gCaptureSystemActive = NO;

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
        _isRecordingVideo = NO;
        _optimizedForVideo = NO;
        _currentURL = nil;
        _preferredPixelFormat = kCVPixelFormatType_32BGRA; // Formato padrão
        _currentVideoOrientation = 1; // Portrait por padrão
        
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

- (void)setPreferredPixelFormat:(uint32_t)format {
    _preferredPixelFormat = format;
    
    // Formato em string para log
    NSString *formatString;
    switch (format) {
        case kCVPixelFormatType_32BGRA:
            formatString = @"32BGRA";
            break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            formatString = @"420f (BiPlanar)";
            break;
        case kCVPixelFormatType_420YpCbCr8Planar:
            formatString = @"420v (Planar)";
            break;
        default:
            formatString = [NSString stringWithFormat:@"0x%08X", format];
            break;
    }
    
    writeLog(@"[CAMERA] Formato de pixel preferido definido para: %@", formatString);
}

- (void)setCurrentVideoOrientation:(int)orientation {
    _currentVideoOrientation = orientation;
    
    // Atualizar a variável global
    g_videoOrientation = orientation;
    g_isVideoOrientationSet = YES;
    
    writeLog(@"[CAMERA] Orientação de vídeo atualizada para: %d", orientation);
    
    // Se estiver gravando vídeo, precisamos garantir que todos os componentes usem a mesma orientação
    if (self.isRecordingVideo) {
        // Atualizar o videoConnection se disponível
        if (self.videoConnection && [self.videoConnection isVideoOrientationSupported]) {
            AVCaptureVideoOrientation videoOrientation = (AVCaptureVideoOrientation)orientation;
            self.videoConnection.videoOrientation = videoOrientation;
        }
    }
}

// Implementação para o método setOptimizedForVideo: - crítico para gravação de vídeo
- (void)setOptimizedForVideo:(BOOL)optimized {
    if (_optimizedForVideo == optimized) return;
    
    _optimizedForVideo = optimized;
    writeLog(@"[CAMERA] Modo otimizado para vídeo: %@", optimized ? @"ATIVADO" : @"DESATIVADO");
    
    // Configurar alta prioridade para o leitor MJPEG durante gravação
    [[MJPEGReader sharedInstance] setHighPriority:optimized];
    
    // Configurar modo de processamento para vídeo
    if (optimized) {
        [[MJPEGReader sharedInstance] setProcessingMode:MJPEGReaderProcessingModeHighPerformance];
    } else {
        [[MJPEGReader sharedInstance] setProcessingMode:MJPEGReaderProcessingModeDefault];
    }
    
    // Atualizar flag para rastreamento
    self.isRecordingVideo = optimized;
    g_isRecordingVideo = optimized; // Atualizar variável global também
    
    if (optimized) {
        // Configurações específicas para vídeo
        // Com base nas informações do diagnóstico (formato 420f)
        
        // Verificar se temos um leitor MJPEG conectado, caso contrário, tentar reconectar
        MJPEGReader *mjpegReader = [MJPEGReader sharedInstance];
        if (!mjpegReader.isConnected) {
            writeLog(@"[CAMERA] Tentando reconectar MJPEG para gravação de vídeo");
            if (self.currentURL) {
                [mjpegReader startStreamingFromURL:self.currentURL];
            } else {
                // URL padrão como fallback
                NSURL *url = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
                [mjpegReader startStreamingFromURL:url];
            }
        }
        
        // Configurar para usar as dimensões da câmera do diagnóstico se disponíveis
        if (CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero)) {
            // Usar dimensões do diagnóstico
            if (g_usingFrontCamera) {
                // Para câmera frontal, poderia usar outra resolução se necessário
                g_originalFrontCameraResolution = CGSizeMake(1334, 750);
            } else {
                // Usar dimensões da câmera traseira do diagnóstico
                g_originalBackCameraResolution = CGSizeMake(4032, 3024);
            }
            
            // Atualizar resolução atual
            g_originalCameraResolution = g_usingFrontCamera ? g_originalFrontCameraResolution : g_originalBackCameraResolution;
            
            writeLog(@"[CAMERA] Usando resolução do diagnóstico para vídeo: %.0f x %.0f",
                  g_originalCameraResolution.width, g_originalCameraResolution.height);
        }
        
        // Pré-carregar alguns frames para garantir inicialização suave
        dispatch_async(_highPriorityQueue, ^{
            for (int i = 0; i < 5; i++) {
                [GetFrame getCurrentFrame:NULL replace:YES];
            }
        });
    } else {
        // Modo normal - desativar otimizações específicas para vídeo
        // Limpeza de recursos específicos para vídeo
        //[GetFrame flushVideoBuffers];
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
    
    // Armazenar a URL atual para uso futuro
    if (reader.currentURL) {
        self.currentURL = reader.currentURL;
        writeLog(@"[CAMERA] URL atual armazenada: %@", self.currentURL.absoluteString);
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
    [[MJPEGReader sharedInstance] setProcessingMode:MJPEGReaderProcessingModeDefault];
    
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

// Método otimizado para substituir o buffer da câmera com um buffer de MJPEG
+ (CMSampleBufferRef)replaceCameraSampleBuffer:(CMSampleBufferRef)originalBuffer withMJPEGBuffer:(CMSampleBufferRef)mjpegBuffer {
    // Verificações de segurança
    if (!mjpegBuffer || !CMSampleBufferIsValid(mjpegBuffer)) {
        return originalBuffer;
    }
    
    if (!originalBuffer || !CMSampleBufferIsValid(originalBuffer)) {
        // Se não tivermos buffer original válido, retornar uma cópia do MJPEG
        CMSampleBufferRef resultBuffer = NULL;
        OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, mjpegBuffer, &resultBuffer);
        
        if (status == noErr && resultBuffer != NULL) {
            return resultBuffer;
        } else {
            // Se falhar, retornar o mjpegBuffer com retain
            CFRetain(mjpegBuffer);
            return mjpegBuffer;
        }
    }
    
    // Extrair informações importantes do buffer original
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(originalBuffer);
    CMTime duration = CMSampleBufferGetDuration(originalBuffer);
    
    // Verificar se os tempos são válidos
    if (!CMTIME_IS_VALID(presentationTime)) {
        presentationTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 90000);
    }
    
    if (!CMTIME_IS_VALID(duration)) {
        duration = CMTimeMake(1, 30); // Assumindo 30 fps
    }
    
    // Criar timing info
    CMSampleTimingInfo timing = {
        .duration = duration,
        .presentationTimeStamp = presentationTime,
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    // Criar cópia do buffer com o timing correto
    CMSampleBufferRef resultBuffer = NULL;
    OSStatus status = CMSampleBufferCreateCopyWithNewTiming(
        kCFAllocatorDefault,
        mjpegBuffer,
        1,
        &timing,
        &resultBuffer
    );
    
    if (status != noErr || resultBuffer == NULL) {
        // Se falhar, retornar o buffer original
        return originalBuffer;
    }
    
    // Transferir todos os metadados importantes do buffer original
    NSDictionary *metadataKeys = @{
        // Orientação de vídeo
        (id)CFSTR("VideoOrientation"): @"Orientação",
        
        // Informações de colorimetria
        (id)CFSTR("CVImageBufferYCbCrMatrix"): @"Matriz YCbCr",
        (id)CFSTR("CVImageBufferColorPrimaries"): @"Primárias de cor",
        (id)CFSTR("CVImageBufferTransferFunction"): @"Função de transferência",
        
        // Informações de campo de vídeo
        (id)CFSTR("CVFieldCount"): @"Contagem de campos",
        (id)CFSTR("CVFieldDetail"): @"Detalhe de campo",
        
        // Informações de hardware
        (id)CFSTR("CameraIntrinsicMatrix"): @"Matriz intrínseca",
        
        // Timestamps
        (id)CFSTR("FrameTimeStamp"): @"Timestamp do frame"
    };
    
    // Transferir todos os metadados existentes
    for (NSString *key in metadataKeys.allKeys) {
        CFTypeRef attachment = CMGetAttachment(originalBuffer, (CFStringRef)key, NULL);
        if (attachment) {
            CMSetAttachment(resultBuffer, (CFStringRef)key, attachment, kCMAttachmentMode_ShouldPropagate);
        }
    }
    
    // Se o buffer original tem informações de orientação, transferi-las
    CFTypeRef orientationAttachment = CMGetAttachment(originalBuffer, CFSTR("VideoOrientation"), NULL);
    if (orientationAttachment) {
        CMSetAttachment(resultBuffer, CFSTR("VideoOrientation"),
                      orientationAttachment, kCMAttachmentMode_ShouldPropagate);
    } else if (g_isVideoOrientationSet) {
        // Se não tem orientação no buffer original, mas temos a orientação global
        uint32_t orientation = g_videoOrientation;
        CFNumberRef orientationValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &orientation);
        if (orientationValue) {
            CMSetAttachment(resultBuffer, CFSTR("VideoOrientation"), orientationValue, kCMAttachmentMode_ShouldPropagate);
            CFRelease(orientationValue);
        }
    }
    
    // Cópia exata dos attachments do formato para garantir compatibilidade total
    CMFormatDescriptionRef origFormatDesc = CMSampleBufferGetFormatDescription(originalBuffer);
    CMFormatDescriptionRef newFormatDesc = CMSampleBufferGetFormatDescription(resultBuffer);

    if (origFormatDesc && newFormatDesc) {
        // Verificar e preservar extensões críticas para codecs de vídeo
        CFDictionaryRef origExtensions = CMFormatDescriptionGetExtensions(origFormatDesc);
        if (origExtensions) {
            // Copiar extensões individualmente já que não podemos copiar o dicionário inteiro
            CFStringRef keys[] = {
                CFSTR("FormatDescriptionExtensionMaxKeyLengthKey"),
                CFSTR("FormatDescriptionExtensionWaveFormatKey"),
                CFSTR("FormatDescriptionExtensionTokenKey"),
                CFSTR("FormatDescriptionExtensionVerticalBlankingKey"),
                CFSTR("FormatDescriptionExtensionCleanApertureKey"),
                CFSTR("FormatDescriptionExtensionFieldCountKey"),
                CFSTR("FormatDescriptionExtensionFieldDetailKey"),
                CFSTR("FormatDescriptionExtensionPixelAspectRatioKey"),
                CFSTR("FormatDescriptionExtensionColorPrimariesKey"),
                CFSTR("FormatDescriptionExtensionTransferFunctionKey"),
                CFSTR("FormatDescriptionExtensionYCbCrMatrixKey"),
                CFSTR("FormatDescriptionExtensionChromaLocationKey"),
                CFSTR("FormatDescriptionExtensionCodecSpecificKey")
            };
            
            for (int i = 0; i < sizeof(keys)/sizeof(keys[0]); i++) {
                CFTypeRef value = CFDictionaryGetValue(origExtensions, keys[i]);
                if (value) {
                    // Não podemos usar CMSetFormatDescriptionExtension diretamente
                    // Logando apenas para debug
                    if (keys[i]) {
                        writeLog(@"[CAMERA] Encontrada extensão de formato que não pode ser copiada: %@", keys[i]);
                    }
                }
            }
        }
    }
    
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
        
        // Obter buffer de substituição - modo de alta qualidade para fotos
        [[MJPEGReader sharedInstance] setProcessingMode:MJPEGReaderProcessingModeHighQuality];
        CMSampleBufferRef mjpegBuffer = photoSampleBuffer ? [GetFrame getCurrentFrame:photoSampleBuffer replace:YES] : nil;
        [[MJPEGReader sharedInstance] setProcessingMode:MJPEGReaderProcessingModeDefault];
        
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
