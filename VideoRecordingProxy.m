#import "Tweak.h"

@implementation VideoRecordingProxy

+ (instancetype)proxyWithDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    VideoRecordingProxy *proxy = [[VideoRecordingProxy alloc] init];
    proxy.originalDelegate = delegate;
    return proxy;
}

#pragma mark - AVCaptureFileOutputRecordingDelegate Methods

// Método chamado quando a gravação começa
- (void)captureOutput:(AVCaptureFileOutput *)output didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections {
    writeLog(@"[VIDEOPROXY] didStartRecordingToOutputFileAtURL: %@", fileURL.absoluteString);
    
    // Ativar modo de vídeo otimizado
    if ([[VirtualCameraController sharedInstance] respondsToSelector:@selector(setOptimizedForVideo:)]) {
        [[VirtualCameraController sharedInstance] setOptimizedForVideo:YES];
    }
    
    // Ativar modo de alta prioridade para MJPEG
    [[MJPEGReader sharedInstance] setHighPriority:YES];
    
    // Redirecionar para o delegate original
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:)]) {
        [self.originalDelegate captureOutput:output didStartRecordingToOutputFileAtURL:fileURL fromConnections:connections];
    }
}

// Método chamado quando a gravação termina
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
    writeLog(@"[VIDEOPROXY] didFinishRecordingToOutputFileAtURL: %@, error: %@",
             outputFileURL.absoluteString, error ? error.localizedDescription : @"Sem erro");
    
    // Desativar modo de vídeo otimizado
    if ([[VirtualCameraController sharedInstance] respondsToSelector:@selector(setOptimizedForVideo:)]) {
        [[VirtualCameraController sharedInstance] setOptimizedForVideo:NO];
    }
    
    // Desativar modo de alta prioridade
    [[MJPEGReader sharedInstance] setHighPriority:NO];
    
    // Redirecionar para o delegate original
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:)]) {
        [self.originalDelegate captureOutput:output didFinishRecordingToOutputFileAtURL:outputFileURL fromConnections:connections error:error];
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
