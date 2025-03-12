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
    
    // Ativar modo de vídeo otimizado em todas as partes do sistema
    [[VirtualCameraController sharedInstance] setOptimizedForVideo:YES];
    
    // Ativar modo de alta prioridade para MJPEG
    [[MJPEGReader sharedInstance] setHighPriority:YES];
    
    // Ativar modo de processamento otimizado
    [[MJPEGReader sharedInstance] setProcessingMode:MJPEGReaderProcessingModeHighPerformance];
    
    // Definir flag global de gravação
    g_isRecordingVideo = YES;
    
    // Pré-carregar alguns frames para evitar delays no início da gravação
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        for (int i = 0; i < 5; i++) {
            [GetFrame getCurrentFrame:NULL replace:YES];
        }
    });
    
    // Verificar orientação da câmera e configurar corretamente para o vídeo
    for (AVCaptureConnection *connection in connections) {
        if ([connection isVideoOrientationSupported]) {
            AVCaptureVideoOrientation orientation = connection.videoOrientation;
            g_videoOrientation = (int)orientation;
            g_isVideoOrientationSet = YES;
            
            writeLog(@"[VIDEOPROXY] Orientação da câmera para gravação: %d", (int)orientation);
            
            // Forçar a mesma orientação para todos os componentes do sistema
            [[VirtualCameraController sharedInstance] setCurrentVideoOrientation:(int)orientation];
        }
    }
    
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
    [[VirtualCameraController sharedInstance] setOptimizedForVideo:NO];
    
    // Desativar modo de alta prioridade
    [[MJPEGReader sharedInstance] setHighPriority:NO];
    
    // Voltar ao modo de processamento normal
    [[MJPEGReader sharedInstance] setProcessingMode:MJPEGReaderProcessingModeDefault];
    
    // Desativar flag global de gravação
    g_isRecordingVideo = NO;
    
    // Limpar quaisquer buffers temporários usados durante a gravação
    [GetFrame flushVideoBuffers];
    
    // Verificar se há erro no arquivo final
    if (error) {
        writeLog(@"[VIDEOPROXY] Erro na gravação do vídeo: %@", error.localizedDescription);
        
        // Verificar se o arquivo existe
        BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:outputFileURL.path];
        writeLog(@"[VIDEOPROXY] Arquivo de vídeo existe: %@", fileExists ? @"Sim" : @"Não");
        
        // Verificar o tamanho do arquivo
        if (fileExists) {
            NSError *attrError = nil;
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:outputFileURL.path error:&attrError];
            if (!attrError) {
                NSNumber *fileSize = attributes[NSFileSize];
                writeLog(@"[VIDEOPROXY] Tamanho do arquivo de vídeo: %@ bytes", fileSize);
            }
        }
    }
    
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
