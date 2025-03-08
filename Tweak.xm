#import "Tweak.h"
#import <notify.h>

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

// Manipulador de notificação de ativação
static void handleActivateNotification(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // Não ativar no SpringBoard
    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
        writeLog(@"[NOTIFY] Ignorando ativação no SpringBoard");
        return;
    }
    
    writeLog(@"[NOTIFY] Recebida notificação para ativar câmera virtual");
    
    // Verificar se o sistema está habilitado nos NSUserDefaults
    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"VCamMJPEG_Enabled"];
    if (!isEnabled) {
        writeLog(@"[NOTIFY] Sistema não está habilitado nos NSUserDefaults");
        return;
    }
    
    // Obter a URL do servidor
    NSString *serverURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"VCamMJPEG_ServerURL"];
    if (!serverURL) {
        writeLog(@"[NOTIFY] URL do servidor não encontrada");
        return;
    }
    
    // Ativar o VirtualCameraController
    writeLog(@"[NOTIFY] Ativando VirtualCameraController com URL: %@", serverURL);
    dispatch_async(dispatch_get_main_queue(), ^{
        VirtualCameraController *controller = [VirtualCameraController sharedInstance];
        [controller startCapturing];
        
        // Conectar ao servidor MJPEG
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        [reader startStreamingFromURL:[NSURL URLWithString:serverURL]];
    });
}

// Manipulador de notificação de desativação
static void handleDeactivateNotification(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // Não desativar no SpringBoard
    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
        writeLog(@"[NOTIFY] Ignorando desativação no SpringBoard");
        return;
    }
    
    writeLog(@"[NOTIFY] Recebida notificação para desativar câmera virtual");
    
    // Desativar o VirtualCameraController
    dispatch_async(dispatch_get_main_queue(), ^{
        VirtualCameraController *controller = [VirtualCameraController sharedInstance];
        [controller stopCapturing];
        
        // Parar o streaming MJPEG
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        [reader stopStreaming];
    });
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
        
        // Registrar para notificações Darwin - em todos os processos
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            handleActivateNotification,
            CFSTR("com.vcam.mjpeg.activate"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
            
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            handleDeactivateNotification,
            CFSTR("com.vcam.mjpeg.deactivate"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        
        // Verificar se o sistema já está habilitado - mas não no SpringBoard
        if (![processName isEqualToString:@"SpringBoard"]) {
            BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"VCamMJPEG_Enabled"];
            if (isEnabled) {
                writeLog(@"[INIT] Sistema já está habilitado, tentando ativar...");
                NSString *serverURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"VCamMJPEG_ServerURL"];
                if (serverURL) {
                    writeLog(@"[INIT] Usando URL salva: %@", serverURL);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        // Chamar diretamente para evitar problemas de compatibilidade de assinatura
                        handleActivateNotification(NULL, NULL, NULL, NULL, NULL);
                    });
                }
            }
        }
        
        // Mostrar a janela de preview apenas no SpringBoard
        if ([processName isEqualToString:@"SpringBoard"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                writeLog(@"[INIT] Mostrando janela de preview em SpringBoard");
                [[MJPEGPreviewWindow sharedInstance] show];
                
                // Verificar se o sistema está habilitado e atualizar o botão
                BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"VCamMJPEG_Enabled"];
                if (isEnabled) {
                    MJPEGPreviewWindow *window = [MJPEGPreviewWindow sharedInstance];
                    window.isConnected = YES;
                    [window.connectButton setTitle:@"Desativar Câmera Virtual" forState:UIControlStateNormal];
                    [window.connectButton setBackgroundColor:[UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.9]];
                    [window updateStatus:@"VirtualCam\nAtivo"];
                }
            });
        }
        
        // Inicializar os grupos padrão - sem hooks específicos neste arquivo
        %init(_ungrouped);
    }
}
