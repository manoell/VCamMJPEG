#import "GetFrame.h"
#import "MJPEGReader.h"
#import "logger.h"
#import "VirtualCameraController.h"
#import "Globals.h"

// Indica se alguma instância já está conectada
static BOOL gGlobalReaderConnected = NO;
// URL do servidor atual
static NSString *gCurrentServerURL = nil;

// Limites de tamanho de buffer para segurança
static const NSUInteger kMaxBufferSize = 10 * 1024 * 1024; // 10MB
static const NSUInteger kResetBufferSize = 64 * 1024; // 64KB
static const NSUInteger kInitialBufferSize = 1024 * 1024; // 1MB

@interface MJPEGReader ()
// Usar um tipo normal em vez de property para dispatch_queue_t
{
    dispatch_queue_t _processingQueue;
    dispatch_queue_t _highPriorityQueue; // Nova fila de alta prioridade
    dispatch_queue_t _imageProcessingQueue; // Fila para processamento de imagem
}

// Propriedades privadas
@property (nonatomic, assign) NSTimeInterval lastFrameTime;
@property (nonatomic, assign) NSInteger frameProcessedCount;
@property (nonatomic, assign) CGFloat currentFPS;
@property (nonatomic, strong) NSLock *bufferLock;

// Cache para processamento mais rápido
@property (nonatomic, strong) NSCache *formatsCache;
@property (nonatomic, strong) CVPixelBufferPoolRef pixelBufferPool;

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
        
        // Otimizar configuração de rede
        config.HTTPMaximumConnectionsPerHost = 5; // Aumentar conexões por host
        config.HTTPShouldUsePipelining = YES; // Usar HTTP pipelining quando possível
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData; // Evitar cache para streaming
        config.waitsForConnectivity = YES; // iOS 11+ - esperar por conectividade
        
        // Aumentar timeouts para melhor tolerância
        config.timeoutIntervalForRequest = 60.0;
        config.timeoutIntervalForResource = 300.0;
        
        self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        self.buffer = [NSMutableData dataWithCapacity:kInitialBufferSize];
        self.isConnected = NO;
        self.isReconnecting = NO;
        self.lastKnownResolution = CGSizeMake(1280, 720); // Resolução padrão
        self.currentURL = nil;
        self.lastReceivedSampleBuffer = NULL;
        self.highPriorityMode = NO;
        self.bufferLock = [[NSLock alloc] init];
        self.processingMode = MJPEGReaderProcessingModeDefault;
        
        // Inicializar cache
        self.formatsCache = [[NSCache alloc] init];
        self.formatsCache.countLimit = 5; // Limita a 5 formatos diferentes
        
        // Inicializar contadores FPS
        self.lastFrameTime = CACurrentMediaTime();
        self.frameProcessedCount = 0;
        self.currentFPS = 0;
        
        // Criar as filas de processamento como variáveis de instância
        _processingQueue = dispatch_queue_create("com.vcam.mjpeg.processing", DISPATCH_QUEUE_SERIAL);
        
        // Fila para processamento de alta prioridade
        _highPriorityQueue = dispatch_queue_create("com.vcam.mjpeg.highpriority", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_highPriorityQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        
        // Fila específica para processamento de imagem
        _imageProcessingQueue = dispatch_queue_create("com.vcam.mjpeg.image", DISPATCH_QUEUE_CONCURRENT);
        
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

- (void)dealloc {
    [self stopStreaming];
    
    if (self.lastReceivedSampleBuffer) {
        CFRelease(self.lastReceivedSampleBuffer);
        self.lastReceivedSampleBuffer = NULL;
    }
    
    if (self.pixelBufferPool) {
        CVPixelBufferPoolRelease(self.pixelBufferPool);
        self.pixelBufferPool = NULL;
    }
}

- (void)setHighPriority:(BOOL)enabled {
    self.highPriorityMode = enabled;
    writeLog(@"[MJPEG] Modo de alta prioridade %@", enabled ? @"ATIVADO" : @"DESATIVADO");
    
    // Se o modo de alta prioridade for ativado, também ajustamos a prioridade da task
    if (self.dataTask && enabled) {
        self.dataTask.priority = NSURLSessionTaskPriorityHigh;
    } else if (self.dataTask) {
        self.dataTask.priority = NSURLSessionTaskPriorityDefault;
    }
}

- (void)setProcessingMode:(MJPEGReaderProcessingMode)mode {
    _processingMode = mode;
    
    writeLog(@"[MJPEG] Modo de processamento alterado para: %@",
             mode == MJPEGReaderProcessingModeHighPerformance ? @"Alta Performance" :
             mode == MJPEGReaderProcessingModeHighQuality ? @"Alta Qualidade" : @"Padrão");
    
    // Ajustar as configurações baseado no modo
    switch (mode) {
        case MJPEGReaderProcessingModeHighPerformance:
            // Otimizado para vídeo: maior taxa de frames, menor latência
            dispatch_set_target_queue(_processingQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
            dispatch_set_target_queue(_highPriorityQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
            
            // Pré-alocar buffer maior para performance
            if (self.buffer.length < 1024 * 1024) {
                self.buffer = [NSMutableData dataWithCapacity:2 * 1024 * 1024]; // 2MB
            }
            break;
            
        case MJPEGReaderProcessingModeHighQuality:
            // Otimizado para fotos: qualidade mais alta, maior fidelidade
            dispatch_set_target_queue(_processingQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
            dispatch_set_target_queue(_highPriorityQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
            break;
            
        default: // MJPEGReaderProcessingModeDefault
            // Configuração balanceada
            dispatch_set_target_queue(_processingQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
            dispatch_set_target_queue(_highPriorityQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
            break;
    }
}

- (void)startStreamingFromURL:(NSURL *)url {
    static NSLock *connectionLock = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        connectionLock = [[NSLock alloc] init];
    });
    
    [connectionLock lock];
    
    @try {
        // Adicionar log para debug
        writeLog(@"[MJPEG] Verificando conexão para URL: %@, gGlobalReaderConnected: %d",
                 url.absoluteString, gGlobalReaderConnected);
        
        // Se já existe uma conexão global ativa, não iniciar nova
        if (gGlobalReaderConnected) {
            if ([url.absoluteString isEqualToString:gCurrentServerURL]) {
                writeLog(@"[MJPEG] Já existe uma conexão global ativa para %@, reutilizando", url.absoluteString);
                self.isConnected = YES;
                self.currentURL = url;
                [connectionLock unlock];
                return;
            } else {
                // Se a URL for diferente, fechar a conexão atual primeiro
                writeLog(@"[MJPEG] Fechando conexão existente para abrir nova URL");
                [self stopStreaming];
            }
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
        
        // Reiniciar buffer com tamanho adequado
        self.buffer = [NSMutableData dataWithCapacity:kInitialBufferSize];
        
        // Garantir que o callback esteja configurado para GetFrame
        if (!self.sampleBufferCallback) {
            writeLog(@"[MJPEG] sampleBufferCallback não estava configurado. Configurando para GetFrame.");
            
            self.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
                // Enviar o buffer para GetFrame
                [[GetFrame sharedInstance] processNewMJPEGFrame:sampleBuffer];
            };
        }
        
        // Preparar request com cabeçalhos otimizados
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setValue:@"multipart/x-mixed-replace" forHTTPHeaderField:@"Accept"];
        [request setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
        [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
        
        // Adicionar cabeçalhos para melhorar a performance do stream
        [request setValue:@"video/x-motion-jpeg, multipart/x-mixed-replace" forHTTPHeaderField:@"Accept"];
        [request setValue:@"*/*" forHTTPHeaderField:@"Accept-Encoding"];
        [request setValue:@"gzip, deflate" forHTTPHeaderField:@"Accept-Encoding"];
        [request setValue:@"close" forHTTPHeaderField:@"Connection"];
        
        // Configurar timeout mais longo para estabilidade
        [request setTimeoutInterval:60.0];
        
        // Iniciar a tarefa com a requisição
        self.dataTask = [self.session dataTaskWithRequest:request];
        
        // Configurar a prioridade da tarefa para alta
        self.dataTask.priority = NSURLSessionTaskPriorityHigh;
        
        // Iniciar a tarefa
        [self.dataTask resume];
        
        // Marcar como conectado globalmente
        gGlobalReaderConnected = YES;
        writeLog(@"[MJPEG] Tarefa de streaming iniciada com prioridade alta");
    } @catch (NSException *exception) {
        writeLog(@"[MJPEG] Erro ao iniciar streaming: %@", exception.reason);
        self.isConnected = NO;
        self.isReconnecting = NO;
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
        
        // Limpar buffer
        [self.bufferLock lock];
        [self.buffer setLength:0];
        [self.bufferLock unlock];
        
        // Limpar cache de formatos
        [self.formatsCache removeAllObjects];
        
        // Liberar pool de buffers de pixels
        if (self.pixelBufferPool) {
            CVPixelBufferPoolRelease(self.pixelBufferPool);
            self.pixelBufferPool = NULL;
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
        [self.bufferLock lock];
        [self.buffer setLength:0];
        [self.bufferLock unlock];
        
        // Redefinir estado
        self.isConnected = NO;
        self.isReconnecting = NO;
        gGlobalReaderConnected = NO;
        
        if (self.lastReceivedSampleBuffer) {
            CFRelease(self.lastReceivedSampleBuffer);
            self.lastReceivedSampleBuffer = NULL;
        }
    }
    
    // Tentar reconectar automaticamente após um tempo
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.currentURL) {
            writeLog(@"[MJPEG] Tentando reconectar automaticamente a %@", self.currentURL);
            [self startStreamingFromURL:self.currentURL];
        }
    });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    static BOOL isProcessingResponse = NO;
    
    if (!isProcessingResponse) {
        isProcessingResponse = YES;
        writeLog(@"[MJPEG] Conexão estabelecida com o servidor");
        
        // Verificar código de resposta HTTP
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if ([httpResponse isKindOfClass:[NSHTTPURLResponse class]]) {
            writeLog(@"[MJPEG] Código de resposta HTTP: %ld", (long)httpResponse.statusCode);
            
            // Verificar tipo de conteúdo para confirmar stream MJPEG
            NSString *contentType = [httpResponse.allHeaderFields objectForKey:@"Content-Type"];
            if (contentType) {
                writeLog(@"[MJPEG] Content-Type: %@", contentType);
                
                // Verificar se é um tipo MJPEG válido
                if ([contentType containsString:@"multipart/x-mixed-replace"] ||
                    [contentType containsString:@"multipart/mixed"] ||
                    [contentType containsString:@"image/jpeg"]) {
                    writeLog(@"[MJPEG] Tipo de conteúdo MJPEG válido detectado");
                } else {
                    writeLog(@"[MJPEG] Aviso: tipo de conteúdo inesperado, mas tentando processar mesmo assim");
                }
            }
        }
        
        self.isConnected = YES;
        self.isReconnecting = NO;
        gGlobalReaderConnected = YES;
        
        // Limpar buffer
        [self.bufferLock lock];
        [self.buffer setLength:0];
        [self.bufferLock unlock];
        
        // Reset após 5 segundos
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isProcessingResponse = NO;
        });
    }
    
    completionHandler(NSURLSessionResponseAllow);
}

// Detecta os marcadores JPEG para extrair as imagens do stream
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    // Verificar se temos dados válidos
    if (!data || data.length == 0) return;
    
    // Determinar qual fila usar baseado no modo de prioridade
    dispatch_queue_t queue = self.highPriorityMode ? _highPriorityQueue : _processingQueue;
    
    // Processar em fila separada para evitar bloqueio da rede
    dispatch_async(queue, ^{
        // Obter acesso exclusivo ao buffer
        [self.bufferLock lock];
        
        @try {
            // Verificar se a conexão ainda está ativa
            if (!self.isConnected) {
                [self.bufferLock unlock];
                return;
            }
            
            // Verificar tamanho do buffer para proteção contra vazamento de memória
            if (self.buffer.length > kMaxBufferSize) {
                writeLog(@"[MJPEG] Aviso: buffer excedeu tamanho máximo (%lu bytes), reduzindo", (unsigned long)kMaxBufferSize);
                NSRange keepRange = NSMakeRange(self.buffer.length - kResetBufferSize, kResetBufferSize);
                self.buffer = [[self.buffer subdataWithRange:keepRange] mutableCopy];
            }
            
            // Adicionar novos dados ao buffer
            [self.buffer appendData:data];
            
            // Processar dados recebidos - procurar por frames JPEG
            [self processReceivedData];
        } @catch (NSException *e) {
            writeLog(@"[MJPEG] Erro ao processar dados recebidos: %@", e);
        } @finally {
            [self.bufferLock unlock];
        }
    });
}

- (void)processReceivedData {
    NSUInteger length = self.buffer.length;
    const uint8_t *bytes = (const uint8_t *)self.buffer.bytes;
    
    if (length < 4) return; // Precisamos de pelo menos 4 bytes para SOI e EOI
    
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
            
            // Verificar se temos dados suficientes para um frame válido
            if (frameEnd - frameStart < 100) {
                // Frame muito pequeno, provavelmente inválido
                continue;
            }
            
            // Extrair os dados do JPEG completo
            NSData *jpegData = [self.buffer subdataWithRange:NSMakeRange(frameStart, frameEnd - frameStart)];
            
            // Processar o frame em outra thread para não bloquear
            dispatch_queue_t processingQueue = (self.processingMode == MJPEGReaderProcessingModeHighPerformance)
                ? _highPriorityQueue
                : _imageProcessingQueue;
            
            dispatch_async(processingQueue, ^{
                [self processJPEGData:jpegData];
            });
            
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
    if (self.buffer.length > kMaxBufferSize / 2) { // 5MB
        static BOOL loggedBufferReset = NO;
        if (!loggedBufferReset) {
            writeLog(@"[MJPEG] Buffer muito grande sem frame completo, resetando parcialmente (%lu bytes)",
                     (unsigned long)self.buffer.length);
            loggedBufferReset = YES;
            
            // Resetar após 5 segundos para permitir mais logs se ocorrer novamente
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                loggedBufferReset = NO;
            });
        }
        
        // Manter apenas a parte final do buffer onde pode haver um frame em andamento
        if (self.buffer.length > kResetBufferSize) {
            NSRange keepRange = NSMakeRange(self.buffer.length - kResetBufferSize, kResetBufferSize);
            self.buffer = [[self.buffer subdataWithRange:keepRange] mutableCopy];
        }
    }
}

- (void)processJPEGData:(NSData *)jpegData {
    @autoreleasepool {
        // Medir FPS
        NSTimeInterval now = CACurrentMediaTime();
        self.frameProcessedCount++;
        
        // Atualizar FPS a cada segundo
        if (now - self.lastFrameTime >= 1.0) {
            self.currentFPS = self.frameProcessedCount / (now - self.lastFrameTime);
            self.frameProcessedCount = 0;
            self.lastFrameTime = now;
            
            // Log limitado de FPS
            static int fpsLogCount = 0;
            if (++fpsLogCount % 10 == 0) {
                writeLog(@"[MJPEG] FPS atual: %.1f", self.currentFPS);
            }
        }
        
        // Log limitado de frames processados
        static int frameCount = 0;
        frameCount++;
        if (frameCount % 300 == 0) {  // Log a cada 300 frames para não encher o log
            writeLog(@"[MJPEG] Processado frame #%d (%d bytes)", frameCount, (int)jpegData.length);
        }
        
        // Criar imagem a partir dos dados JPEG para visualização/preview
        UIImage *image = nil;
        
        // Se estamos no modo de alta qualidade ou temos um callback de frame, decodificar a imagem
        if (self.processingMode == MJPEGReaderProcessingModeHighQuality || self.frameCallback) {
            image = [UIImage imageWithData:jpegData];
            
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
            }
        }
        
        // Converter para CMSampleBuffer utilizando o método otimizado
        CMSampleBufferRef sampleBuffer = [self createOptimizedSampleBufferFromJPEGData:jpegData
                                                               withSize:self.lastKnownResolution];
        
        if (sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) {
            // Enviar diretamente para GetFrame para processamento - MÉTODO CRÍTICO
            [[GetFrame sharedInstance] processNewMJPEGFrame:sampleBuffer];
            
            // Garantir que a orientação está corretamente definida
            if (g_isVideoOrientationSet) {
                // Definir orientação como metadado do buffer
                uint32_t orientation = g_videoOrientation;
                CFNumberRef orientationValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &orientation);
                if (orientationValue) {
                    CMSetAttachment(sampleBuffer, CFSTR("VideoOrientation"), orientationValue, kCMAttachmentMode_ShouldPropagate);
                    CFRelease(orientationValue);
                }
            }
            
            // Liberar o sampleBuffer após uso
            CFRelease(sampleBuffer);
        } else if (image) {
            // Fallback para o método anterior se o otimizado falhar
            CMSampleBufferRef fallbackBuffer = [[GetFrame sharedInstance] createSampleBufferFromJPEGData:jpegData
                                                                                              withSize:image.size];
            
            if (fallbackBuffer) {
                [[GetFrame sharedInstance] processNewMJPEGFrame:fallbackBuffer];
                CFRelease(fallbackBuffer);
            }
        } else {
            writeLog(@"[MJPEG] Falha ao criar sample buffer a partir dos dados JPEG");
        }
    }
}

// Método otimizado para criar CMSampleBuffer a partir de dados JPEG
- (CMSampleBufferRef)createOptimizedSampleBufferFromJPEGData:(NSData *)jpegData withSize:(CGSize)size {
   if (!jpegData || jpegData.length == 0) {
       return NULL;
   }
   
   // Usar um cache para formatDescription - isso melhora performance significativamente
   NSString *cacheKey = [NSString stringWithFormat:@"%.0fx%.0f", size.width, size.height];
   CMFormatDescriptionRef formatDesc = (__bridge CMFormatDescriptionRef)[self.formatsCache objectForKey:cacheKey];
   
   // Step 1: Criar um CVPixelBuffer otimizado
   CVPixelBufferRef pixelBuffer = NULL;
   CVReturn cvReturn = kCVReturnSuccess;
   
   // Tentar usar um pool de pixel buffers para melhorar performance
   if (self.pixelBufferPool == NULL ||
       CVPixelBufferPoolGetWidth(self.pixelBufferPool) != size.width ||
       CVPixelBufferPoolGetHeight(self.pixelBufferPool) != size.height) {
       
       // Criar um novo pool com as dimensões corretas
       if (self.pixelBufferPool) {
           CVPixelBufferPoolRelease(self.pixelBufferPool);
           self.pixelBufferPool = NULL;
       }
       
       NSDictionary *poolAttributes = @{
           (id)kCVPixelBufferPoolMinimumBufferCountKey: @(3)  // Manter pelo menos 3 buffers no pool
       };
       
       NSDictionary *pixelBufferAttributes = @{
           (id)kCVPixelBufferWidthKey: @(size.width),
           (id)kCVPixelBufferHeightKey: @(size.height),
           (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
           (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
           (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
           (id)kCVPixelBufferMetalCompatibilityKey: @YES
       };
       
       cvReturn = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                       (__bridge CFDictionaryRef)poolAttributes,
                                       (__bridge CFDictionaryRef)pixelBufferAttributes,
                                       &_pixelBufferPool);
       
       if (cvReturn != kCVReturnSuccess) {
           writeLog(@"[MJPEG] Falha ao criar pool de pixel buffers: %d", cvReturn);
           return NULL;
       }
   }
   
   // Obter um buffer do pool
   cvReturn = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pixelBufferPool, &pixelBuffer);
   
   if (cvReturn != kCVReturnSuccess) {
       writeLog(@"[MJPEG] Falha ao obter buffer do pool: %d", cvReturn);
       return NULL;
   }
   
   // Step 2: Decodificar o JPEG para o pixel buffer
   // Criar um CGImage a partir dos dados JPEG
   CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, jpegData.bytes, jpegData.length, NULL);
   CGImageRef cgImage = CGImageCreateWithJPEGDataProvider(dataProvider, NULL, true, kCGRenderingIntentDefault);
   CGDataProviderRelease(dataProvider);
   
   if (cgImage == NULL) {
       CVPixelBufferRelease(pixelBuffer);
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
       return NULL;
   }
   
   // Limpar o contexto para evitar artefatos
   CGContextClearRect(context, CGRectMake(0, 0, size.width, size.height));
   
   // Configurar qualidade de interpolação baseada no modo
   if (self.processingMode == MJPEGReaderProcessingModeHighQuality) {
       CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
   } else {
       CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
   }
   
   // Desenhar a imagem no contexto com a orientação correta
   CGContextDrawImage(context, CGRectMake(0, 0, size.width, size.height), cgImage);
   
   // Liberar recursos
   CGContextRelease(context);
   CGImageRelease(cgImage);
   
   // Desbloquear o buffer
   CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
   
   // Step 3: Criar ou reutilizar a descrição de formato
   if (formatDesc == NULL) {
       // Criar nova descrição de formato se não estiver em cache
       CVReturn status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
       
       if (status != noErr) {
           CVPixelBufferRelease(pixelBuffer);
           return NULL;
       }
       
       // Armazenar no cache
       [self.formatsCache setObject:(__bridge id)formatDesc forKey:cacheKey];
   }
   
   // Step 4: Criar o SampleBuffer com timestamp preciso
   CMSampleBufferRef sampleBuffer = NULL;
   
   // Configurar timing info
   CMSampleTimingInfo timing;
   timing.duration = CMTimeMake(1, 30); // 30 fps
   timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 90000);
   timing.decodeTimeStamp = kCMTimeInvalid;
   
   // Criar sample buffer
   OSStatus status = CMSampleBufferCreateForImageBuffer(
       kCFAllocatorDefault,
       pixelBuffer,
       true,
       NULL,
       NULL,
       formatDesc,
       &timing,
       &sampleBuffer
   );
   
   // Liberar recursos
   CFRelease(formatDesc); // O cache retém uma cópia
   CVPixelBufferRelease(pixelBuffer);
   
   if (status != noErr || !sampleBuffer) {
       return NULL;
   }
   
   // Adicionar metadados
   if (g_isVideoOrientationSet) {
       // Adicionar orientação como attachment
       uint32_t orientation = g_videoOrientation;
       CFNumberRef orientationValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &orientation);
       if (orientationValue) {
           CMSetAttachment(sampleBuffer, CFSTR("VideoOrientation"), orientationValue, kCMAttachmentMode_ShouldPropagate);
           CFRelease(orientationValue);
       }
   }
   
   // Adicionar timestamp como metadado
   CMSetAttachment(sampleBuffer, CFSTR("FrameTimeStamp"),
                 (__bridge CFTypeRef)@(CACurrentMediaTime()),
                 kCMAttachmentMode_ShouldPropagate);
   
   // Log limitado
   static int sampleBufferCount = 0;
   if (sampleBufferCount++ % 300 == 0) {
       writeLog(@"[MJPEG] SampleBuffer #%d criado com sucesso (dimensões: %.0f x %.0f)",
               sampleBufferCount, size.width, size.height);
   }
   
   return sampleBuffer;
}

// Método para compatibilidade com versões anteriores
- (CMSampleBufferRef)createSampleBufferFromJPEGData:(NSData *)jpegData withSize:(CGSize)size {
   // Usar o método otimizado
   return [self createOptimizedSampleBufferFromJPEGData:jpegData withSize:size];
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
