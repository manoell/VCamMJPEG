#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"
#import "MJPEGReader.h"
#import "MJPEGPreviewWindow.h"
#import "VirtualCameraController.h"

// Estado global para controle
static dispatch_queue_t g_processingQueue;

// Hook para AVCaptureSession para monitorar quando a câmera é iniciada
%hook AVCaptureSession

- (void)startRunning {
    writeLog(@"[HOOK] AVCaptureSession startRunning foi chamado");
    
    // Chamar o método original primeiro
    %orig;
    
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
}

%end

%hook NSObject

// Hook para o método que recebe os sample buffers da câmera
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    static int originalFrameCount = 0;
    static int replacedFrameCount = 0;
    
    // Primeiro verifique se este objeto responde ao método original
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        %orig;
        return;
    }
    
    // Verificar se é um output de vídeo e se todos os parâmetros são válidos
    if (sampleBuffer && connection) {
        // Verificar se é um VideoDataOutput de forma mais geral
        BOOL isVideoOutput = [output isKindOfClass:%c(AVCaptureVideoDataOutput)] || 
                             [NSStringFromClass([output class]) containsString:@"VideoDataOutput"] ||
                             [NSStringFromClass([output class]) containsString:@"Video"];
        
        if (isVideoOutput) {
            @try {
                // Verificações para debug
                if (originalFrameCount++ % 300 == 0) {
                    writeLog(@"[HOOK] Frame original #%d da câmera recebido na classe: %@", 
                             originalFrameCount, NSStringFromClass([self class]));
                }
                
                // Verificar controlador e leitor
                VirtualCameraController *controller = [VirtualCameraController sharedInstance];
                MJPEGReader *reader = [MJPEGReader sharedInstance];
                
                // Se não estiver ativo, ative-o
                if (!controller.isActive) {
                    [controller startCapturing];
                }
                
                // Se o reader não estiver conectado, conecte-o
                if (!reader.isConnected) {
                    NSURL *defaultURL = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
                    [reader startStreamingFromURL:defaultURL];
                }
                
                if (controller.isActive) {
                    // Tentar obter um buffer virtual
                    CMSampleBufferRef mjpegBuffer = [controller getLatestSampleBuffer];
                    
                    if (mjpegBuffer) {
                        // Log para saber que estamos tentando substituir
                        if (replacedFrameCount++ % 300 == 0) {
                            writeLog(@"[HOOK] Substituindo frame da câmera #%d na classe: %@", 
                                     replacedFrameCount, NSStringFromClass([self class]));
                        }
                        
                        // Chamar o método original com nosso buffer substituído
                        %orig(output, mjpegBuffer, connection);
                        
                        // Liberar o buffer após uso
                        CFRelease(mjpegBuffer);
                        return;
                    } else if (originalFrameCount % 300 == 0) {
                        writeLog(@"[HOOK] Sem buffer MJPEG disponível para substituir frame #%d", originalFrameCount);
                    }
                }
            } @catch (NSException *exception) {
                writeLog(@"[HOOK] Erro ao processar frame: %@", exception);
            }
        }
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
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        
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