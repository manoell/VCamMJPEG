#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"
#import "MJPEGReader.h"
#import "MJPEGPreviewWindow.h"
#import "VirtualCameraController.h"

// Hook para AVCaptureVideoDataOutput
%hook AVCaptureVideoDataOutput

// Hook para método de adição de delegate
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    writeLog(@"[HOOK] AVCaptureVideoDataOutput setSampleBufferDelegate chamado");
    
    // Chamar o método original
    %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
    
    // Ativar o controlador de câmera virtual quando alguém se registra como delegate
    if (sampleBufferDelegate) {
        [[VirtualCameraController sharedInstance] startCapturing];
    }
}

%end

// Hook para o método de callback do delegate
%hook NSObject

// Hook para o método que recebe os sample buffers da câmera
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Verificar se é um output de vídeo
    if ([output isKindOfClass:%c(AVCaptureVideoDataOutput)]) {
        VirtualCameraController *controller = [VirtualCameraController sharedInstance];
        
        // Se a câmera virtual estiver ativa e tivermos um buffer para substituir
        if (controller.isActive) {
            // Obter o buffer virtual
            CMSampleBufferRef virtualBuffer = [controller getLatestSampleBuffer];
            
            if (virtualBuffer) {
                // Chamar o método original com nosso buffer em vez do original
                %orig(output, virtualBuffer, connection);
                CFRelease(virtualBuffer);
                return;
            }
        }
    }
    
    // Caso não estejamos substituindo, chamar o método original normalmente
    %orig;
}

%end

// Constructor - roda quando o tweak é carregado
%ctor {
    @autoreleasepool {
        // Configurar nível de log
        setLogLevel(4); // Nível debug para ver logs
        
        NSString *processName = [NSProcessInfo processInfo].processName;
        writeLog(@"[INIT] VirtualCam MJPEG carregado em processo: %@", processName);
        
        // APENAS inicializar no SpringBoard para mostrar a UI
        if ([processName isEqualToString:@"SpringBoard"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                writeLog(@"[INIT] Mostrando janela de preview em SpringBoard");
                [[MJPEGPreviewWindow sharedInstance] show];
            });
        } else {
            // Para outros processos, apenas inicializar os hooks (sem UI)
            writeLog(@"[INIT] Inicializando hooks para substituição de câmera em %@", processName);
        }
    }
}