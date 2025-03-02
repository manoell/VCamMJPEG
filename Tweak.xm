#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"
#import "MJPEGReader.h"
#import "MJPEGPreviewWindow.h"
#import "VirtualCameraController.h"

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

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    // Logar informações detalhadas
    writeLog(@"[HOOK] AVCaptureVideoDataOutput setSampleBufferDelegate chamado para %@", 
             sampleBufferDelegate ? NSStringFromClass([sampleBufferDelegate class]) : @"(null)");
    
    // Se for NULL, apenas chamar o método original e não fazer mais nada
    if (!sampleBufferDelegate) {
        %orig;
        return;
    }
    
    // Verificar se a queue também é válida
    if (!sampleBufferCallbackQueue) {
        writeLog(@"[HOOK] Aviso: queue de callback é null");
        %orig;
        return;
    }
    
    // Chamar o método original
    %orig;
    
    // Ativar o controlador com proteção contra erros
    @try {
        // Verificar se podemos ativar o controlador
        VirtualCameraController *controller = [VirtualCameraController sharedInstance];
        [controller startCapturing];
        
        writeLog(@"[HOOK] Controlador ativado em setSampleBufferDelegate");
    } @catch (NSException *exception) {
        writeLog(@"[HOOK] Erro ao ativar controlador: %@", exception);
    }
}

%end

%hook NSObject

// Hook para o método que recebe os sample buffers da câmera
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Primeiro verifique se este objeto responde ao método original
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        %orig;
        return;
    }
    
    // Verificar se é um output de vídeo e se todos os parâmetros são válidos
    if ([output isKindOfClass:%c(AVCaptureVideoDataOutput)] && sampleBuffer && connection) {
        @try {
            // Aqui é a substituição do buffer
            VirtualCameraController *controller = [VirtualCameraController sharedInstance];
            
            if (controller.isActive) {
                // Tentar obter um buffer virtual
                CMSampleBufferRef virtualBuffer = [controller getLatestSampleBuffer];
                
                if (virtualBuffer) {
                    static int frameCount = 0;
                    frameCount++;
                    
                    if (frameCount % 30 == 0) {
                        writeLog(@"[HOOK] Substituindo frame da câmera #%d", frameCount);
                    }
                    
                    // Chamar o método original com nosso buffer substituído
                    %orig(output, virtualBuffer, connection);
                    CFRelease(virtualBuffer);
                    return;
                }
            }
        } @catch (NSException *exception) {
            writeLog(@"[HOOK] Erro ao processar frame: %@", exception);
        }
    }
    
    // Se não pudermos substituir, chamar o método original
    %orig;
}

%end

// Constructor - roda quando o tweak é carregado
%ctor {
    @autoreleasepool {
        setLogLevel(4);
        
        NSString *processName = [NSProcessInfo processInfo].processName;
        writeLog(@"[INIT] VirtualCam MJPEG carregado em processo: %@", processName);
        
        if ([processName isEqualToString:@"SpringBoard"]) {
            // Modo SpringBoard: Apenas UI
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                writeLog(@"[INIT] Mostrando janela de preview em SpringBoard");
                [[MJPEGPreviewWindow sharedInstance] show];
            });
        } else if ([processName isEqualToString:@"Camera"]) {
            // Para o app de câmera: Ativar hooks e carregar VirtualCameraController
            writeLog(@"[INIT] Ativando modo de substituição de câmera para %@", processName);
            
            // Inicializar VirtualCameraController
            VirtualCameraController *controller = [VirtualCameraController sharedInstance];
            
            // Importante: ativar o controlador para que a substituição ocorra
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [controller startCapturing];
                writeLog(@"[CAMERA] Controlador ativado automaticamente");
                
                // Iniciar conexão com servidor MJPEG se não estiver conectado
                MJPEGReader *reader = [MJPEGReader sharedInstance];
                if (!reader.isConnected) {
                    writeLog(@"[CAMERA] Iniciando conexão automática com servidor MJPEG");
                    NSURL *url = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
                    [reader startStreamingFromURL:url];
                }
            });
        }
    }
}