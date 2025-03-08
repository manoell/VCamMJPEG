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
    // Resolução padrão caso falhe a detecção automática
    g_originalFrontCameraResolution = CGSizeMake(960, 1280); // iPhone 7/8 Front
    g_originalBackCameraResolution = CGSizeMake(1080, 1920); // iPhone 7/8 Back
    
    // A detecção real ocorre via hooks em AVCaptureDevice em CameraHooks.xm
    writeLog(@"[INIT] Configurando resoluções de câmera padrão: Front %@, Back %@",
             NSStringFromCGSize(g_originalFrontCameraResolution),
             NSStringFromCGSize(g_originalBackCameraResolution));
}

// Constructor - roda quando o tweak é carregado
%ctor {
    @autoreleasepool {
        // Restaurar nível de log para ajudar no debug
        setLogLevel(5); // Mudando para nível DEBUG
        
        NSString *processName = [NSProcessInfo processInfo].processName;
        writeLog(@"[INIT] VirtualCam MJPEG carregado em processo: %@", processName);
        
        // Inicializar resoluções da câmera
        detectCameraResolutions();
        
        // Inicializar o sharedInstance, mas não ativar automaticamente
        [VirtualCameraController sharedInstance];
        
        // Garantir que o tweak começa desativado nos NSUserDefaults (importante!)
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"VCamMJPEG_Enabled"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // Mostrar a janela de preview apenas no SpringBoard
        if ([processName isEqualToString:@"SpringBoard"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                writeLog(@"[INIT] Mostrando janela de preview em SpringBoard");
                [[MJPEGPreviewWindow sharedInstance] show];
            });
        }
    }
}
