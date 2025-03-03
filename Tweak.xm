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

// Hook para AVCaptureVideoDataOutput
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    // Logar informações sobre o delegado
    writeLog(@"[HOOK] AVCaptureVideoDataOutput setSampleBufferDelegate chamado para %@", 
             sampleBufferDelegate ? NSStringFromClass([sampleBufferDelegate class]) : @"(null)");
    
    // Logar todas as classes que implementam captureOutput:didOutputSampleBuffer:fromConnection:
    if (sampleBufferDelegate) {
        BOOL respondsToSelector = [sampleBufferDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)];
        writeLog(@"[HOOK] Delegado responde a captureOutput:didOutputSampleBuffer:fromConnection: %d", respondsToSelector);
    }
    
    // Ativar o controlador
    [[VirtualCameraController sharedInstance] startCapturing];
    
    // Tentar conectar ao servidor MJPEG se necessário
    MJPEGReader *reader = [MJPEGReader sharedInstance];
    if (!reader.isConnected) {
        NSURL *defaultURL = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
        [reader startStreamingFromURL:defaultURL];
    }
    
    // Chamar o método original
    %orig;
    
    // Log após configuração
    writeLog(@"[HOOK] Delegado configurado com sucesso");
}

%end

// Hook para AVCaptureConnection para entender seu funcionamento
%hook AVCaptureConnection

- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation {
    writeLog(@"[HOOK] setVideoOrientation: %d", (int)videoOrientation);
    %orig;
}

%end

// MÉTODO CHAVE MODIFICADO: Hook mais robusto para captureOutput:didOutputSampleBuffer:fromConnection:
%hook NSObject

// Hook para o método que recebe os sample buffers da câmera
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    static int originalFrameCount = 0;
    static int replacedFrameCount = 0;
    static BOOL isFirstFrame = YES;
    
    // Verificações iniciais com mais logs
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        if (isFirstFrame) {
            writeLog(@"[HOOK] Objeto %@ não responde ao seletor captureOutput:didOutputSampleBuffer:fromConnection:", 
                NSStringFromClass([self class]));
            isFirstFrame = NO;
        }
        %orig;
        return;
    }
    
    // Log inicial para captura
    if (isFirstFrame) {
        writeLog(@"[HOOK] CAPTURADA PRIMEIRA CHAMADA de captureOutput:didOutputSampleBuffer: na classe %@", 
            NSStringFromClass([self class]));
        isFirstFrame = NO;
    }
    
    // Verificar se é um output de vídeo e se todos os parâmetros são válidos
    if (!output || !sampleBuffer || !connection) {
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
    
    @try {
        // Log para depuração (limitado para não sobrecarregar)
        if (originalFrameCount++ % 300 == 0) {
            writeLog(@"[HOOK] Frame original #%d da câmera recebido de %@", 
                    originalFrameCount, NSStringFromClass([output class]));
        }
        
        // Verificar se o leitor MJPEG está conectado
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        if (!reader.isConnected) {
            NSURL *defaultURL = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
            [reader startStreamingFromURL:defaultURL];
        }
        
        // Obter um buffer MJPEG para substituição 
        CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
            
        if (mjpegBuffer) {
            // Log para saber que estamos tentando substituir (limitado)
            if (replacedFrameCount++ % 100 == 0) {
                writeLog(@"[HOOK] Substituindo frame da câmera #%d com frame MJPEG em %@", 
                        replacedFrameCount, NSStringFromClass([self class]));
                
                CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(mjpegBuffer);
                Float64 presentationSeconds = CMTimeGetSeconds(presentationTime);
                writeLog(@"[HOOK] Timestamp do frame substituído: %.3f segundos", presentationSeconds);
            }
            
            // SUBSTITUIÇÃO DO FRAME - chamar o método original com nosso buffer substituído
            %orig(output, mjpegBuffer, connection);
            
            // Liberar o buffer após uso
            CFRelease(mjpegBuffer);
            return;
        } else if (originalFrameCount % 300 == 0) {
            writeLog(@"[HOOK] Sem buffer MJPEG disponível para substituir frame #%d", originalFrameCount);
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
        VirtualCameraController *controller = [VirtualCameraController sharedInstance];
        
        if ([processName isEqualToString:@"SpringBoard"]) {
            // Modo SpringBoard: Apenas UI
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                writeLog(@"[INIT] Mostrando janela de preview em SpringBoard");
                [[MJPEGPreviewWindow sharedInstance] show];
            });
        } else {
            // Observar notificações relacionadas à câmera para iniciar a captura quando necessário
            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
            
            // Observar quando o app se torna ativo (possível uso da câmera)
            [center addObserverForName:UIApplicationDidBecomeActiveNotification 
                                object:nil 
                                 queue:[NSOperationQueue mainQueue] 
                            usingBlock:^(NSNotification *notification) {
                [controller startCapturing];
            }];
            
            // Verificar apps conhecidos que usam a câmera frequentemente para ativar proativamente
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