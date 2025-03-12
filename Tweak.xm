#import "Tweak.h"

// Inicialização das variáveis globais
dispatch_queue_t g_processingQueue;
AVSampleBufferDisplayLayer *g_customDisplayLayer = nil;
CALayer *g_maskLayer = nil;
CADisplayLink *g_displayLink = nil;
NSString *g_tempFile = @"/tmp/vcam.mjpeg";
BOOL g_isVideoOrientationSet = NO;
int g_videoOrientation = 1; // Default orientation (portrait)
BOOL g_isCapturingPhoto = NO; // Flag para indicar captura de foto em andamento
BOOL g_isRecordingVideo = NO; // Flag para indicar gravação de vídeo em andamento
CGSize g_originalCameraResolution = CGSizeZero;
CGSize g_originalFrontCameraResolution = CGSizeZero;
CGSize g_originalBackCameraResolution = CGSizeZero;
BOOL g_usingFrontCamera = NO;

// Função para registro de delegados ativos
void logDelegates() {
    writeLog(@"[HOOK] Buscando delegados de câmera ativos...");
    
    NSArray *activeDelegateClasses = @[
        @"CAMCaptureEngine",
        @"PLCameraController",
        @"PLCaptureSession",
        @"SCCapture",
        @"TGCameraController",
        @"AVCaptureSession"
    ];
    
    for (NSString *className in activeDelegateClasses) {
        Class delegateClass = NSClassFromString(className);
        if (delegateClass) {
            writeLog(@"[HOOK] Encontrado delegado potencial: %@", className);
        }
    }
}

// Função para detectar dimensões das câmeras
void detectCameraResolutions() {
    // Configurar resoluções da câmera baseadas no diagnóstico
    g_originalFrontCameraResolution = CGSizeMake(1334, 750); // Baseado no diagnóstico
    g_originalBackCameraResolution = CGSizeMake(4032, 3024); // Baseado no diagnóstico
    
    // A detecção real ocorre via hooks em AVCaptureDevice em CameraHooks.xm
    writeLog(@"[INIT] Configurando resoluções de câmera: Front %@, Back %@",
             NSStringFromCGSize(g_originalFrontCameraResolution),
             NSStringFromCGSize(g_originalBackCameraResolution));
}

// Constructor - roda quando o tweak é carregado
%ctor {
    @autoreleasepool {
        setLogLevel(5); // Aumentado para nível DEBUG para mais detalhes
        
        NSString *processName = [NSProcessInfo processInfo].processName;
        writeLog(@"[INIT] VirtualCam MJPEG carregado em processo: %@", processName);
        
        // Inicializar resoluções da câmera
        detectCameraResolutions();
        
        // Inicialização única dos componentes principais
        VirtualCameraController *controller = [VirtualCameraController sharedInstance];
        
        // Verificar se estamos em um aplicativo que usa a câmera
        BOOL isCameraApp =
            ([processName isEqualToString:@"Camera"] ||
             [processName containsString:@"camera"] ||
             [processName isEqualToString:@"Telegram"] ||
             [processName isEqualToString:@"Facetime"] ||
             [processName containsString:@"facetime"] ||
             [processName isEqualToString:@"MobileSlideShow"]); // App de fotos
            
        if (isCameraApp) {
            writeLog(@"[INIT] Configurando hooks para app de câmera: %@", processName);
            // Iniciar controller após um pequeno delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [controller startCapturing];
            });
        }
        
        // Mostrar a janela de preview apenas no SpringBoard
        if ([processName isEqualToString:@"SpringBoard"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                writeLog(@"[INIT] Mostrando janela de preview em SpringBoard");
                [[MJPEGPreviewWindow sharedInstance] show];
            });
        }
        
        // Inicializar os grupos padrão - sem hooks específicos neste arquivo
        %init(_ungrouped);
    }
}
