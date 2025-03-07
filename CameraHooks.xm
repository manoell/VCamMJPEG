#import "Tweak.h"

// Grupo para hooks relacionados à câmera
%group CameraHooks

// Função auxiliar para garantir que a resolução da câmera está atualizada
static void updateCurrentCameraResolution() {
    // Atualizar a resolução atual com base na câmera em uso
    g_originalCameraResolution = g_usingFrontCamera ? g_originalFrontCameraResolution : g_originalBackCameraResolution;
    
    // Log para depuração
    writeLog(@"[HOOK] Resolução atual da câmera atualizada para %.0f x %.0f (Câmera %@)",
             g_originalCameraResolution.width, g_originalCameraResolution.height,
             g_usingFrontCamera ? @"Frontal" : @"Traseira");
}

// Hook para AVCaptureSession para monitorar quando a câmera é iniciada
%hook AVCaptureSession

- (void)startRunning {
    writeLog(@"[HOOK] AVCaptureSession startRunning foi chamado");
    
    // Chamar o método original primeiro
    %orig;
    
    // Registrar delegados conhecidos
    logDelegates();
    
    @try {
        VirtualCameraController *controller = [VirtualCameraController sharedInstance];
        
        writeLog(@"[HOOK] Ativando VirtualCameraController após AVCaptureSession.startRunning");
        [controller startCapturing];
        
        // Registrar status atual
        writeLog(@"[HOOK] VirtualCameraController ativo: %d", controller.isActive);
        
        // Ativar conexão MJPEG se necessário
        NSString *savedURL = [[NSUserDefaults standardUserDefaults] objectForKey:@"VCamMJPEG_ServerURL"];
        if (savedURL && ![[MJPEGReader sharedInstance] isConnected]) {
            NSURL *url = [NSURL URLWithString:savedURL];
            if (url) {
                writeLog(@"[HOOK] Iniciando conexão MJPEG após AVCaptureSession.startRunning");
                [[MJPEGReader sharedInstance] startStreamingFromURL:url];
            }
        }
        
        writeLog(@"[HOOK] MJPEGReader conectado: %d", [[MJPEGReader sharedInstance] isConnected]);
    } @catch (NSException *exception) {
        writeLog(@"[HOOK] Erro após startRunning: %@", exception);
    }
}

%end

// Hook para AVCaptureConnection para entender seu funcionamento
%hook AVCaptureConnection

- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation {
    writeLog(@"[HOOK] setVideoOrientation: %d (Anterior: %d)", (int)videoOrientation, g_videoOrientation);
    g_isVideoOrientationSet = YES;
    g_videoOrientation = (int)videoOrientation;
    
    // Log detalhado
    NSString *orientationDesc;
    switch ((int)videoOrientation) {
        case 1: orientationDesc = @"Portrait"; break;
        case 2: orientationDesc = @"Portrait Upside Down"; break;
        case 3: orientationDesc = @"Landscape Right"; break;
        case 4: orientationDesc = @"Landscape Left"; break;
        default: orientationDesc = @"Desconhecido"; break;
    }
    
    writeLog(@"[HOOK] Orientação definida para: %@ (%d)", orientationDesc, (int)videoOrientation);
    %orig;
}
%end

// Hook para AVCaptureDevice para obter a resolução real da câmera
%hook AVCaptureDevice

+ (AVCaptureDevice *)defaultDeviceWithMediaType:(NSString *)mediaType {
    AVCaptureDevice *device = %orig;
    
    if ([mediaType isEqualToString:AVMediaTypeVideo] && device) {
        // Obter a resolução da câmera real
        AVCaptureDeviceFormat *format = device.activeFormat;
        if (format) {
            CMVideoFormatDescriptionRef formatDescription = format.formatDescription;
            if (formatDescription) {
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
                
                // Determinar se é câmera frontal ou traseira
                BOOL isFrontCamera = (device.position == AVCaptureDevicePositionFront);
                g_usingFrontCamera = isFrontCamera;
                
                if (isFrontCamera) {
                    g_originalFrontCameraResolution = CGSizeMake(dimensions.width, dimensions.height);
                    writeLog(@"[HOOK] Resolução da câmera frontal detectada: %.0f x %.0f",
                            g_originalFrontCameraResolution.width, g_originalFrontCameraResolution.height);
                } else {
                    g_originalBackCameraResolution = CGSizeMake(dimensions.width, dimensions.height);
                    writeLog(@"[HOOK] Resolução da câmera traseira detectada: %.0f x %.0f",
                            g_originalBackCameraResolution.width, g_originalBackCameraResolution.height);
                }
                
                // Definir a resolução atual com base na câmera em uso
                g_originalCameraResolution = isFrontCamera ? g_originalFrontCameraResolution : g_originalBackCameraResolution;
            }
        }
    }
    
    return device;
}

// Método adicional para detectar a posição da câmera
- (void)_setPosition:(int)position {
    %orig;
    
    // 1 = traseira, 2 = frontal
    BOOL isFrontCamera = (position == 2);
    g_usingFrontCamera = isFrontCamera;
    
    // Usar a função de atualização em vez do código direto
    updateCurrentCameraResolution();
    
    writeLog(@"[HOOK] Mudança de câmera detectada: %@", isFrontCamera ? @"Frontal" : @"Traseira");
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

// Para todos os iOS - processamento de vídeo
%hook NSObject

// Para a captura de frames de vídeo
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @try {
        // Verificar se somos um delegate de amostra de buffer
        if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            %orig;
            return;
        }
        
        // Verificar se a substituição da câmera está ativa
        BOOL isActive = NO;
        @try {
            isActive = [[VirtualCameraController sharedInstance] isActive];
        } @catch (NSException *e) {
            writeLog(@"[HOOK] Exceção ao verificar estado ativo: %@", e);
        }
        
        // IMPORTANTE: Verificar explicitamente o status de conexão do MJPEGReader
        // e o status do buffer do GetFrame
        BOOL isConnected = NO;
        @try {
            MJPEGReader *reader = [MJPEGReader sharedInstance];
            isConnected = reader.isConnected;
            
            // Verificar se o buffer de frame é válido
            // Se isConnected = TRUE mas não temos frames, forçar isConnected = FALSE
            BOOL hasFrames = [[GetFrame sharedInstance] hasFrames];
            if (isConnected && !hasFrames) {
                writeLog(@"[HOOK] O MJPEGReader está marcado como conectado, mas não existem frames disponíveis");
                isConnected = NO;
            }
        } @catch (NSException *e) {
            writeLog(@"[HOOK] Exceção ao verificar estado de conexão: %@", e);
        }
        
        // Só substitui o feed se estiver ativo E conectado
        if (!isActive || !isConnected) {
            %orig;
            return;
        }
        
        // Obter informações de orientação do vídeo
        g_videoOrientation = (int)connection.videoOrientation;
        
        // Obter buffer de substituição com proteção de erro
        CMSampleBufferRef mjpegBuffer = NULL;
        @try {
            mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
        } @catch (NSException *e) {
            writeLog(@"[HOOK] Exceção ao obter frame MJPEG: %@", e);
            mjpegBuffer = NULL;
        }
        
        // Verificação adicional de segurança
        BOOL bufferValid = NO;
        if (mjpegBuffer != NULL) {
            @try {
                bufferValid = CMSampleBufferIsValid(mjpegBuffer);
            } @catch (NSException *e) {
                writeLog(@"[HOOK] Exceção ao validar buffer MJPEG: %@", e);
                bufferValid = NO;
            }
        }
        
        if (mjpegBuffer != NULL && bufferValid) {
            // Chamar o método original com o buffer MJPEG
            %orig(output, mjpegBuffer, connection);
            
            // Não liberar mjpegBuffer pois o método original vai usá-lo
        } else {
            // Se não conseguimos substituir, usar o original
            %orig;
        }
    } @catch (NSException *e) {
        writeLog(@"[HOOK] Exceção geral em captureOutput: %@", e);
        %orig;
    }
}

%end

%end // grupo CameraHooks

// Constructor específico deste arquivo
%ctor {
    %init(CameraHooks);
}
