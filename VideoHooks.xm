#import "Tweak.h"

// Grupo para hooks relacionados à gravação de vídeo
%group VideoHooks

// Hook para AVCaptureMovieFileOutput para interceptar gravação de vídeo
%hook AVCaptureMovieFileOutput

- (void)startRecordingToOutputFileURL:(NSURL *)outputFileURL recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    writeLog(@"[VIDEOHOOK] startRecordingToOutputFileURL foi chamado (URL: %@)", outputFileURL.absoluteString);
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    // Configuração para o modo de alta prioridade durante a gravação
    [[MJPEGReader sharedInstance] setHighPriority:YES];
    
    // Criar proxy para o delegate de gravação se ainda não existe
    id<AVCaptureFileOutputRecordingDelegate> proxyDelegate = objc_getAssociatedObject(delegate, "VideoRecordingProxyDelegate");
    
    if (!proxyDelegate) {
        writeLog(@"[VIDEOHOOK] Criando proxy para gravação de vídeo");
        proxyDelegate = [VideoRecordingProxy proxyWithDelegate:delegate];
        
        // Associar o proxy para referência futura
        objc_setAssociatedObject(delegate, "VideoRecordingProxyDelegate", proxyDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(proxyDelegate, "OriginalVideoDelegate", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    writeLog(@"[VIDEOHOOK] Iniciando gravação com modo de alta prioridade");
    
    // Informar ao VirtualCameraController que estamos gravando vídeo
    [[VirtualCameraController sharedInstance] setIsRecordingVideo:YES];
    g_isRecordingVideo = YES;
    
    // Chamar o método original com nosso proxy
    %orig(outputFileURL, proxyDelegate);
}

- (void)stopRecording {
    writeLog(@"[VIDEOHOOK] stopRecording foi chamado");
    
    // Restaurar para o modo normal após encerrar a gravação
    [[MJPEGReader sharedInstance] setHighPriority:NO];
    
    // Informar ao VirtualCameraController que paramos de gravar
    [[VirtualCameraController sharedInstance] setIsRecordingVideo:NO];
    g_isRecordingVideo = NO;
    
    // Chamar o método original
    %orig;
}

// HOOK CRÍTICO: Este é o método que realmente envia os frames para gravação
- (void)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(NSString *)mediaType {
    // Verificar se estamos gravando vídeo e se a substituição está ativa
    if (!g_isRecordingVideo || ![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    // Se não for vídeo, passar adiante sem modificar
    if (![mediaType isEqualToString:AVMediaTypeVideo]) {
        %orig;
        return;
    }
    
    // Log limitado para não impactar performance
    static int frameCount = 0;
    BOOL logFrame = (++frameCount % 100 == 0);
    
    if (logFrame) {
        writeLog(@"[VIDEOHOOK-CRITICAL] appendSampleBuffer:ofType:%@ interceptado, frame #%d", mediaType, frameCount);
    }
    
    // Obter buffer MJPEG para substituição
    CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
    
    if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
        // Criar um buffer compatível com o timing do buffer original
        CMSampleBufferRef syncedBuffer = NULL;
        
        @try {
            // Copiar timing do buffer original
            CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
            
            // Criar timing info para sincronização - Correção da inicialização
            CMSampleTimingInfo timing = {
                .duration = duration,
                .presentationTimeStamp = presentationTime,
                .decodeTimeStamp = kCMTimeInvalid
            };
            
            // Criar novo buffer com timing sincronizado
            OSStatus status = CMSampleBufferCreateCopyWithNewTiming(
                kCFAllocatorDefault,
                mjpegBuffer,
                1,
                &timing,
                &syncedBuffer
            );
            
            if (status == noErr && syncedBuffer != NULL) {
                // Transferir metadados importantes
                // Orientação
                CFTypeRef orientationAttachment = CMGetAttachment(sampleBuffer, CFSTR("VideoOrientation"), NULL);
                if (orientationAttachment) {
                    CMSetAttachment(syncedBuffer, CFSTR("VideoOrientation"),
                                  orientationAttachment, kCMAttachmentMode_ShouldPropagate);
                } else if (g_isVideoOrientationSet) {
                    // Se não tem orientação no buffer original, mas temos a orientação global
                    uint32_t orientation = g_videoOrientation;
                    CFNumberRef orientationValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &orientation);
                    if (orientationValue) {
                        CMSetAttachment(syncedBuffer, CFSTR("VideoOrientation"), orientationValue, kCMAttachmentMode_ShouldPropagate);
                        CFRelease(orientationValue);
                    }
                }
                
                // Outros metadados importantes
                NSArray *metadataKeys = @[
                    (id)CFSTR("CVImageBufferYCbCrMatrix"),
                    (id)CFSTR("CVImageBufferColorPrimaries"),
                    (id)CFSTR("CVImageBufferTransferFunction"),
                    (id)CFSTR("CVFieldCount"),
                    (id)CFSTR("CVFieldDetail")
                ];
                
                for (id key in metadataKeys) {
                    CFTypeRef attachment = CMGetAttachment(sampleBuffer, (CFStringRef)key, NULL);
                    if (attachment) {
                        CMSetAttachment(syncedBuffer, (CFStringRef)key,
                                      attachment, kCMAttachmentMode_ShouldPropagate);
                    }
                }
                
                if (logFrame) {
                    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(syncedBuffer);
                    if (imageBuffer) {
                        size_t width = CVPixelBufferGetWidth(imageBuffer);
                        size_t height = CVPixelBufferGetHeight(imageBuffer);
                        writeLog(@"[VIDEOHOOK-CRITICAL] Substituindo buffer para gravação: %zu x %zu", width, height);
                    }
                }
                
                // Chamar o método original com o buffer substituído
                %orig(syncedBuffer, mediaType);
                
                // Liberar o buffer após uso
                CFRelease(syncedBuffer);
                CFRelease(mjpegBuffer);
                
                return;
            }
        } @catch (NSException *e) {
            writeLog(@"[VIDEOHOOK-CRITICAL] Erro ao sincronizar buffer: %@", e);
        }
        
        // Se não conseguimos sincronizar, liberar o buffer MJPEG
        CFRelease(mjpegBuffer);
    }
    
    // Se chegamos aqui, usamos o buffer original
    %orig;
}

%end

// Hook para AVCaptureVideoDataOutput para entender configurações
%hook AVCaptureVideoDataOutput

- (void)setVideoSettings:(NSDictionary<NSString *,id> *)videoSettings {
    // Registrar as configurações originais para diagnóstico
    writeLog(@"[VIDEOHOOK] setVideoSettings: %@", videoSettings);
    
    // Se não estiver ativo, apenas chamar o método original
    if (![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    // Obter o formato de pixel do diagnóstico (420f = 875704422)
    NSNumber *pixelFormat = videoSettings[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey];
    if (pixelFormat) {
        writeLog(@"[VIDEOHOOK] Formato de pixel para gravação: %@", pixelFormat);
    }
    
    // Chamar o original sem modificações por enquanto
    %orig;
}

%end

// Hook específico para o ponto onde os frames são processados para gravação em iOS 14+
%hook AVCaptureMovieFileOutputInternal

// Método crítico na gravação onde os buffers são processados para gravação
- (void)_processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(id)connection {
    // Verificar se estamos gravando vídeo e se a substituição está ativa
    if (!g_isRecordingVideo || ![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    // Verificar se o buffer é válido
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
        %orig;
        return;
    }
    
    // Log limitado para não impactar performance
    static int frameCount = 0;
    BOOL logFrame = (++frameCount % 100 == 0);
    
    if (logFrame) {
        writeLog(@"[VIDEOHOOK-INTERNAL] _processVideoSampleBuffer interceptado, frame #%d", frameCount);
    }
    
    // Obter buffer MJPEG para substituição
    CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
    
    if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
        // Converter para buffer compatível com o timing original
        CMSampleBufferRef syncedBuffer = [VirtualCameraFeedReplacer replaceCameraSampleBuffer:sampleBuffer
                                                                              withMJPEGBuffer:mjpegBuffer];
        
        if (syncedBuffer) {
            if (logFrame) {
                writeLog(@"[VIDEOHOOK-INTERNAL] Substituindo buffer para processamento interno de vídeo");
            }
            
            // Chamar o método original com o buffer substituído
            %orig(syncedBuffer, connection);
            
            // Liberar buffers
            if (syncedBuffer != mjpegBuffer) {
                CFRelease(syncedBuffer);
            }
            CFRelease(mjpegBuffer);
            
            return;
        }
        
        // Se não conseguimos sincronizar, liberar o buffer MJPEG
        CFRelease(mjpegBuffer);
    }
    
    // Fallback para o buffer original
    %orig;
}

%end

// Hook usado para acesso de baixo nível em algumas versões do iOS
%hook AVCaptureSession

// Método interno para processar os frames de vídeo
- (void)_captureOutput:(id)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(id)connection {
    // Verificar se estamos gravando vídeo e se a substituição está ativa
    if (!g_isRecordingVideo || ![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    // Verificar se o buffer é válido
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
        %orig;
        return;
    }
    
    // Log limitado para não impactar performance
    static int frameCount = 0;
    BOOL logFrame = (++frameCount % 100 == 0);
    
    // Verificar se é um buffer de vídeo
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (formatDesc) {
        FourCharCode mediaType = CMFormatDescriptionGetMediaType(formatDesc);
        if (mediaType == kCMMediaType_Video) {
            if (logFrame) {
                writeLog(@"[VIDEOHOOK-SESSION] _captureOutput:didOutputSampleBuffer: interceptado, frame #%d", frameCount);
            }
            
            // Obter buffer MJPEG para substituição
            CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
            
            if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
                // Converter para buffer compatível com o timing original
                CMSampleBufferRef syncedBuffer = [VirtualCameraFeedReplacer replaceCameraSampleBuffer:sampleBuffer
                                                                                       withMJPEGBuffer:mjpegBuffer];
                
                if (syncedBuffer) {
                    if (logFrame) {
                        writeLog(@"[VIDEOHOOK-SESSION] Substituindo buffer para processamento da sessão");
                    }
                    
                    // Chamar o método original com o buffer substituído
                    %orig(output, syncedBuffer, connection);
                    
                    // Liberar buffers
                    if (syncedBuffer != mjpegBuffer) {
                        CFRelease(syncedBuffer);
                    }
                    CFRelease(mjpegBuffer);
                    
                    return;
                }
                
                // Se não conseguimos sincronizar, liberar o buffer MJPEG
                CFRelease(mjpegBuffer);
            }
        }
    }
    
    // Fallback para o buffer original
    %orig;
}

%end

// Hook para interface genérica de recebimento de frames via AVFoundation
%hook NSObject

// Este método é implementado por várias classes que processam frames de vídeo
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Verificar se somos uma classe que captura vídeo
    if (![self respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        return %orig;
    }
    
    // Verificar se estamos gravando vídeo e se a substituição está ativa
    if (!g_isRecordingVideo || ![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Verificar se o buffer é válido
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
        return %orig;
    }
    
    // Verificar se é um buffer de vídeo
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDesc) {
        return %orig;
    }
    
    FourCharCode mediaType = CMFormatDescriptionGetMediaType(formatDesc);
    if (mediaType != kCMMediaType_Video) {
        return %orig; // Não é vídeo, passamos adiante sem modificar
    }
    
    // Log limitado para não impactar performance
    static int frameCount = 0;
    BOOL logFrame = (++frameCount % 100 == 0);
    
    if (logFrame) {
        writeLog(@"[VIDEOHOOK-DELEGATE] captureOutput:didOutputSampleBuffer: interceptado, frame #%d", frameCount);
    }
    
    // Obter buffer MJPEG para substituição
    CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
    
    if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
        // Converter para buffer compatível com o timing original
        CMSampleBufferRef syncedBuffer = [VirtualCameraFeedReplacer replaceCameraSampleBuffer:sampleBuffer
                                                                                withMJPEGBuffer:mjpegBuffer];
        
        if (syncedBuffer) {
            if (logFrame) {
                writeLog(@"[VIDEOHOOK-DELEGATE] Substituindo buffer para delegate");
            }
            
            // Chamar o método original com o buffer substituído
            %orig(output, syncedBuffer, connection);
            
            // Liberar buffers
            if (syncedBuffer != mjpegBuffer) {
                CFRelease(syncedBuffer);
            }
            CFRelease(mjpegBuffer);
            
            return;
        }
        
        // Se não conseguimos sincronizar, liberar o buffer MJPEG
        CFRelease(mjpegBuffer);
    }
    
    // Fallback para o buffer original
    %orig;
}

%end

// Hook específico para classe AVCaptureRecordingFileOutputRecordingDelegate
// que é usada internamente pelo AVFoundation
%hook AVCaptureRecordingFileOutputRecordingDelegate

// Método interno que processa os frames para gravação
- (void)_outputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Verificar se estamos gravando vídeo e se a substituição está ativa
    if (!g_isRecordingVideo || ![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    // Verificar se o buffer é válido
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
        %orig;
        return;
    }
    
    // Verificar se é um buffer de vídeo
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDesc) {
        %orig;
        return;
    }
    
    FourCharCode mediaType = CMFormatDescriptionGetMediaType(formatDesc);
    if (mediaType != kCMMediaType_Video) {
        %orig; // Não é vídeo, passamos adiante sem modificar
        return;
    }
    
    // Log limitado para não impactar performance
    static int frameCount = 0;
    BOOL logFrame = (++frameCount % 100 == 0);
    
    if (logFrame) {
        writeLog(@"[VIDEOHOOK-OUTPUT] _outputSampleBuffer: interceptado, frame #%d", frameCount);
    }
    
    // Obter buffer MJPEG para substituição
    CMSampleBufferRef mjpegBuffer = [GetFrame getCurrentFrame:sampleBuffer replace:YES];
    
    if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
        // Converter para buffer compatível com o timing original
        CMSampleBufferRef syncedBuffer = [VirtualCameraFeedReplacer replaceCameraSampleBuffer:sampleBuffer
                                                                                withMJPEGBuffer:mjpegBuffer];
        
        if (syncedBuffer) {
            if (logFrame) {
                writeLog(@"[VIDEOHOOK-OUTPUT] Substituindo buffer para output");
            }
            
            // Chamar o método original com o buffer substituído
            %orig(syncedBuffer);
            
            // Liberar buffers
            if (syncedBuffer != mjpegBuffer) {
                CFRelease(syncedBuffer);
            }
            CFRelease(mjpegBuffer);
            
            return;
        }
        
        // Se não conseguimos sincronizar, liberar o buffer MJPEG
        CFRelease(mjpegBuffer);
    }
    
    // Fallback para o buffer original
    %orig;
}

%end

%end // fim do grupo VideoHooks

// Constructor específico deste arquivo
%ctor {
    %init(VideoHooks);
}
