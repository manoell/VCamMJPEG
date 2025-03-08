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
        
        // CORREÇÃO: Verificar se o tweak deve ser ativado pelos NSUserDefaults
        BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"VCamMJPEG_Enabled"];
        
        // Log do estado ao iniciar
        writeLog(@"[INIT] Estado inicial do tweak: isEnabled=%d, gGlobalReaderConnected=%d",
                 isEnabled, gGlobalReaderConnected);
        
        // CORREÇÃO: Remover a redefinição forçada para outros processos
        // Isso permite que a configuração seja mantida entre processos
        
        // Se estiver habilitado em NSUserDefaults, sincronizar com a variável global
        if (isEnabled && !gGlobalReaderConnected) {
            writeLog(@"[INIT] Sincronizando estado: NSUserDefaults indica ativado, atualizando gGlobalReaderConnected");
            gGlobalReaderConnected = YES;
        }
        
        // Mostrar a janela de preview apenas no SpringBoard
        if ([processName isEqualToString:@"SpringBoard"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                writeLog(@"[INIT] Mostrando janela de preview em SpringBoard");
                [[MJPEGPreviewWindow sharedInstance] show];
                
                // CORREÇÃO: Se o tweak estava ativado antes do respring, restaurar estado
                if (isEnabled) {
                    writeLog(@"[INIT] Tweak estava ativado antes do respring, restaurando estado");
                    
                    // Obter URL do servidor
                    NSString *serverURL = [[NSUserDefaults standardUserDefaults] objectForKey:@"VCamMJPEG_ServerURL"];
                    if (serverURL) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            writeLog(@"[INIT] Restaurando conexão MJPEG: %@", serverURL);
                            
                            // Atualizar interface
                            MJPEGPreviewWindow *window = [MJPEGPreviewWindow sharedInstance];
                            window.serverTextField.text = [serverURL stringByReplacingOccurrencesOfString:@"http://" withString:@""];
                            
                            // CORREÇÃO: Em vez de chamar diretamente o método privado, usar notificação
                            // Isso simula um clique no botão
                            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"VCamMJPEG_Enabled"];
                            [[NSUserDefaults standardUserDefaults] synchronize];
                            
                            // Ativar VirtualCameraController
                            [[VirtualCameraController sharedInstance] startCapturing];
                            
                            // Ativar MJPEGReader
                            NSURL *url = [NSURL URLWithString:serverURL];
                            [[MJPEGReader sharedInstance] startStreamingFromURL:url];
                            
                            // Atualizar interface
                            window.isConnected = YES;
                            [window.connectButton setTitle:@"Desativar Câmera Virtual" forState:UIControlStateNormal];
                            [window.connectButton setBackgroundColor:[UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.9]];
                            [window updateStatus:@"VirtualCam\nAtivo"];
                        });
                    }
                }
            });
        }
    }
}
