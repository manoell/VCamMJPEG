#import "GetFrame.h"
#import "MJPEGReader.h"
#import "logger.h"
#import "VirtualCameraController.h"

// Indica se alguma instância já está conectada
static BOOL gGlobalReaderConnected = NO;
// URL do servidor atual
static NSString *gCurrentServerURL = nil;

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
        config.timeoutIntervalForRequest = 30.0;
        config.timeoutIntervalForResource = 60.0;
        
        self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        self.buffer = [NSMutableData data];
        self.isConnected = NO;
        self.isReconnecting = NO;
        self.lastKnownResolution = CGSizeMake(1280, 720); // Resolução padrão
        self.currentURL = nil;
        self.lastReceivedSampleBuffer = NULL;
        
        // Criar a fila de processamento como variável de instância
        _processingQueue = dispatch_queue_create("com.vcam.mjpeg.processing", DISPATCH_QUEUE_SERIAL);
        
        // Verificar se alguma outra instância já está conectada
        if (gGlobalReaderConnected) {
            writeLog(@"[MJPEG] Outra instância já está conectada. Usando configuração global.");
            if (gCurrentServerURL) {
                writeLog(@"[MJPEG] Usando URL existente: %@", gCurrentServerURL);
                self.currentURL = [NSURL URLWithString:gCurrentServerURL];
                self.isConnected = YES;
            }
        }
    }
    return self;
}

- (void)startStreamingFromURL:(NSURL *)url {
    static NSLock *connectionLock = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        connectionLock = [[NSLock alloc] init];
    });
    
    [connectionLock lock];
    
    @try {
        // Se já existe uma conexão global ativa, não iniciar nova
        if (gGlobalReaderConnected && [url.absoluteString isEqualToString:gCurrentServerURL]) {
            writeLog(@"[MJPEG] Já existe uma conexão global ativa para %@", url.absoluteString);
            self.isConnected = YES;
            self.currentURL = url;
            [connectionLock unlock];
            return;
        }
        
        // Evitar múltiplas reconexões simultâneas
        if (self.isReconnecting) {
            writeLog(@"[MJPEG] Já está reconectando, ignorando solicitação para: %@", url.absoluteString);
            [connectionLock unlock];
            return;
        }
        
        self.isReconnecting = YES;
        
        // Se estiver conectado a outra URL, desconecta primeiro
        [self stopStreaming];
        
        // Armazena a URL atual globalmente
        self.currentURL = url;
        gCurrentServerURL = url.absoluteString;
        
        writeLog(@"[MJPEG] Iniciando streaming de: %@", url.absoluteString);
        
        self.buffer = [NSMutableData data];
        
        // Garantir que o callback esteja configurado
        if (!self.sampleBufferCallback) {
            writeLog(@"[MJPEG] sampleBufferCallback não estava configurado. Configurando para GetFrame.");
            // Removida a variável weakSelf não utilizada
            self.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
                // Enviar o buffer para GetFrame
                [[GetFrame sharedInstance] processNewMJPEGFrame:sampleBuffer];
            };
        }
        
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setValue:@"multipart/x-mixed-replace" forHTTPHeaderField:@"Accept"];
        [request setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
        [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
        
        self.dataTask = [self.session dataTaskWithRequest:request];
        [self.dataTask resume];
        
        gGlobalReaderConnected = YES;
        writeLog(@"[MJPEG] Tarefa de streaming iniciada");
    } @catch (NSException *exception) {
        writeLog(@"[MJPEG] Erro ao iniciar streaming: %@", exception.reason);
    } @finally {
        // Garantir que o estado de reconexão seja limpo após um tempo
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.isReconnecting = NO;
        });
        
        [connectionLock unlock];
    }
}

- (void)stopStreaming {
    @synchronized (self) {
        if (self.dataTask) {
            writeLog(@"[MJPEG] Parando streaming");
            [self.dataTask cancel];
            self.dataTask = nil;
            self.isConnected = NO;
            gGlobalReaderConnected = NO;
            gCurrentServerURL = nil;
        }
        
        if (self.lastReceivedSampleBuffer) {
            CFRelease(self.lastReceivedSampleBuffer);
            self.lastReceivedSampleBuffer = NULL;
        }
    }
}

- (void)dealloc {
    [self stopStreaming];
    
    if (self.lastReceivedSampleBuffer) {
        CFRelease(self.lastReceivedSampleBuffer);
        self.lastReceivedSampleBuffer = NULL;
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
        self.isReconnecting = NO;
        gGlobalReaderConnected = NO;
        
        if (self.lastReceivedSampleBuffer) {
            CFRelease(self.lastReceivedSampleBuffer);
            self.lastReceivedSampleBuffer = NULL;
        }
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    static BOOL isProcessingResponse = NO;
    
    if (!isProcessingResponse) {
        isProcessingResponse = YES;
        writeLog(@"[MJPEG] Conexão estabelecida com o servidor");
        
        self.isConnected = YES;
        self.isReconnecting = NO;
        gGlobalReaderConnected = YES;
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
    
    // Procurar o início e fim do JPEG de forma mais robusta
    for (NSUInteger i = 0; i < length - 1; i++) {
        // Detectar o início do JPEG (SOI marker: FF D8)
        if (bytes[i] == 0xFF && bytes[i+1] == 0xD8) {
            frameStart = i;
            foundJPEGStart = YES;
        }
        // Detectar o fim do JPEG (EOI marker: FF D9) apenas se já encontramos o início
        else if (foundJPEGStart && bytes[i] == 0xFF && bytes[i+1] == 0xD9) {
            NSUInteger frameEnd = i + 2; // Incluir o marcador EOI
            
            // Extrair os dados do JPEG completo
            NSData *jpegData = [self.buffer subdataWithRange:NSMakeRange(frameStart, frameEnd - frameStart)];
            
            // Processar o frame
            [self processJPEGData:jpegData];
            
            // Remover dados processados do buffer
            [self.buffer replaceBytesInRange:NSMakeRange(0, frameEnd) withBytes:NULL length:0];
            
            // Resetar para continuar procurando
            i = 0;
            length = self.buffer.length;
            bytes = (const uint8_t *)self.buffer.bytes;
            foundJPEGStart = NO;
            
            if (length <= 1) break;
        }
    }
    
    // Proteção para buffer muito grande sem frame completo
    if (self.buffer.length > 1024 * 1024) { // 1MB
        static BOOL loggedBufferReset = NO;
        if (!loggedBufferReset) {
            writeLog(@"[MJPEG] Buffer muito grande sem frame completo, resetando (1MB)");
            loggedBufferReset = YES;
            
            // Resetar após 5 segundos para permitir mais logs se ocorrer novamente
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                loggedBufferReset = NO;
            });
        }
        
        // Manter até 8KB no início do buffer por segurança, caso esteja no meio de um frame
        if (self.buffer.length > 8192) {
            [self.buffer replaceBytesInRange:NSMakeRange(8192, self.buffer.length - 8192) withBytes:NULL length:0];
        } else {
            [self.buffer setLength:0];
        }
    }
}

- (void)processJPEGData:(NSData *)jpegData {
    @autoreleasepool {
        // Adicionar log para saber se está recebendo frames - limitado a cada 300 frames
        static int frameCount = 0;
        frameCount++;
        if (frameCount % 300 == 0) {  // Log a cada 300 frames para não encher o log
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
            
            // Converter para CMSampleBuffer para uso com AVFoundation - MÉTODO CRÍTICO
            @try {
                CMSampleBufferRef sampleBuffer = [self createSampleBufferFromJPEGData:jpegData withSize:image.size];
                if (sampleBuffer) {
                    // Limitando o log para não lotar a saída
                    if (frameCount % 300 == 0) {
                        writeLog(@"[MJPEG] SampleBuffer criado e pronto para substituição (frame #%d)", frameCount);
                    }
                    
                    // Verificação extra de segurança
                    if (CMSampleBufferIsValid(sampleBuffer)) {
                        // Armazenar o buffer tanto localmente quanto no GetFrame
                        @synchronized(self) {
                            if (self.lastReceivedSampleBuffer) {
                                CFRelease(self.lastReceivedSampleBuffer);
                                self.lastReceivedSampleBuffer = NULL;
                            }
                            self.lastReceivedSampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
                        }
                        
                        // CRÍTICO: Enviar para o GetFrame para substituição global
                        [[GetFrame sharedInstance] processNewMJPEGFrame:sampleBuffer];
                        
                        // Chamar o callback original - com cópia do buffer
                        if (self.sampleBufferCallback) {
                            CMSampleBufferRef callbackBuffer = NULL;
                            OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &callbackBuffer);
                            
                            if (status == noErr && callbackBuffer != NULL) {
                                self.sampleBufferCallback(callbackBuffer);
                                CFRelease(callbackBuffer);
                            }
                        }
                        
                        CFRelease(sampleBuffer);
                    } else {
                        writeLog(@"[MJPEG] SampleBuffer gerado não é válido (frame #%d)", frameCount);
                        CFRelease(sampleBuffer);
                    }
                } else {
                    if (frameCount % 300 == 0) {
                        writeLog(@"[MJPEG] Falha ao criar sampleBuffer (frame #%d)", frameCount);
                    }
                }
            } @catch (NSException *e) {
                writeLog(@"[MJPEG] Exceção ao processar sampleBuffer: %@", e);
            }
            
        } else {
            writeLog(@"[MJPEG] Falha ao criar imagem a partir dos dados JPEG");
        }
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
    
    // Especificar propriedades do buffer para melhor compatibilidade
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}  // Melhora a compatibilidade
    };
    
    // Criar pixel buffer vazio
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                        size.width,
                                        size.height,
                                        kCVPixelFormatType_32BGRA,  // Formato mais compatível
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
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    // Configurar contexto para desenhar a imagem no buffer
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(baseAddress,
                                              size.width,
                                              size.height,
                                              8,
                                              bytesPerRow,
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
    
    // Desenhar a imagem no contexto com a orientação correta - ajuste importante
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
    
    // Criar uma referência de tempo precisa para o sample buffer
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
    
    // Log para depuração
    static int sampleBufferCount = 0;
    if (sampleBufferCount++ % 300 == 0) {
        writeLog(@"[MJPEG] SampleBuffer #%d criado com sucesso (dimensões: %.0f x %.0f)",
                sampleBufferCount, size.width, size.height);
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
        self.isReconnecting = NO;
        gGlobalReaderConnected = NO;
    }
}

@end
