#import "GetFrame.h"
#import "logger.h"
#import "Globals.h"

// Variáveis globais para gerenciamento do buffer de frame atual
static CMSampleBufferRef g_lastReceivedBuffer = NULL;
static BOOL g_isFrameReady = NO;

// Queue para acesso thread-safe às variáveis compartilhadas (mais eficiente que NSLock)
static dispatch_queue_t g_bufferAccessQueue = NULL;

// Cache de performance
static CMFormatDescriptionRef g_cachedFormatDescription = NULL;

// Variáveis para armazenar informações sobre o último frame processado
static size_t g_lastFrameWidth = 0;
static size_t g_lastFrameHeight = 0;
static int g_successfulReplacements = 0;
static int g_failedReplacements = 0;

// Timestamp do último frame processado
static CFAbsoluteTime g_lastFrameTimestamp = 0;

// Dados adicionais para otimização de vídeo
static NSMutableArray *g_videoFrameCache = nil;
static const int kVideoFrameCacheMaxSize = 5; // 5 frames para cachear

@implementation GetFrame

+ (instancetype)sharedInstance {
    static GetFrame *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        // Inicializar a queue para acesso seguro
        static dispatch_once_t queueOnceToken;
        dispatch_once(&queueOnceToken, ^{
            g_bufferAccessQueue = dispatch_queue_create("com.vcam.buffer.access", DISPATCH_QUEUE_SERIAL);
            g_videoFrameCache = [NSMutableArray arrayWithCapacity:kVideoFrameCacheMaxSize];
        });
    }
    return self;
}

// Método principal para substituir frames - redesenhado para ser mais seguro e eficiente
+ (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)inputBuffer replace:(BOOL)replace {
    static int callCount = 0;
    
    // Log limitado para não afetar a performance
    if (++callCount % 500 == 0) {
        writeLog(@"[GETFRAME] getCurrentFrame chamado %d vezes (sucesso: %d, falhas: %d)",
                callCount, g_successfulReplacements, g_failedReplacements);
    }
    
    __block CMSampleBufferRef resultBuffer = NULL;
    
    // Usar dispatch_sync para garantir acesso exclusivo atômico, melhor que locks
    dispatch_sync(g_bufferAccessQueue, ^{
        // Verificar se temos um buffer válido para substituição
        if (g_lastReceivedBuffer != NULL && CMSampleBufferIsValid(g_lastReceivedBuffer)) {
            // Criar uma cópia do buffer para o chamador
            OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, g_lastReceivedBuffer, &resultBuffer);
            
            if (status == noErr && resultBuffer != NULL) {
                if (callCount % 500 == 0) {
                    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(resultBuffer);
                    if (imageBuffer) {
                        size_t width = CVPixelBufferGetWidth(imageBuffer);
                        size_t height = CVPixelBufferGetHeight(imageBuffer);
                        writeLog(@"[GETFRAME] Retornando buffer MJPEG válido: %zu x %zu", width, height);
                    }
                }
                
                // Se temos um buffer válido e o inputBuffer também é válido, vamos sincronizar os metadados
                if (replace && inputBuffer != NULL && CMSampleBufferIsValid(inputBuffer)) {
                    @try {
                        // Copiar timestamp de apresentação para manter sincronização
                        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(inputBuffer);
                        CMTime duration = CMSampleBufferGetDuration(inputBuffer);
                        
                        // Verificar validade dos timestamps
                        if (!CMTIME_IS_VALID(presentationTime)) {
                            presentationTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 90000);
                        }
                        
                        if (!CMTIME_IS_VALID(duration)) {
                            duration = CMTimeMake(1, 30); // Assumindo 30 fps
                        }
                        
                        // Criar timing info baseado no inputBuffer
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
                            
                            // Transferir todos os metadados importantes do inputBuffer
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
                                CFTypeRef attachment = CMGetAttachment(inputBuffer, (CFStringRef)key, NULL);
                                if (attachment) {
                                    CMSetAttachment(resultBuffer, (CFStringRef)key, attachment, kCMAttachmentMode_ShouldPropagate);
                                }
                            }
                        }
                        
                        // Anexar timestamp como metadado
                        CMSetAttachment(resultBuffer, CFSTR("FrameTimeStamp"),
                                      (__bridge CFTypeRef)@(CMTimeGetSeconds(presentationTime)),
                                      kCMAttachmentMode_ShouldPropagate);
                        
                        // Verificar orientação no buffer original
                        CFTypeRef orientationAttachment = CMGetAttachment(inputBuffer, CFSTR("VideoOrientation"), NULL);
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
                        
                    } @catch (NSException *e) {
                        writeLog(@"[GETFRAME] Erro ao copiar metadados: %@", e);
                    }
                }
                
                // Incrementar contador de substituições bem-sucedidas
                g_successfulReplacements++;
                
                // O chamador deve liberar este buffer quando terminar
                return;
            }
        }
    });
    
    // Se não conseguimos criar o buffer, incrementar falhas
    if (resultBuffer == NULL) {
        g_failedReplacements++;
        
        if (callCount % 500 == 0) {
            writeLog(@"[GETFRAME] Nenhum buffer disponível para substituição");
        }
    }
    
    return resultBuffer;
}

// Método para obter a imagem para exibição na UI - com tratamento de erros e cache
- (UIImage *)getDisplayImage {
    __block UIImage *image = nil;
    
    dispatch_sync(g_bufferAccessQueue, ^{
        @try {
            if (g_lastReceivedBuffer != NULL && CMSampleBufferIsValid(g_lastReceivedBuffer)) {
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(g_lastReceivedBuffer);
                if (imageBuffer) {
                    // Bloquear buffer para leitura segura
                    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
                    
                    // Criar CIImage e depois UIImage
                    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
                    if (ciImage) {
                        CIContext *context = [CIContext contextWithOptions:nil];
                        CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                        
                        if (cgImage) {
                            // Definir orientação baseada na orientação global
                            UIImageOrientation orientation = UIImageOrientationUp;
                            if (g_isVideoOrientationSet) {
                                switch (g_videoOrientation) {
                                    case 1: orientation = UIImageOrientationUp; break;
                                    case 2: orientation = UIImageOrientationDown; break;
                                    case 3: orientation = UIImageOrientationLeft; break;
                                    case 4: orientation = UIImageOrientationRight; break;
                                }
                            }
                            
                            image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:orientation];
                            CGImageRelease(cgImage);
                        }
                    }
                    
                    // Desbloquear buffer
                    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
                }
            }
        } @catch (NSException *e) {
            writeLog(@"[GETFRAME] Erro ao obter imagem de exibição: %@", e);
        }
    });
    
    return image;
}

// Método para processar um novo frame MJPEG - otimizado para performance
- (void)processNewMJPEGFrame:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer == NULL || !CMSampleBufferIsValid(sampleBuffer)) {
        return;
    }
    
    // Garantir que o buffer tenha uma imagem
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer == NULL) {
        writeLog(@"[GETFRAME] Frame MJPEG sem imagem válida, ignorando");
        return;
    }
    
    // Verificar a resolução do frame MJPEG
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    // Verificar proporção e dimensões do frame vs câmera real
    BOOL aspectRatioMismatch = NO;
    
    if (!CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero)) {
        // Verificar proporção do frame MJPEG vs câmera real
        CGFloat mjpegRatio = (CGFloat)width / (CGFloat)height;
        CGFloat cameraRatio = g_originalCameraResolution.width / g_originalCameraResolution.height;
        
        // Se a diferença de proporção for significativa
        if (fabs(mjpegRatio - cameraRatio) > 0.05) {
            aspectRatioMismatch = YES;
            static BOOL loggedAspectWarning = NO;
            if (!loggedAspectWarning) {
                writeLog(@"[GETFRAME] Aviso: Proporção de aspecto do MJPEG (%.2f) difere da câmera (%.2f)",
                        mjpegRatio, cameraRatio);
                loggedAspectWarning = YES;
            }
        }
        
        // Se as dimensões forem diferentes da câmera real
        if (width != g_originalCameraResolution.width || height != g_originalCameraResolution.height) {
            if (g_lastFrameWidth != width || g_lastFrameHeight != height) {
                writeLog(@"[GETFRAME] Dimensões do frame MJPEG: %zu x %zu, câmera real: %.0f x %.0f",
                        width, height, g_originalCameraResolution.width, g_originalCameraResolution.height);
                
                g_lastFrameWidth = width;
                g_lastFrameHeight = height;
            }
        }
    }
    
    // Tratamento atômico para substituição do buffer
    dispatch_sync(g_bufferAccessQueue, ^{
        @try {
            // Caso 1: Precisamos redimensionar/ajustar o buffer devido a incompatibilidade de proporção
            if (aspectRatioMismatch && !CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero) && g_isRecordingVideo) {
                // Criar um buffer ajustado com o tamanho da câmera real - seria implementado aqui
                // Por ora, apenas usamos o buffer original
            }
            
            // Liberar o buffer anterior
            if (g_lastReceivedBuffer != NULL) {
                CFRelease(g_lastReceivedBuffer);
                g_lastReceivedBuffer = NULL;
            }
            
            // Armazenar o novo buffer (fazer uma cópia para evitar problemas de liberação)
            OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &g_lastReceivedBuffer);
            
            if (status == noErr && g_lastReceivedBuffer != NULL) {
                g_isFrameReady = YES;
                g_lastFrameTimestamp = CFAbsoluteTimeGetCurrent();
                
                // Cache para video se estiver gravando
                if (g_isRecordingVideo && g_videoFrameCache != nil) {
                    // Manter o cache limitado
                    while (g_videoFrameCache.count >= kVideoFrameCacheMaxSize) {
                        CMSampleBufferRef oldBuffer = (__bridge CMSampleBufferRef)[g_videoFrameCache firstObject];
                        [g_videoFrameCache removeObjectAtIndex:0];
                        if (oldBuffer) {
                            CFRelease(oldBuffer);
                        }
                    }
                    
                    // Adicionar cópia do buffer atual ao cache
                    CMSampleBufferRef cacheCopy = NULL;
                    if (CMSampleBufferCreateCopy(kCFAllocatorDefault, g_lastReceivedBuffer, &cacheCopy) == noErr) {
                        [g_videoFrameCache addObject:(__bridge id)cacheCopy];
                    }
                }
                
                static int frameCount = 0;
                if (++frameCount % 500 == 0) {
                    writeLog(@"[GETFRAME] Novo frame MJPEG #%d processado: %zu x %zu",
                            frameCount, width, height);
                }
            } else {
                writeLog(@"[GETFRAME] Erro ao copiar sample buffer: %d", (int)status);
            }
        } @catch (NSException *e) {
            writeLog(@"[GETFRAME] Exceção ao processar frame MJPEG: %@", e);
        }
    });
}

// Método para criar um CMSampleBuffer a partir de dados JPEG - otimizado para alta fidelidade
- (CMSampleBufferRef)createSampleBufferFromJPEGData:(NSData *)jpegData withSize:(CGSize)size {
    if (!jpegData || jpegData.length == 0) {
        writeLog(@"[MJPEG] Dados JPEG inválidos");
        return NULL;
    }
    
    // Criar um CGImage a partir dos dados JPEG
    CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, jpegData.bytes, jpegData.length, NULL);
    CGImageRef cgImage = CGImageCreateWithJPEGDataProvider(dataProvider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(dataProvider);
    
    if (cgImage == NULL) {
        writeLog(@"[MJPEG] Falha ao criar CGImage");
        return NULL;
    }
    
    // Criar um CVPixelBuffer
    CVPixelBufferRef pixelBuffer = NULL;
    
    // Especificar propriedades do buffer para melhor compatibilidade
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        // Propriedade para otimizar performance
        (id)kCVPixelBufferPoolAllocationThresholdKey: @6
    };
    
    // Obter as dimensões corretas da imagem
    CGFloat imageWidth = CGImageGetWidth(cgImage);
    CGFloat imageHeight = CGImageGetHeight(cgImage);
    
    // Usar as dimensões da imagem caso não tenha sido especificado
    if (size.width <= 0 || size.height <= 0) {
        size = CGSizeMake(imageWidth, imageHeight);
    }
    
    // Criar pixel buffer vazio
    CVReturn cvReturn = CVPixelBufferCreate(kCFAllocatorDefault,
                                          size.width,
                                          size.height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)options,
                                          &pixelBuffer);
    
    if (cvReturn != kCVReturnSuccess) {
        writeLog(@"[MJPEG] Falha ao criar CVPixelBuffer: %d", cvReturn);
        CGImageRelease(cgImage);
        return NULL;
    }
    
    // Bloquear o buffer para escrita
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    // Obter o ponteiro para os dados do buffer
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    // Configurar contexto para desenhar a imagem no buffer
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(baseAddress,
                                              size.width,
                                              size.height,
                                              8,
                                              bytesPerRow,
                                              colorSpace,
                                              kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    
    if (context == NULL) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        CGImageRelease(cgImage);
        writeLog(@"[MJPEG] Falha ao criar contexto de bitmap");
        return NULL;
    }
    
    // Limpar o contexto para evitar artefatos
    CGContextClearRect(context, CGRectMake(0, 0, size.width, size.height));
    
    // Configurar alta qualidade de interpolação
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    
    // Desenhar a imagem no contexto com a orientação correta
    CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), cgImage);
    
    // Liberar recursos
    CGContextRelease(context);
    CGImageRelease(cgImage);
    
    // Desbloquear o buffer
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    // Verificar se temos uma descrição de formato em cache
    CMFormatDescriptionRef formatDescription = NULL;
    
    if (g_cachedFormatDescription) {
        // Reutilizar o formato em cache se as dimensões forem iguais
        CMVideoDimensions cachedDims = CMVideoFormatDescriptionGetDimensions(g_cachedFormatDescription);
        if (cachedDims.width == size.width && cachedDims.height == size.height) {
            formatDescription = g_cachedFormatDescription;
            CFRetain(formatDescription);
        }
    }
    
    // Criar nova descrição de formato se necessário
    if (formatDescription == NULL) {
        CVReturn status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
        
        if (status != noErr) {
            CVPixelBufferRelease(pixelBuffer);
            writeLog(@"[MJPEG] Falha ao criar descrição de formato: %d", status);
            return NULL;
        }
        
        // Atualizar o cache de formato
        if (g_cachedFormatDescription) {
            CFRelease(g_cachedFormatDescription);
        }
        g_cachedFormatDescription = formatDescription;
        CFRetain(g_cachedFormatDescription);
    }
    
    // Criar uma referência de tempo precisa para o sample buffer
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, 30); // 30 fps
    timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000);
    timing.decodeTimeStamp = kCMTimeInvalid;
    
    // Criar o sample buffer final
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        true,
        NULL,
        NULL,
        formatDescription,
        &timing,
        &sampleBuffer
    );
    
    // Liberar recursos
    CFRelease(formatDescription);
    CVPixelBufferRelease(pixelBuffer);
    
    if (status != noErr || !sampleBuffer) {
        writeLog(@"[MJPEG] Falha ao criar sample buffer: %d", status);
        return NULL;
    }
    
    // Log para depuração
    static int sampleBufferCount = 0;
    if (sampleBufferCount++ % 300 == 0) {
        writeLog(@"[MJPEG] SampleBuffer #%d criado com sucesso (dimensões: %.0f x %.0f)",
                sampleBufferCount, size.width, size.height);
    }
    
    // Adicionar metadados padrão para melhorar compatibilidade
    if (g_isVideoOrientationSet) {
        uint32_t orientation = g_videoOrientation;
        CFNumberRef orientationValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &orientation);
        if (orientationValue) {
            CMSetAttachment(sampleBuffer, CFSTR("VideoOrientation"), orientationValue, kCMAttachmentMode_ShouldPropagate);
            CFRelease(orientationValue);
        }
    }
    
    return sampleBuffer;
}

// Liberar recursos ao descarregar o tweak
+ (void)cleanupResources {
    dispatch_sync(g_bufferAccessQueue, ^{
        if (g_lastReceivedBuffer != NULL) {
            CFRelease(g_lastReceivedBuffer);
            g_lastReceivedBuffer = NULL;
        }
        
        if (g_cachedFormatDescription != NULL) {
            CFRelease(g_cachedFormatDescription);
            g_cachedFormatDescription = NULL;
        }
        
        // Limpar o cache de frames de vídeo
        for (id buffer in g_videoFrameCache) {
            CMSampleBufferRef sampleBuffer = (__bridge CMSampleBufferRef)buffer;
            if (sampleBuffer) {
                CFRelease(sampleBuffer);
            }
        }
        [g_videoFrameCache removeAllObjects];
        
        g_isFrameReady = NO;
    });
    
    writeLog(@"[GETFRAME] Recursos liberados");
}

// Novo método para otimizar frames de vídeo
+ (void)flushVideoBuffers {
    dispatch_sync(g_bufferAccessQueue, ^{
        // Limpar o cache de frames de vídeo
        for (id buffer in g_videoFrameCache) {
            CMSampleBufferRef sampleBuffer = (__bridge CMSampleBufferRef)buffer;
            if (sampleBuffer) {
                CFRelease(sampleBuffer);
            }
        }
        [g_videoFrameCache removeAllObjects];
    });
}

@end
