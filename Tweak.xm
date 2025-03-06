#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"
#import "MJPEGReader.h"
#import "MJPEGPreviewWindow.h"
#import "VirtualCameraController.h"
#import "GetFrame.h"
#import <objc/runtime.h>

// Estado global para controle
static dispatch_queue_t g_processingQueue;
static AVSampleBufferDisplayLayer *g_customDisplayLayer = nil;
static CALayer *g_maskLayer = nil;
static CADisplayLink *g_displayLink = nil;
static NSString *g_tempFile = @"/tmp/vcam.mjpeg";
static BOOL g_isVideoOrientationSet = NO;
static int g_videoOrientation = 1; // Default orientation (portrait)

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
    g_isVideoOrientationSet = YES;
    g_videoOrientation = (int)videoOrientation;
    %orig;
}

%end

// Hook para AVCaptureVideoDataOutput para monitorar captura
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    writeLog(@"[HOOK] AVCaptureVideoDataOutput setSampleBufferDelegate: %@",
             NSStringFromClass([sampleBufferDelegate class]));
    %orig;
}

%end

// Hook para AVCaptureVideoPreviewLayer para adicionar nossa camada
%hook AVCaptureVideoPreviewLayer

- (void)addSublayer:(CALayer *)layer {
    %orig;
    
    // Verificar se já injetamos nossa camada
    if (![self.sublayers containsObject:g_customDisplayLayer]) {
        // Criar nossa própria camada de exibição se ainda não existe
        if (!g_customDisplayLayer) {
            g_customDisplayLayer = [[AVSampleBufferDisplayLayer alloc] init];
            g_maskLayer = [CALayer new];
            [g_maskLayer setBackgroundColor:[UIColor blackColor].CGColor];
        }
        
        // Adicionar nossas camadas
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_customDisplayLayer above:g_maskLayer];
        
        // Configurar DisplayLink para atualização periódica
        if (!g_displayLink) {
            g_displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
            [g_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        }
        
        // Atualizar frames e opacidade
        dispatch_async(dispatch_get_main_queue(), ^{
            g_customDisplayLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
        });
        
        writeLog(@"[HOOK] Camadas customizadas adicionadas com sucesso");
    }
}

// Adicionar método step: para atualização periódica
%new
- (void)step:(CADisplayLink *)link {
    // Verificar se o VirtualCameraController está ativo
    if (![[VirtualCameraController sharedInstance] isActive]) {
        [g_maskLayer setOpacity:0.0];
        [g_customDisplayLayer setOpacity:0.0];
        return;
    }
    
    // Atualizar visibilidade das camadas
    [g_maskLayer setOpacity:1.0];
    [g_customDisplayLayer setOpacity:1.0];
    [g_customDisplayLayer setVideoGravity:self.videoGravity];
    
    // Aplicar transformação baseada na orientação do vídeo
    if (g_isVideoOrientationSet) {
        CATransform3D transform = CATransform3DIdentity;
        
        // Ajustar transformação baseada na orientação
        switch (g_videoOrientation) {
            case 1: // Portrait
                transform = CATransform3DIdentity;
                break;
            case 2: // Portrait upside down
                transform = CATransform3DMakeRotation(M_PI, 0, 0, 1.0);
                break;
            case 3: // Landscape right
                transform = CATransform3DMakeRotation(M_PI_2, 0, 0, 1.0);
                break;
            case 4: // Landscape left
                transform = CATransform3DMakeRotation(-M_PI_2, 0, 0, 1.0);
                break;
            default:
                transform = [self transform];
                break;
        }
        
        [g_customDisplayLayer setTransform:transform];
    }
    
    // Verificar se a camada está pronta para mais dados
    if ([g_customDisplayLayer isReadyForMoreMediaData]) {
        // Obter o último frame MJPEG
        CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
        
        if (buffer && CMSampleBufferIsValid(buffer)) {
            // Limpar buffer existente e adicionar novo
            [g_customDisplayLayer flush];
            [g_customDisplayLayer enqueueSampleBuffer:buffer];
            
            static int frameCount = 0;
            if (++frameCount % 300 == 0) {
                writeLog(@"[HOOK] Frame #%d injetado na camada personalizada", frameCount);
            }
            
            // Liberar o buffer após uso
            CFRelease(buffer);
        }
    }
}

%end

// Hook para AVSampleBufferDisplayLayer para interceptar enqueueSampleBuffer
%hook AVSampleBufferDisplayLayer

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Ignorar o hook para SpringBoard
    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
        %orig;
        return;
    }
    
    // Verificar se o VirtualCameraController está ativo
    if (![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    // Verificar validade do buffer original
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
        %orig;
        return;
    }
    
    @try {
        // Obter buffer MJPEG para substituição
        CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
        
        if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
            // Registro de substituição (limitado)
            static int displayReplaceCount = 0;
            if (++displayReplaceCount % 300 == 0) {
                writeLog(@"[DISPLAY] Substituindo frame #%d em AVSampleBufferDisplayLayer",
                         displayReplaceCount);
            }
            
            // Usar o buffer MJPEG diretamente
            %orig(mjpegBuffer);
            
            // Liberar buffer
            CFRelease(mjpegBuffer);
            return;
        }
    } @catch (NSException *exception) {
        writeLog(@"[DISPLAY] Erro ao processar buffer para exibição: %@", exception);
    }
    
    // Se não conseguimos substituir, usar o original
    %orig;
}

// Monitorar operações de flush para depuração
- (void)flush {
    static int flushCount = 0;
    if (++flushCount % 300 == 0) {
        writeLog(@"[DISPLAY] AVSampleBufferDisplayLayer flush #%d", flushCount);
    }
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
        
        // Verificar se estamos em um aplicativo que usa a câmera
        BOOL isCameraApp =
            ([processName isEqualToString:@"Camera"] ||
             [processName containsString:@"camera"] ||
             [processName isEqualToString:@"Telegram"] ||
             [processName containsString:@"facetime"]);
            
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
    }
}
