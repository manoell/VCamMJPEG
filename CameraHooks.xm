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
    
    // Depois ativar o controlador com segurança
    @try {
        // Verificar se o tweak está ativado nas preferências compartilhadas
        BOOL isEnabled = [SharedPreferences isTweakEnabled];
        
        writeLog(@"[HOOK] Verificando status: SharedPreferences isEnabled=%d", isEnabled);
        
        if (isEnabled) {
            writeLog(@"[HOOK] Tweak está ativado, ativando VirtualCameraController");
            
            VirtualCameraController *controller = [VirtualCameraController sharedInstance];
            writeLog(@"[HOOK] Ativando VirtualCameraController após AVCaptureSession.startRunning");
            [controller startCapturing];
            
            // Registrar status atual
            writeLog(@"[HOOK] VirtualCameraController ativo: %d", controller.isActive);
            
            // Ativar conexão MJPEG se necessário
            MJPEGReader *reader = [MJPEGReader sharedInstance];
            if (!reader.isConnected) {
                NSString *serverURL = [SharedPreferences serverURL];
                if (serverURL) {
                    writeLog(@"[HOOK] Iniciando conexão MJPEG após AVCaptureSession.startRunning com URL: %@", serverURL);
                    [reader startStreamingFromURL:[NSURL URLWithString:serverURL]];
                } else {
                    writeLog(@"[HOOK] Não foi possível obter URL do servidor das preferências compartilhadas");
                }
            }
            
            writeLog(@"[HOOK] MJPEGReader conectado: %d", reader.isConnected);
        } else {
            writeLog(@"[HOOK] VirtualCameraController não foi ativado (Camera virtual desativada via SharedPreferences)");
        }
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
    
    %orig;
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
    // Verificar se somos um delegate de amostra de buffer
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        return %orig;
    }
    
    // Log do tipo de objeto para ajudar na depuração
    static BOOL loggedClass = NO;
    if (!loggedClass) {
        writeLog(@"[HOOK] captureOutput chamado em objeto do tipo: %@", NSStringFromClass([self class]));
        loggedClass = YES;
    }
    
    // Verificar se output é AVCaptureVideoDataOutput
    BOOL isVideoOutput = [output isKindOfClass:[AVCaptureVideoDataOutput class]];
    static BOOL loggedOutputType = NO;
    if (!loggedOutputType) {
        writeLog(@"[HOOK] captureOutput com output de tipo: %@, isVideoOutput=%d",
                 NSStringFromClass([output class]), isVideoOutput);
        loggedOutputType = YES;
    }
    
    // Verificar se a substituição da câmera está ativa
    BOOL isEnabled = [SharedPreferences isTweakEnabled];
    if (!isEnabled) {
        if (!loggedClass) {
            writeLog(@"[HOOK] Tweak não está ativado via SharedPreferences");
        }
        return %orig;
    }
    
    if (![[VirtualCameraController sharedInstance] isActive]) {
        if (!loggedClass) {
            writeLog(@"[HOOK] VirtualCameraController não está ativo");
        }
        return %orig;
    }
    
    // Apenas substituir frames de vídeo, não de áudio
    if (!isVideoOutput) {
        return %orig;
    }
    
    // Log para mostrar que estamos entrando na substituição
    static int frameReplaceCount = 0;
    if (++frameReplaceCount % 100 == 0) {
        writeLog(@"[HOOK] Substituindo frame #%d em captureOutput", frameReplaceCount);
    }
    
    // Obter informações de orientação do vídeo
    g_videoOrientation = (int)connection.videoOrientation;
    
    // Obter buffer de substituição com log
    CMSampleBufferRef mjpegBuffer = NULL;
    @try {
        mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
        
        if (frameReplaceCount == 1) {
            writeLog(@"[HOOK] getCurrentFrame retornou: %@", mjpegBuffer ? @"buffer válido" : @"NULL");
        }
    } @catch (NSException *e) {
        writeLog(@"[HOOK] Exceção ao chamar getCurrentFrame: %@", e);
    }
    
    if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
        // Log para primeiro frame substituído
        if (frameReplaceCount == 1) {
            writeLog(@"[HOOK] Primeiro frame substituído com sucesso!");
        }
        
        // Chamar o método original com o buffer MJPEG
        %orig(output, mjpegBuffer, connection);
        
        // Não liberar mjpegBuffer pois o método original vai usá-lo
    } else {
        // Se não conseguimos substituir, usar o original
        if (frameReplaceCount % 100 == 0 || frameReplaceCount == 1) {
            writeLog(@"[HOOK] Falha ao obter buffer MJPEG válido, usando original");
        }
        %orig;
    }
}

%end

%end // grupo CameraHooks

// Constructor específico deste arquivo
%ctor {
    %init(CameraHooks);
}
