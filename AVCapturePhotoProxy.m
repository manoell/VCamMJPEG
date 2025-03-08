#import "Tweak.h"

@implementation AVCapturePhotoProxy

+ (instancetype)proxyWithDelegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    AVCapturePhotoProxy *proxy = [[AVCapturePhotoProxy alloc] init];
    proxy.originalDelegate = delegate;
    return proxy;
}

#pragma mark - AVCapturePhotoCaptureDelegate Methods

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// iOS 10+
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)photoSampleBuffer previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings bracketSettings:(AVCaptureBracketedStillImageSettings *)bracketSettings error:(NSError *)error {
    
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:)]) {
        
        writeLog(@"[PHOTOPROXY] Interceptando didFinishProcessingPhotoSampleBuffer");
        
        // Obter buffer de substituição apenas se VirtualCameraController estiver ativo
        if ([[VirtualCameraController sharedInstance] isActive]) {
            CMSampleBufferRef mjpegBuffer = photoSampleBuffer ? [GetFrame getCurrentFrame:photoSampleBuffer replace:YES] : nil;
            
            if (mjpegBuffer && CMSampleBufferIsValid(mjpegBuffer)) {
                writeLog(@"[PHOTOPROXY] Substituindo buffer na finalização da captura de foto");
                
                // Sinalizar que estamos capturando foto para que UIHooks possa aplicar a orientação correta
                g_isCapturingPhoto = YES;
                
                [self.originalDelegate captureOutput:output
                    didFinishProcessingPhotoSampleBuffer:mjpegBuffer
                           previewPhotoSampleBuffer:previewPhotoSampleBuffer
                                 resolvedSettings:resolvedSettings
                                  bracketSettings:bracketSettings
                                           error:error];
                
                // Limpar flag após processamento
                g_isCapturingPhoto = NO;
            } else {
                [self.originalDelegate captureOutput:output
                    didFinishProcessingPhotoSampleBuffer:photoSampleBuffer
                           previewPhotoSampleBuffer:previewPhotoSampleBuffer
                                 resolvedSettings:resolvedSettings
                                  bracketSettings:bracketSettings
                                           error:error];
            }
        } else {
            // Se não estiver ativo, apenas passar adiante sem modificar
            [self.originalDelegate captureOutput:output
                didFinishProcessingPhotoSampleBuffer:photoSampleBuffer
                       previewPhotoSampleBuffer:previewPhotoSampleBuffer
                             resolvedSettings:resolvedSettings
                              bracketSettings:bracketSettings
                                       error:error];
        }
    }
}
#pragma clang diagnostic pop

// iOS 11+
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
        
        writeLog(@"[PHOTOPROXY] Interceptando didFinishProcessingPhoto");
        
        // Como não podemos modificar o AVCapturePhoto diretamente,
        // apenas sinalizamos que estamos capturando foto para que os hooks de imagem possam aplicar
        if ([[VirtualCameraController sharedInstance] isActive]) {
            g_isCapturingPhoto = YES;
            [self.originalDelegate captureOutput:output didFinishProcessingPhoto:photo error:error];
            g_isCapturingPhoto = NO;
        } else {
            [self.originalDelegate captureOutput:output didFinishProcessingPhoto:photo error:error];
        }
    }
}

// Método para encaminhar mensagens desconhecidas para o delegate original
- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.originalDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.originalDelegate respondsToSelector:aSelector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:aSelector];
}

@end
