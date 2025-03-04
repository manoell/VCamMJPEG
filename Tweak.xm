#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"
#import "MJPEGReader.h"
#import "MJPEGPreviewWindow.h"
#import "VirtualCameraController.h"
#import "GetFrame.h"

// Estado global para controle
static dispatch_queue_t g_processingQueue;

// Log para mostrar delegados conhecidos
static void logDelegates() {
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

// Hook para AVCaptureSession para monitorar quando a câmera é iniciada
%hook AVCaptureSession

- (void)startRunning {
    writeLog(@"[HOOK] AVCaptureSession startRunning foi chamado");
    
    // Chamar o método original primeiro
    %orig;
    
    // Registrar delegados conhecidos
    logDelegates();
    
    // Depois ativar o controlador com segurança
    @try {
        VirtualCameraController *controller = [VirtualCameraController sharedInstance];
        
        writeLog(@"[HOOK] Ativando VirtualCameraController após AVCaptureSession.startRunning");
        [controller startCapturing];
        
        // Registrar status atual
        writeLog(@"[HOOK] VirtualCameraController ativo: %d", controller.isActive);
        
        // Ativar conexão MJPEG se necessário
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        if (!reader.isConnected) {
            writeLog(@"[HOOK] Iniciando conexão MJPEG após AVCaptureSession.startRunning");
            [reader startStreamingFromURL:[NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"]];
        }
        
        writeLog(@"[HOOK] MJPEGReader conectado: %d", reader.isConnected);
    } @catch (NSException *exception) {
        writeLog(@"[HOOK] Erro após startRunning: %@", exception);
    }
}

%end

// Hook para AVCaptureConnection para entender seu funcionamento
%hook AVCaptureConnection

- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation {
    writeLog(@"[HOOK] setVideoOrientation: %d", (int)videoOrientation);
    %orig;
}

%end

// MÉTODO CHAVE MODIFICADO: Hook mais robusto para substituição de buffer
%hook NSObject

// Verificar se o objeto é um delegado conhecido de SampleBuffer
- (BOOL)isKnownSampleBufferDelegate {
    static NSArray *knownDelegates = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        knownDelegates = @[
            @"SCManagedCapturerV2",
            @"SCManagedVideoCapturerSnapRecorder",
            @"SCManagedCapturerPreviewView",
            @"AVCaptureVideoPreviewLayer",
            @"PLCameraController",
            @"CAMCaptureEngine",
            @"CAMViewfinderViewController",
            @"CAMPreviewViewController"
        ];
    });
    
    NSString *className = NSStringFromClass([self class]);
    return [knownDelegates containsObject:className];
}

// Hook para o método que recebe os sample buffers da câmera
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Verificações iniciais - Ignorar o hook para SpringBoard e outros processos não relevantes
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        %orig;
        return;
    }
    
    // Verificar se é um output de vídeo e se todos os parâmetros são válidos
    if (!output || !sampleBuffer || !connection || !CMSampleBufferIsValid(sampleBuffer)) {
        %orig;
        return;
    }
    
    // Verificar se é um VideoDataOutput
    BOOL isVideoOutput = [output isKindOfClass:%c(AVCaptureVideoDataOutput)] ||
                          [NSStringFromClass([output class]) containsString:@"VideoDataOutput"] ||
                          [NSStringFromClass([output class]) containsString:@"Video"];
    
    if (!isVideoOutput) {
        %orig;
        return;
    }
    
    // Ignorar para o processo SpringBoard
    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
        %orig;
        return;
    }
    
    @try {
        // Verificar se o VirtualCameraController está ativo
        if (![[VirtualCameraController sharedInstance] isActive]) {
            %orig;
            return;
        }
        
        // Tentar obter um buffer MJPEG para substituição
        CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
            
        if (mjpegBuffer) {
            // Verificar novamente se o buffer é válido
            if (CMSampleBufferIsValid(mjpegBuffer) && CMSampleBufferGetImageBuffer(mjpegBuffer)) {
                // Log estático para não sobrecarregar
                static int replacedFrameCount = 0;
                if (++replacedFrameCount % 300 == 0) {
                    writeLog(@"[HOOK] Substituindo frame da câmera #%d com frame MJPEG em %@",
                            replacedFrameCount, NSStringFromClass([self class]));
                }
                
                // SUBSTITUIÇÃO DO FRAME - chamar o método original com nosso buffer substituído
                %orig(output, mjpegBuffer, connection);
                
                // Liberar o buffer após uso
                CFRelease(mjpegBuffer);
                return;
            } else {
                // Se o buffer não for válido, liberá-lo
                writeLog(@"[HOOK] Buffer MJPEG obtido não é válido");
                CFRelease(mjpegBuffer);
            }
        }
    } @catch (NSException *exception) {
        writeLog(@"[HOOK] Erro ao processar frame: %@", exception);
    }
    
    // Se não pudermos substituir, chamar o método original
    %orig;
}

%end

// Constructor - roda quando o tweak é carregado
%ctor {
    @autoreleasepool {
        setLogLevel(5); // Aumentado para nível DEBUG para mais detalhes
        
        NSString *processName = [NSProcessInfo processInfo].processName;
        writeLog(@"[INIT] VirtualCam MJPEG carregado em processo: %@", processName);
        
        // Inicialização única dos componentes principais
        // Forçar inicialização do VirtualCameraController
        VirtualCameraController *controller = [VirtualCameraController sharedInstance];
        
        if ([processName isEqualToString:@"SpringBoard"]) {
            // Modo SpringBoard: Apenas UI
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                writeLog(@"[INIT] Mostrando janela de preview em SpringBoard");
                [[MJPEGPreviewWindow sharedInstance] show];
            });
        } else {
            // Aplicativos que usam a câmera
            BOOL isCameraApp =
                ([processName isEqualToString:@"Camera"] ||
                 [processName containsString:@"camera"] ||
                 [processName isEqualToString:@"Telegram"] ||
                 [processName containsString:@"facetime"]);
                
            if (isCameraApp) {
                writeLog(@"[INIT] Configurando hooks para app de câmera: %@", processName);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [controller startCapturing];
                });
            }
        }
    }
}
