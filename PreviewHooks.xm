#import "Tweak.h"

// Grupo para hooks relacionados ao preview
%group PreviewHooks

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
            
            // Configurar a camada para melhor desempenho
            [g_customDisplayLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
            [g_customDisplayLayer setOpaque:YES];
            [g_customDisplayLayer setContentsGravity:kCAGravityResizeAspectFill];
            
            // Configuração adicional para melhor desempenho
            g_customDisplayLayer.actions = @{
                @"bounds": [NSNull null],
                @"position": [NSNull null],
                @"transform": [NSNull null]
            };
        }
        
        // Adicionar nossas camadas
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_customDisplayLayer above:g_maskLayer];
        
        // Configurar DisplayLink para atualização periódica
        if (!g_displayLink) {
            g_displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
            [g_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
            
            // Configurar preferências para preview mais suave
            g_displayLink.preferredFramesPerSecond = 30;
        }
        
        // Atualizar frames e opacidade
        dispatch_async(dispatch_get_main_queue(), ^{
            g_customDisplayLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
            
            // Registrar para atualizações de layout quando necessário
            // Removi a linha problemática: self.layoutManager = self;
        });
        
        writeLog(@"[HOOK] Camadas customizadas adicionadas com sucesso");
    }
}

// Adicionar métodos para garantir que a layer se ajuste corretamente
- (void)layoutSublayers {
    if (g_customDisplayLayer) {
        g_customDisplayLayer.frame = self.bounds;
        g_maskLayer.frame = self.bounds;
    }
    %orig;
}

- (void)setBounds:(CGRect)bounds {
    %orig;
    if (g_customDisplayLayer) {
        g_customDisplayLayer.frame = bounds;
        g_maskLayer.frame = bounds;
    }
}

- (void)setFrame:(CGRect)frame {
    %orig;
    if (g_customDisplayLayer) {
        g_customDisplayLayer.frame = self.bounds;
        g_maskLayer.frame = self.bounds;
    }
}

- (void)setVideoGravity:(NSString *)videoGravity {
    %orig;
    if (g_customDisplayLayer) {
        [g_customDisplayLayer setVideoGravity:videoGravity];
    }
}

// Adicionar método step: para atualização periódica
%new
- (void)step:(CADisplayLink *)link {
    static int frameCount = 0;
    static CFTimeInterval lastTime = 0;
    
    // Verificar se o VirtualCameraController está ativo
    if (![[VirtualCameraController sharedInstance] isActive]) {
        [g_maskLayer setOpacity:0.0];
        [g_customDisplayLayer setOpacity:0.0];
        return;
    }
    
    // Calcular FPS real para depuração
    if (frameCount % 100 == 0) {
        CFTimeInterval currentTime = CACurrentMediaTime();
        if (lastTime != 0) {
            CFTimeInterval elapsed = currentTime - lastTime;
            float fps = 100.0f / elapsed;
            writeLog(@"[PREVIEW] FPS atual: %.1f", fps);
        }
        lastTime = currentTime;
    }
    
    // Atualizar visibilidade das camadas
    [g_maskLayer setOpacity:1.0];
    [g_customDisplayLayer setOpacity:1.0];
    
    // Garantir que a geometria da camada esteja atualizada
    CGRect currentBounds = self.bounds;
    if (!CGRectEqualToRect(g_customDisplayLayer.frame, currentBounds)) {
        g_customDisplayLayer.frame = currentBounds;
        g_maskLayer.frame = currentBounds;
    }
    
    // Aplicar videoGravity atual
    if (self.videoGravity) {
        [g_customDisplayLayer setVideoGravity:self.videoGravity];
    }
    
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
            
            frameCount++;
            
            // Log limitado para performance
            if (frameCount % 300 == 0) {
                // Verificar informações do buffer para diagnóstico
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
                if (imageBuffer) {
                    size_t width = CVPixelBufferGetWidth(imageBuffer);
                    size_t height = CVPixelBufferGetHeight(imageBuffer);
                    writeLog(@"[PREVIEW] Frame #%d injetado: %zu x %zu, orientação: %d",
                             frameCount, width, height, g_videoOrientation);
                }
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
    // Ignorar o hook para SpringBoard e para nossa própria camada de display
    if ([[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"] ||
        (g_customDisplayLayer && self == g_customDisplayLayer)) {
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
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(mjpegBuffer);
                if (imageBuffer) {
                    size_t width = CVPixelBufferGetWidth(imageBuffer);
                    size_t height = CVPixelBufferGetHeight(imageBuffer);
                    writeLog(@"[DISPLAY] Substituindo frame #%d em AVSampleBufferDisplayLayer (%zu x %zu)",
                             displayReplaceCount, width, height);
                }
            }
            
            // Preservar timestamp e duração do buffer original
            if (CMSampleBufferGetNumSamples(sampleBuffer) > 0) {
                CMTime origPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                CMTime origDuration = CMSampleBufferGetDuration(sampleBuffer);
                
                // Criar timing info baseado no buffer original
                CMSampleTimingInfo timing;
                timing.duration = origDuration;
                timing.presentationTimeStamp = origPTS;
                timing.decodeTimeStamp = kCMTimeInvalid;
                
                // Criar cópia do buffer MJPEG com timing do original
                CMSampleBufferRef syncedBuffer = NULL;
                OSStatus status = CMSampleBufferCreateCopyWithNewTiming(
                    kCFAllocatorDefault,
                    mjpegBuffer,
                    1,
                    &timing,
                    &syncedBuffer
                );
                
                if (status == noErr && syncedBuffer) {
                    // Usar o buffer sincronizado
                    %orig(syncedBuffer);
                    // Liberar o buffer sincronizado
                    CFRelease(syncedBuffer);
                } else {
                    // Se falhar, usar o buffer MJPEG original
                    %orig(mjpegBuffer);
                }
            } else {
                // Usar o buffer MJPEG diretamente se original não tiver samples
                %orig(mjpegBuffer);
            }
            
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
    %init(PreviewHooks);
}
