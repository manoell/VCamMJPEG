#import "GetFrame.h"
#import "logger.h"

// Variáveis globais para gerenciamento do buffer de frame atual
static CMSampleBufferRef g_lastReceivedBuffer = NULL;
static BOOL g_isFrameReady = NO;

// Mutex para acesso thread-safe às variáveis compartilhadas
static NSLock *bufferLock = nil;

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
    if (++callCount % 200 == 0) {
        writeLog(@"[GETFRAME] getCurrentFrame chamado %d vezes", callCount);
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
                if (callCount % 300 == 0) {
                    writeLog(@"[GETFRAME] Retornando buffer MJPEG válido para substituição");
                }
                
                // Se o inputBuffer for válido, precisamos copiar propriedades importantes
                if (inputBuffer != NULL && CMSampleBufferIsValid(inputBuffer)) {
                    @try {
                        // Copiar timestamp de apresentação para manter sincronização
                        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(inputBuffer);
                        
                        // Anexar timestamp como metadado
                        CMSetAttachment(resultBuffer, CFSTR("FrameTimeStamp"),
                                      (__bridge CFTypeRef)@(CMTimeGetSeconds(presentationTime)),
                                      kCMAttachmentMode_ShouldPropagate);
                        
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
                
                // O chamador deve liberar este buffer quando terminar
                [bufferLock unlock];
                return resultBuffer;
            }
        }
    } @catch (NSException *exception) {
        writeLog(@"[GETFRAME] Exceção em getCurrentFrame: %@", exception);
    }
    
    [bufferLock unlock];
    
    // Se chegamos aqui, não temos um buffer válido para substituição
    if (callCount % 300 == 0) {
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
                CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
                image = [UIImage imageWithCIImage:ciImage];
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
            if (++frameCount % 300 == 0) {
                writeLog(@"[GETFRAME] Novo frame MJPEG #%d processado e pronto para substituição", frameCount);
                
                // Log de dimensões
                size_t width = CVPixelBufferGetWidth(imageBuffer);
                size_t height = CVPixelBufferGetHeight(imageBuffer);
                writeLog(@"[GETFRAME] Dimensões do frame: %zu x %zu", width, height);
            }
        } else {
            writeLog(@"[GETFRAME] Erro ao copiar sample buffer: %d", (int)status);
        }
    } @catch (NSException *e) {
        writeLog(@"[GETFRAME] Exceção ao processar frame MJPEG: %@", e);
    }
    [bufferLock unlock];
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
