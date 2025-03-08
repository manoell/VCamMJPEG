#import "Tweak.h"

// Grupo para hooks relacionados ao preview
%group PreviewHooks

// Hook para AVCaptureVideoPreviewLayer para adicionar nossa camada
%hook AVCaptureVideoPreviewLayer

- (void)addSublayer:(CALayer *)layer {
    %orig;
    
    // Verificar se o tweak está ativado
    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"VCamMJPEG_Enabled"];
    if (!isEnabled) {
        return;
    }
    
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
    static int stepCount = 0;
    BOOL isEnabled = [SharedPreferences isTweakEnabled];
    
    // Log a cada 300 frames
    if (++stepCount % 300 == 0) {
        writeLog(@"[PREVIEW] step: chamado %d vezes, isEnabled=%d, controller.isActive=%d",
                stepCount, isEnabled, [[VirtualCameraController sharedInstance] isActive]);
    }
    
    // Verificar se o tweak está ativado
    if (!isEnabled) {
        [g_maskLayer setOpacity:0.0];
        [g_customDisplayLayer setOpacity:0.0];
        return;
    }
    
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
                writeLog(@"[PREVIEW] Frame #%d injetado na camada personalizada", frameCount);
            }
            
            // Liberar o buffer após uso
            CFRelease(buffer);
        } else if (stepCount % 300 == 0) {
            writeLog(@"[PREVIEW] Falha ao obter buffer válido para preview");
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
    
    // Verificar se o tweak está ativado
    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"VCamMJPEG_Enabled"];
    if (!isEnabled) {
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

%end // grupo PreviewHooks

// Constructor específico deste arquivo
%ctor {
    // Inicializar os hooks só depois que tudo estiver carregado
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        %init(PreviewHooks);
    });
}
