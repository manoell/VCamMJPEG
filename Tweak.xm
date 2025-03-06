#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"
#import "MJPEGReader.h"
#import "MJPEGPreviewWindow.h"
#import "VirtualCameraController.h"
#import "GetFrame.h"
#import <objc/runtime.h>

// Estados de compilação condicional
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)

// Estado global para controle
static dispatch_queue_t g_processingQueue;
static AVSampleBufferDisplayLayer *g_customDisplayLayer = nil;
static CALayer *g_maskLayer = nil;
static CADisplayLink *g_displayLink = nil;
static NSString *g_tempFile = @"/tmp/vcam.mjpeg";
static BOOL g_isVideoOrientationSet = NO;
static int g_videoOrientation = 1; // Default orientation (portrait)
static BOOL g_isCapturingPhoto = NO; // Flag para indicar captura de foto em andamento

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
    
    // Criar um proxy para o delegado original
    if (sampleBufferDelegate && [[VirtualCameraController sharedInstance] isActive]) {
        // Usar objc_setAssociatedObject para associar o delegado original
        objc_setAssociatedObject(sampleBufferDelegate, "originalDelegate", sampleBufferDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // Chamar o método original com o delegado interceptado
        %orig;
    } else {
        %orig;
    }
}

%end

// Hook para AVCaptureAudioDataOutput
%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    writeLog(@"[HOOK] AVCaptureAudioDataOutput setSampleBufferDelegate: %@",
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

// Para iOS <10, AVCaptureStillImageOutput
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
%group iOS9AndBelow

// Hook para AVCaptureStillImageOutput para captura de fotos estáticas
%hook AVCaptureStillImageOutput

- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection completionHandler:(void (^)(CMSampleBufferRef, NSError *))handler {
    writeLog(@"[HOOK] Capturando foto estática com AVCaptureStillImageOutput");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    g_isCapturingPhoto = YES;
    
    // Criar um novo handler que intercepta o buffer da foto
    void (^newHandler)(CMSampleBufferRef, NSError *) = ^(CMSampleBufferRef sampleBuffer, NSError *error) {
        writeLog(@"[HOOK] Interceptando completionHandler da captura de foto");
        
        // Obter o buffer MJPEG para substituição
        CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
        
        if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
            writeLog(@"[HOOK] Substituindo buffer da foto capturada");
            // Chamar o handler original com o buffer MJPEG
            handler(mjpegBuffer, error);
            // Não liberar o mjpegBuffer aqui, pois o handler original vai usá-lo
        } else {
            // Se não conseguimos substituir, usar o original
            handler(sampleBuffer, error);
        }
        
        g_isCapturingPhoto = NO;
    };
    
    // Chamar o método original com o novo handler
    %orig(connection, newHandler);
}

%end

// Classe utilitária para o AVCaptureStillImageOutput
%hook NSObject

// Método para representação JPEG de imagem estática
+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)sampleBuffer {
    // Verificar se somos o método correto da classe correta
    if (![self respondsToSelector:@selector(jpegStillImageNSDataRepresentation:)]) {
        return %orig;
    }
    
    writeLog(@"[HOOK] jpegStillImageNSDataRepresentation chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Obter o buffer MJPEG para substituição
    CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:NO];
    
    if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
        writeLog(@"[HOOK] Substituindo buffer na representação JPEG");
        
        // Usar o buffer MJPEG para criar os dados JPEG
        NSData *jpegData = %orig(mjpegBuffer);
        
        return jpegData;
    }
    
    // Se não conseguimos substituir, usar o original
    return %orig;
}

%end
%end  // iOS9AndBelow
#pragma clang diagnostic pop

// Para iOS 10+, AVCapturePhotoOutput
%group iOS10AndAbove

// Hook para AVCapturePhotoOutput
%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    writeLog(@"[HOOK] capturePhotoWithSettings:delegate: chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    g_isCapturingPhoto = YES;
    
    // Armazenar o delegate original
    objc_setAssociatedObject(delegate, "originalDelegate", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Continuamos com o método original
    %orig;
}

%end

// Hook para métodos do AVCapturePhotoCaptureDelegate
%hook NSObject

// Para iOS 10-12
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)photoSampleBuffer previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings bracketSettings:(AVCaptureBracketedStillImageSettings *)bracketSettings error:(NSError *)error {
    // Verificar se somos um delegate de AVCapturePhotoCaptureDelegate
    if (![self respondsToSelector:@selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:)]) {
        return %orig;
    }
    
    writeLog(@"[HOOK] didFinishProcessingPhotoSampleBuffer chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Obter buffer de substituição
    CMSampleBufferRef mjpegBuffer = photoSampleBuffer ? [GetFrame getCurrentFrame:photoSampleBuffer replace:YES] : nil;
    
    if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
        writeLog(@"[HOOK] Substituindo buffer na finalização da captura de foto");
        // Chamar o método original com o buffer MJPEG
        %orig(output, mjpegBuffer, previewPhotoSampleBuffer, resolvedSettings, bracketSettings, error);
    } else {
        // Se não conseguimos substituir, usar o original
        %orig;
    }
    
    g_isCapturingPhoto = NO;
}

// Para iOS 11+
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    // Verificar se somos um delegate de AVCapturePhotoCaptureDelegate
    if (![self respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
        return %orig;
    }
    
    writeLog(@"[HOOK] didFinishProcessingPhoto chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Aqui precisamos substituir a imagem na propriedade do AVCapturePhoto
    // Como não podemos modificar o AVCapturePhoto diretamente, vamos criar um substituto
    // Isso pode ser complexo e dependente da implementação interna do AVCapturePhoto
    
    // Por enquanto, apenas logamos e seguimos com o original
    writeLog(@"[HOOK] Método de captura de foto moderno - complexidade de substituição alta");
    
    %orig;
    g_isCapturingPhoto = NO;
}

%end

// Hook para AVCapturePhoto - iOS 11+
%hook AVCapturePhoto

- (CGImageRef)CGImageRepresentation {
    writeLog(@"[HOOK] CGImageRepresentation chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Obter o frame atual
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:NO];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        writeLog(@"[HOOK] Substituindo CGImageRepresentation com frame atual");
        
        // Obter um CIImage do buffer
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
        
        // Converter CIImage para CGImage
        CIContext *context = [CIContext new];
        CGImageRef cgImage = [context createCGImage:ciImage fromRect:[ciImage extent]];
        
        return cgImage;
    }
    
    return %orig;
}

- (CVPixelBufferRef)pixelBuffer {
    writeLog(@"[HOOK] pixelBuffer chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Obter o frame atual
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:NO];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        writeLog(@"[HOOK] Substituindo pixelBuffer com frame atual");
        
        // Retornar o CVPixelBuffer do buffer atual
        return CMSampleBufferGetImageBuffer(buffer);
    }
    
    return %orig;
}

- (NSData *)fileDataRepresentation {
    writeLog(@"[HOOK] fileDataRepresentation chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Obter o frame atual
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:NO];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        writeLog(@"[HOOK] Substituindo fileDataRepresentation com frame atual");
        
        // Obter um CIImage do buffer
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
        
        // Converter para UIImage
        UIImage *image = [UIImage imageWithCIImage:ciImage];
        
        // Converter para JPEG data
        return UIImageJPEGRepresentation(image, 1.0);
    }
    
    return %orig;
}

- (NSData *)fileDataRepresentationWithCustomizer:(id)customizer {
    writeLog(@"[HOOK] fileDataRepresentationWithCustomizer chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Obter o frame atual
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:NO];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        writeLog(@"[HOOK] Substituindo fileDataRepresentationWithCustomizer com frame atual");
        
        // Obter um CIImage do buffer
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
        
        // Converter para UIImage
        UIImage *image = [UIImage imageWithCIImage:ciImage];
        
        // Converter para JPEG data
        return UIImageJPEGRepresentation(image, 1.0);
    }
    
    return %orig;
}

%end
%end  // iOS10AndAbove

// Para todos os iOS - processamento de vídeo
%hook NSObject

// Para a captura de frames de vídeo
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Verificar se somos um delegate de amostra de buffer
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        return %orig;
    }
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Obter informações de orientação do vídeo
    g_videoOrientation = (int)connection.videoOrientation;
    
    // Obter buffer de substituição
    CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
    
    if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
        // Chamar o método original com o buffer MJPEG
        %orig(output, mjpegBuffer, connection);
        
        // Não liberar mjpegBuffer pois o método original vai usá-lo
    } else {
        // Se não conseguimos substituir, usar o original
        %orig;
    }
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
        
        // Inicializar grupos condicionalmente com base na versão do iOS
        if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"10.0")) {
            writeLog(@"[INIT] Ativando hooks para iOS 10 e superior");
            %init(iOS10AndAbove);
        } else {
            writeLog(@"[INIT] Ativando hooks para iOS 9 e inferior");
            %init(iOS9AndBelow);
        }
        
        // Inicializar os grupos padrão
        %init(_ungrouped);
    }
}
