#import "GetFrame.h"
#import "logger.h"

// Variáveis globais (baseadas no TTtest.dylib)
static CMSampleBufferRef g_lastReceivedBuffer = NULL;
static BOOL g_isFrameReady = NO;
static NSURL *g_streamURL = nil;

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
        g_streamURL = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
    }
    return self;
}

// Método principal para substituir frames - baseado diretamente no GetFrame::getCurrentFrame__
+ (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)inputBuffer replace:(BOOL)replace {
    static int callCount = 0;
    
    // Log limitado
    if (++callCount % 200 == 0) {
        writeLog(@"[GETFRAME] getCurrentFrame chamado %d vezes", callCount);
    }
    
    @synchronized(self) {
        // Verificar se temos um buffer válido para substituição
        if (g_lastReceivedBuffer != NULL && CMSampleBufferIsValid(g_lastReceivedBuffer)) {
            CMSampleBufferRef resultBuffer = (CMSampleBufferRef)CFRetain(g_lastReceivedBuffer);
            
            if (callCount % 300 == 0) {
                writeLog(@"[GETFRAME] Retornando buffer MJPEG válido para substituição");
            }
            
            return resultBuffer;
        }
    }
    
    // Se chegamos aqui, não temos um buffer válido para substituição
    if (callCount % 300 == 0) {
        writeLog(@"[GETFRAME] Nenhum buffer disponível para substituição");
    }
    
    return NULL;
}

// Método para obter a imagem para exibição na UI
- (UIImage *)getDisplayImage {
    if (g_lastReceivedBuffer != NULL && CMSampleBufferIsValid(g_lastReceivedBuffer)) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(g_lastReceivedBuffer);
        if (imageBuffer) {
            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
            return [UIImage imageWithCIImage:ciImage];
        }
    }
    return nil;
}

// Método para processar um novo frame MJPEG
- (void)processNewMJPEGFrame:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer == NULL || !CMSampleBufferIsValid(sampleBuffer)) {
        return;
    }
    
    @synchronized([self class]) {
        // Liberar o buffer anterior
        if (g_lastReceivedBuffer != NULL) {
            CFRelease(g_lastReceivedBuffer);
        }
        
        // Armazenar o novo buffer
        g_lastReceivedBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
        g_isFrameReady = YES;
        
        static int frameCount = 0;
        if (++frameCount % 300 == 0) {
            writeLog(@"[GETFRAME] Novo frame MJPEG #%d processado e pronto para substituição", frameCount);
            
            // Log de dimensões
            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(g_lastReceivedBuffer);
            if (imageBuffer) {
                size_t width = CVPixelBufferGetWidth(imageBuffer);
                size_t height = CVPixelBufferGetHeight(imageBuffer);
                writeLog(@"[GETFRAME] Dimensões do frame: %zu x %zu", width, height);
            }
        }
    }
}

@end
