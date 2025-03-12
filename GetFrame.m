#import "GetFrame.h"
#import "logger.h"
#import "Globals.h"

// Variáveis globais para gerenciamento do buffer de frame atual
static CMSampleBufferRef g_lastReceivedBuffer = NULL;
static BOOL g_isFrameReady = NO;

// Mutex para acesso thread-safe às variáveis compartilhadas
static NSLock *bufferLock = nil;

// Variáveis para armazenar informações sobre o último frame processado
static size_t g_lastFrameWidth = 0;
static size_t g_lastFrameHeight = 0;
static int g_successfulReplacements = 0;
static int g_failedReplacements = 0;

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
        // Inicializar o mutex se necessário
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            bufferLock = [[NSLock alloc] init];
        });
    }
    return self;
}

// Método principal para substituir frames - redesenhado para ser mais seguro
+ (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)inputBuffer replace:(BOOL)replace {
    static int callCount = 0;
    
    // Log limitado
    if (++callCount % 500 == 0) {
        writeLog(@"[GETFRAME] getCurrentFrame chamado %d vezes (sucesso: %d, falhas: %d)",
                callCount, g_successfulReplacements, g_failedReplacements);
    }
    
    // Obter acesso exclusivo ao buffer compartilhado
    [bufferLock lock];
    
    @try {
        // Verificar se temos um buffer válido para substituição
        if (g_lastReceivedBuffer != NULL && CMSampleBufferIsValid(g_lastReceivedBuffer)) {
            // Criar uma cópia do buffer para o chamador
            CMSampleBufferRef resultBuffer = NULL;
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
                
                // Se o inputBuffer for válido, precisamos copiar propriedades importantes
                if (inputBuffer != NULL && CMSampleBufferIsValid(inputBuffer)) {
                    @try {
                        // Copiar timestamp de apresentação para manter sincronização
                        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(inputBuffer);
                        CMTime duration = CMSampleBufferGetDuration(inputBuffer);
                        
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
                        }
                        
                        // Transferir outros metadados importantes se existirem
                        CFTypeRef exifData = CMGetAttachment(inputBuffer, CFSTR("{Exif}"), NULL);
                        if (exifData) {
                            CMSetAttachment(resultBuffer, CFSTR("{Exif}"), exifData, kCMAttachmentMode_ShouldPropagate);
                        }
                        
                        CFTypeRef tiffData = CMGetAttachment(inputBuffer, CFSTR("{TIFF}"), NULL);
                        if (tiffData) {
                            CMSetAttachment(resultBuffer, CFSTR("{TIFF}"), tiffData, kCMAttachmentMode_ShouldPropagate);
                        }
                    } @catch (NSException *e) {
                        writeLog(@"[GETFRAME] Erro ao copiar metadados: %@", e);
                    }
                }
                
                // Incrementar contador de substituições bem-sucedidas
                g_successfulReplacements++;
                
                // O chamador deve liberar este buffer quando terminar
                [bufferLock unlock];
                return resultBuffer;
            }
        }
    } @catch (NSException *exception) {
        writeLog(@"[GETFRAME] Exceção em getCurrentFrame: %@", exception);
    }
    
    [bufferLock unlock];
    
    // Incrementar contador de falhas
    g_failedReplacements++;
    
    // Se chegamos aqui, não temos um buffer válido para substituição
    if (callCount % 500 == 0) {
        writeLog(@"[GETFRAME] Nenhum buffer disponível para substituição");
    }
    
    return NULL;
}

// Método para obter a imagem para exibição na UI - com tratamento de erros
- (UIImage *)getDisplayImage {
    UIImage *image = nil;
    
    [bufferLock lock];
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
    [bufferLock unlock];
    
    return image;
}

// Método para processar um novo frame MJPEG
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
    
    // Verificar se precisamos adaptar a resolução para corresponder à câmera do dispositivo
    // Removido: BOOL needsResizing = NO;
    
    if (!CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero)) {
        // Verificar proporção do frame MJPEG vs câmera real
        CGFloat mjpegRatio = (CGFloat)width / (CGFloat)height;
        CGFloat cameraRatio = g_originalCameraResolution.width / g_originalCameraResolution.height;
        
        // Se a diferença de proporção for significativa
        if (fabs(mjpegRatio - cameraRatio) > 0.05) {
            static BOOL loggedAspectWarning = NO;
            if (!loggedAspectWarning) {
                writeLog(@"[GETFRAME] Aviso: Proporção de aspecto do MJPEG (%.2f) difere da câmera (%.2f)",
                        mjpegRatio, cameraRatio);
                loggedAspectWarning = YES;
            }
        }
        
        // Se as dimensões forem muito diferentes da câmera real, redimensionar pode ser necessário
        // Esta verificação é opcional - pode ser desativada se causar problemas de desempenho
        if (width != g_originalCameraResolution.width || height != g_originalCameraResolution.height) {
            // Por enquanto, apenas logamos - implementação real de redimensionamento seria aqui
            if (g_lastFrameWidth != width || g_lastFrameHeight != height) {
                writeLog(@"[GETFRAME] Dimensões do frame MJPEG: %zu x %zu, câmera real: %.0f x %.0f",
                        width, height, g_originalCameraResolution.width, g_originalCameraResolution.height);
                
                g_lastFrameWidth = width;
                g_lastFrameHeight = height;
            }
        }
    }
    
    [bufferLock lock];
    @try {
        // Liberar o buffer anterior
        if (g_lastReceivedBuffer != NULL) {
            CFRelease(g_lastReceivedBuffer);
            g_lastReceivedBuffer = NULL;
        }
        
        // Armazenar o novo buffer (fazer uma cópia para evitar problemas de liberação)
        OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &g_lastReceivedBuffer);
        
        if (status == noErr && g_lastReceivedBuffer != NULL) {
            g_isFrameReady = YES;
            
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
    [bufferLock unlock];
}

// Método para criar um CMSampleBuffer a partir de dados JPEG
- (CMSampleBufferRef)createSampleBufferFromJPEGData:(NSData *)jpegData withSize:(CGSize)size {
    if (!jpegData || jpegData.length == 0) {
        writeLog(@"[MJPEG] Dados JPEG inválidos");
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
        // Adicionar propriedade para otimizar performance
        (id)kCVPixelBufferPoolAllocationThresholdKey: @6
    };
    
    // Criar pixel buffer vazio
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                        size.width,
                                        size.height,
                                        kCVPixelFormatType_32BGRA,  // Formato mais compatível
                                        (__bridge CFDictionaryRef)options,
                                        &pixelBuffer);
    
    if (status != kCVReturnSuccess) {
        writeLog(@"[MJPEG] Falha ao criar CVPixelBuffer: %d", status);
        return NULL;
    }
    
    // Criar uma imagem CGImage a partir dos dados JPEG
    CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, jpegData.bytes, jpegData.length, NULL);
    CGImageRef cgImage = CGImageCreateWithJPEGDataProvider(dataProvider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(dataProvider);
    
    if (cgImage == NULL) {
        CVPixelBufferRelease(pixelBuffer);
        writeLog(@"[MJPEG] Falha ao criar CGImage");
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
    
    // Criar referência ao formato de vídeo
    CMFormatDescriptionRef formatDescription = NULL;
    status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    
    if (status != noErr) {
        CVPixelBufferRelease(pixelBuffer);
        writeLog(@"[MJPEG] Falha ao criar descrição de formato: %d", status);
        return NULL;
    }
    
    // Criar uma referência de tempo precisa para o sample buffer
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, 30); // 30 fps
    timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000);
    timing.decodeTimeStamp = kCMTimeInvalid;
    
    // Criar o sample buffer final
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(
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
    
    return sampleBuffer;
}

// Liberar recursos ao descarregar o tweak
+ (void)cleanupResources {
    [bufferLock lock];
    if (g_lastReceivedBuffer != NULL) {
        CFRelease(g_lastReceivedBuffer);
        g_lastReceivedBuffer = NULL;
    }
    g_isFrameReady = NO;
    [bufferLock unlock];
    
    writeLog(@"[GETFRAME] Recursos liberados");
}

@end
