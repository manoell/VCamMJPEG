#import "MJPEGReader.h"
#import "logger.h"
#import "VirtualCameraController.h"

@interface MJPEGReader ()
// Usar um tipo normal em vez de property para dispatch_queue_t
{
    dispatch_queue_t _processingQueue;
}
@end

@implementation MJPEGReader

+ (instancetype)sharedInstance {
    static MJPEGReader *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30.0;  // Aumentado de 10 para 30 segundos
        config.timeoutIntervalForResource = 60.0; // Aumentado de 30 para 60 segundos
        
        self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        self.buffer = [NSMutableData data];
        self.isConnected = NO;
        self.lastKnownResolution = CGSizeMake(1280, 720); // Resolução padrão
        
        // Criar a fila de processamento como variável de instância, não como propriedade
        _processingQueue = dispatch_queue_create("com.vcam.mjpeg.processing", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startStreamingFromURL:(NSURL *)url {
    writeLog(@"[MJPEG] Iniciando streaming de: %@", url.absoluteString);
    
    [self stopStreaming];
    
    self.buffer = [NSMutableData data];
    
    // IMPORTANTE: Garantir que o callback esteja configurado
    if (!self.sampleBufferCallback) {
        writeLog(@"[MJPEG] sampleBufferCallback não estava configurado. Configurando manualmente.");
        self.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
            [[VirtualCameraController sharedInstance] processSampleBuffer:sampleBuffer];
        };
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"multipart/x-mixed-replace" forHTTPHeaderField:@"Accept"];
    
    // Adicionar headers otimizados
    [request setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    
    self.dataTask = [self.session dataTaskWithRequest:request];
    [self.dataTask resume];
    
    writeLog(@"[MJPEG] Tarefa de streaming iniciada");
}

- (void)stopStreaming {
    @synchronized (self) {
        if (self.dataTask) {
            writeLog(@"[MJPEG] Parando streaming");
            [self.dataTask cancel];
            self.dataTask = nil;
            self.isConnected = NO;
        }
    }
}

- (void)resetWithError:(NSError *)error {
    writeLog(@"[MJPEG] Resetando leitor devido a erro: %@", error.localizedDescription);
    
    @synchronized (self) {
        // Parar task atual
        if (self.dataTask) {
            [self.dataTask cancel];
            self.dataTask = nil;
        }
        
        // Limpar buffer
        [self.buffer setLength:0];
        
        // Redefinir estado
        self.isConnected = NO;
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    static BOOL isProcessingResponse = NO;
    
    if (!isProcessingResponse) {
        isProcessingResponse = YES;
        writeLog(@"[MJPEG] Conexão estabelecida com o servidor");
        
        self.isConnected = YES;
        [self.buffer setLength:0];
        
        // Reset após 5 segundos
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isProcessingResponse = NO;
        });
    }
    
    completionHandler(NSURLSessionResponseAllow);
}

// Detecta os marcadores JPEG para extrair as imagens do stream
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    // Processar em fila separada para evitar bloqueio da rede
    dispatch_async(_processingQueue, ^{
        @synchronized (self) {
            // Verificar se a conexão ainda está ativa
            if (!self.isConnected) return;
            
            // Adicionar novos dados ao buffer
            [self.buffer appendData:data];
            
            // Processar dados recebidos - procurar por frames JPEG
            [self processReceivedData];
        }
    });
}

- (void)processReceivedData {
    NSUInteger length = self.buffer.length;
    const uint8_t *bytes = (const uint8_t *)self.buffer.bytes;
    
    BOOL foundJPEGStart = NO;
    NSUInteger frameStart = 0;
    
    // Procurar o início e fim do JPEG
    for (NSUInteger i = 0; i < length - 1; i++) {
        if (bytes[i] == 0xFF && bytes[i+1] == 0xD8) { // SOI marker
            frameStart = i;
            foundJPEGStart = YES;
        }
        else if (foundJPEGStart && bytes[i] == 0xFF && bytes[i+1] == 0xD9) { // EOI marker
            NSUInteger frameEnd = i + 2;
            NSData *jpegData = [self.buffer subdataWithRange:NSMakeRange(frameStart, frameEnd - frameStart)];
            
            // Processar o frame
            [self processJPEGData:jpegData];
            
            // Remover dados processados
            [self.buffer replaceBytesInRange:NSMakeRange(0, frameEnd) withBytes:NULL length:0];
            
            // Reiniciar a busca
            i = 0;
            length = self.buffer.length;
            bytes = (const uint8_t *)self.buffer.bytes;
            foundJPEGStart = NO;
            
            if (length <= 1) break;
        }
    }
    
    // Proteção para buffer muito grande sem frame completo
    if (self.buffer.length > 1024 * 1024) { // 1MB
        writeLog(@"[MJPEG] Buffer muito grande, resetando");
        [self.buffer setLength:0];
    }
}

- (void)processJPEGData:(NSData *)jpegData {
    // Adicionar log para saber se está recebendo frames
    static int frameCount = 0;
    frameCount++;
    if (frameCount % 30 == 0) {  // Log a cada 30 frames para não encher o log
        writeLog(@"[MJPEG] Processado frame #%d (%d bytes)", frameCount, (int)jpegData.length);
    }
    
    // Criar imagem a partir dos dados JPEG
    UIImage *image = [UIImage imageWithData:jpegData];
    
    if (image) {
        // Atualizar resolução conhecida
        if (!CGSizeEqualToSize(image.size, self.lastKnownResolution)) {
            self.lastKnownResolution = image.size;
            writeLog(@"[MJPEG] Nova resolução detectada: %.0f x %.0f", image.size.width, image.size.height);
        }
        
        // Chamar callback de frame se existir (para preview)
        if (self.frameCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.frameCallback(image);
            });
        }
        
        // Converter para CMSampleBuffer para uso com AVFoundation
        if (self.sampleBufferCallback) {
            CMSampleBufferRef sampleBuffer = [self createSampleBufferFromJPEGData:jpegData withSize:image.size];
            if (sampleBuffer) {
                writeLog(@"[MJPEG] SampleBuffer criado e pronto para substituição");
                self.sampleBufferCallback(sampleBuffer);
                CFRelease(sampleBuffer);
            } else {
                writeLog(@"[MJPEG] Falha ao criar sampleBuffer");
            }
        } else {
            static BOOL loggedMissingSampleBufferCallback = NO;
            if (!loggedMissingSampleBufferCallback) {
                writeLog(@"[MJPEG] sampleBufferCallback não configurado!");
                loggedMissingSampleBufferCallback = YES;
                
                // Resetar flag após período para permitir novos logs se necessário
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    loggedMissingSampleBufferCallback = NO;
                });
            }
        }
    } else {
        writeLog(@"[MJPEG] Falha ao criar imagem a partir dos dados JPEG");
    }
}

// Método para criar um CMSampleBuffer a partir de dados JPEG
- (CMSampleBufferRef)createSampleBufferFromJPEGData:(NSData *)jpegData withSize:(CGSize)size {
    if (!jpegData || jpegData.length == 0) {
        writeLog(@"[MJPEG] Dados JPEG inválidos");
        return NULL;
    }
    
    // Criar um CVPixelBuffer
    CVPixelBufferRef pixelBuffer = NULL;
    
    // Especificar propriedades do buffer
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    
    // Criar pixel buffer vazio
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                        size.width,
                                        size.height,
                                        kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)options,
                                        &pixelBuffer);
    
    if (status != kCVReturnSuccess) {
        writeLog(@"[MJPEG] Falha ao criar CVPixelBuffer: %d", status);
        return NULL;
    }
    
    // Criar uma imagem CGImage a partir dos dados JPEG
    CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, jpegData.bytes, jpegData.length, NULL);
    CGImageRef cgImage = CGImageCreateWithJPEGDataProvider(dataProvider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(dataProvider);
    
    if (cgImage == NULL) {
        CVPixelBufferRelease(pixelBuffer);
        writeLog(@"[MJPEG] Falha ao criar CGImage");
        return NULL;
    }
    
    // Bloquear o buffer para escrita
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    // Obter o ponteiro para os dados do buffer
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    
    // Configurar contexto para desenhar a imagem no buffer
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(baseAddress,
                                              size.width,
                                              size.height,
                                              8,
                                              CVPixelBufferGetBytesPerRow(pixelBuffer),
                                              colorSpace,
                                              kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    
    if (context == NULL) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        CGImageRelease(cgImage);
        writeLog(@"[MJPEG] Falha ao criar contexto de bitmap");
        return NULL;
    }
    
    // Desenhar a imagem no contexto
    CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), cgImage);
    
    // Liberar recursos
    CGContextRelease(context);
    CGImageRelease(cgImage);
    
    // Desbloquear o buffer
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    // Criar referência ao formato de vídeo
    CMFormatDescriptionRef formatDescription = NULL;
    status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    
    if (status != noErr) {
        CVPixelBufferRelease(pixelBuffer);
        writeLog(@"[MJPEG] Falha ao criar descrição de formato: %d", status);
        return NULL;
    }
    
    // Criar referência de tempo para o sample buffer
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, 30); // 30 fps
    timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000);
    timing.decodeTimeStamp = kCMTimeInvalid;
    
    // Criar o sample buffer final
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        true,
        NULL,
        NULL,
        formatDescription,
        &timing,
        &sampleBuffer
    );
    
    // Liberar recursos
    CFRelease(formatDescription);
    CVPixelBufferRelease(pixelBuffer);
    
    if (status != noErr || !sampleBuffer) {
        writeLog(@"[MJPEG] Falha ao criar sample buffer: %d", status);
        return NULL;
    }
    
    return sampleBuffer;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        if (error.code != NSURLErrorCancelled) { // Ignore cancelamento intencional
            writeLog(@"[MJPEG] Erro no streaming: %@", error);
            [self resetWithError:error];
        }
    } else {
        writeLog(@"[MJPEG] Streaming concluído");
        self.isConnected = NO;
    }
}

@end
