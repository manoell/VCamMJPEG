#import "GetFrame.h"
#import "MJPEGReader.h"
#import "logger.h"
#import "VirtualCameraController.h"

// Indica se alguma instância já está conectada - GLOBAL
BOOL gGlobalReaderConnected = NO;

// URL do servidor atual
static NSString *gCurrentServerURL = nil;

@interface MJPEGReader ()
// Usar um tipo normal em vez de property para dispatch_queue_t
{
    dispatch_queue_t _processingQueue;
    dispatch_queue_t _highPriorityQueue; // Fila de alta prioridade
    NSDate *_lastConnectionAttempt;      // Timestamp da última tentativa
    NSTimeInterval _connectionBackoff;    // Tempo de espera para reconexão
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
        
        // Otimizar configuração de rede
        config.HTTPMaximumConnectionsPerHost = 5; // Aumentar conexões por host
        config.HTTPShouldUsePipelining = YES; // Usar HTTP pipelining quando possível
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData; // Evitar cache para streaming
        
        self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        self.buffer = [NSMutableData data];
        self.isConnected = NO;
        self.isReconnecting = NO;
        self.lastKnownResolution = CGSizeMake(1280, 720); // Resolução padrão
        self.currentURL = nil;
        self.lastReceivedSampleBuffer = NULL;
        self.highPriorityMode = NO;
        
        // Valores iniciais para o controle de reconexão
        _lastConnectionAttempt = [NSDate distantPast];
        _connectionBackoff = 1.0; // Começa com 1 segundo
        
        // Criar a fila de processamento como variável de instância
        _processingQueue = dispatch_queue_create("com.vcam.mjpeg.processing", DISPATCH_QUEUE_SERIAL);
        
        // Fila para processamento de alta prioridade
        _highPriorityQueue = dispatch_queue_create("com.vcam.mjpeg.highpriority", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_highPriorityQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        
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

- (void)setHighPriority:(BOOL)enabled {
    self.highPriorityMode = enabled;
    writeLog(@"[MJPEG] Modo de alta prioridade %@", enabled ? @"ATIVADO" : @"DESATIVADO");
}

- (void)startStreamingFromURL:(NSURL *)url {
    @synchronized(self) {
        @try {
            // Log inicial do estado
            writeLog(@"[MJPEG] startStreamingFromURL: url=%@, gGlobalReaderConnected=%d, self.isConnected=%d, self.dataTask=%@",
                     url.absoluteString, gGlobalReaderConnected, self.isConnected, self.dataTask ? @"válido" : @"nulo");
            
            // CORREÇÃO: Modificar verificação para permitir reconexão
            if (gGlobalReaderConnected && [url.absoluteString isEqualToString:gCurrentServerURL] &&
                self.isConnected && self.dataTask != nil) {
                writeLog(@"[MJPEG] Já existe uma conexão ativa e válida para %@", url.absoluteString);
                return;
            }
            
            // Verificar o tempo desde a última tentativa (prevenção de reconexões frequentes)
            NSTimeInterval timeSinceLastAttempt = -[_lastConnectionAttempt timeIntervalSinceNow];
            if (timeSinceLastAttempt < _connectionBackoff && self.isReconnecting) {
                writeLog(@"[MJPEG] Tentativa de reconexão muito frequente (%.1fs < %.1fs). Aguardando...",
                        timeSinceLastAttempt, _connectionBackoff);
                return;
            }
            
            // Atualizar timestamp da tentativa de conexão
            _lastConnectionAttempt = [NSDate date];
            
            // Evitar múltiplas reconexões simultâneas
            if (self.isReconnecting) {
                writeLog(@"[MJPEG] Já está reconectando, ignorando solicitação para: %@", url.absoluteString);
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
            
            // Garantir que o callback esteja configurado para GetFrame
            if (!self.sampleBufferCallback) {
                writeLog(@"[MJPEG] sampleBufferCallback não estava configurado. Configurando para GetFrame.");
                
                self.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
                    // Enviar o buffer para GetFrame
                    [[GetFrame sharedInstance] processNewMJPEGFrame:sampleBuffer];
                };
            }
            
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
            [request setValue:@"multipart/x-mixed-replace" forHTTPHeaderField:@"Accept"];
            [request setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
            [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
            
            // Adicionar cabeçalhos para melhorar a performance do stream
            [request setValue:@"video/x-motion-jpeg, multipart/x-mixed-replace" forHTTPHeaderField:@"Accept"];
            [request setValue:@"*/*" forHTTPHeaderField:@"Accept-Encoding"];
            
            self.dataTask = [self.session dataTaskWithRequest:request];
            [self.dataTask resume];
            
            // Configurar a prioridade da tarefa para alta
            self.dataTask.priority = NSURLSessionTaskPriorityHigh;
            
            gGlobalReaderConnected = YES;
            writeLog(@"[MJPEG] Tarefa de streaming iniciada com prioridade alta");
            
            // Resetar backoff se a conexão for bem sucedida (será definido como bem sucedida no callback didReceiveResponse)
            _connectionBackoff = 1.0;
            
            // Log final do estado
            writeLog(@"[MJPEG] Estado após iniciar streaming: gGlobalReaderConnected=%d, self.isConnected=%d",
                     gGlobalReaderConnected, self.isConnected);
        } @catch (NSException *exception) {
            writeLog(@"[MJPEG] Erro ao iniciar streaming: %@", exception.reason);
            
            // Aumentar backoff exponencialmente até um limite de 30 segundos
            _connectionBackoff = MIN(_connectionBackoff * 1.5, 30.0);
            writeLog(@"[MJPEG] Backoff de reconexão ajustado para %.1f segundos", _connectionBackoff);
        } @finally {
            // Garantir que o estado de reconexão seja limpo após um tempo
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.isReconnecting = NO;
            });
        }
    }
}

- (void)stopStreaming {
    @synchronized(self) {
        @try {
            writeLog(@"[MJPEG] Parando streaming (isConnected=%d, gGlobalReaderConnected=%d)",
                     self.isConnected, gGlobalReaderConnected);
            
            if (self.dataTask) {
                writeLog(@"[MJPEG] Cancelando dataTask");
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
            
            // Limpar o buffer
            [self.buffer setLength:0];
            
            writeLog(@"[MJPEG] Streaming parado (isConnected=%d, gGlobalReaderConnected=%d)",
                     self.isConnected, gGlobalReaderConnected);
        } @catch (NSException *exception) {
            writeLog(@"[MJPEG] Erro ao parar streaming: %@", exception);
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
    
    @synchronized(self) {
        @try {
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
            
            if (self.lastReceivedSampleBuffer) {
                CFRelease(self.lastReceivedSampleBuffer);
                self.lastReceivedSampleBuffer = NULL;
            }
            
            // Aumentar o tempo de backoff exponencialmente até 30 segundos
            _connectionBackoff = MIN(_connectionBackoff * 1.5, 30.0);
            writeLog(@"[MJPEG] Backoff de reconexão ajustado para %.1f segundos", _connectionBackoff);
        } @catch (NSException *exception) {
            writeLog(@"[MJPEG] Erro durante reset: %@", exception);
        }
    }
    
    // Verificar se ainda devemos tentar reconectar
    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"VCamMJPEG_Enabled"];
    
    // Tentar reconectar automaticamente após o tempo de backoff
    if (isEnabled && self.currentURL) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_connectionBackoff * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            writeLog(@"[MJPEG] Tentando reconectar automaticamente a %@ após backoff de %.1f segundos",
                    self.currentURL, _connectionBackoff);
            [self startStreamingFromURL:self.currentURL];
        });
    } else {
        writeLog(@"[MJPEG] Tweak desativado ou sem URL, não tentando reconexão");
        gGlobalReaderConnected = NO;
    }
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
                
                // Verificar se o tipo de conteúdo é compatível com MJPEG
                BOOL isValidContentType = [contentType containsString:@"multipart/x-mixed-replace"] ||
                                         [contentType containsString:@"image/jpeg"] ||
                                         [contentType containsString:@"mjpeg"];
                
                if (!isValidContentType) {
                    writeLog(@"[MJPEG] AVISO: Content-Type inesperado para MJPEG stream: %@", contentType);
                }
            }
            
            // Se o código não for 200, rejeitar
            if (httpResponse.statusCode != 200) {
                writeLog(@"[MJPEG] Erro: código de resposta HTTP inválido: %ld", (long)httpResponse.statusCode);
                completionHandler(NSURLSessionResponseCancel);
                // Reset após 2 segundos para permitir futuras tentativas
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    isProcessingResponse = NO;
                });
                return;
            }
        }
        
        @synchronized(self) {
            self.isConnected = YES;
            self.isReconnecting = NO;
            gGlobalReaderConnected = YES;
            [self.buffer setLength:0];
            
            // Resetar o backoff para 1 segundo já que a conexão foi bem-sucedida
            _connectionBackoff = 1.0;
            writeLog(@"[MJPEG] Conexão bem-sucedida, backoff resetado para %.1f segundos", _connectionBackoff);
        }
        
        // Reset após 5 segundos
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isProcessingResponse = NO;
        });
    }
    
    completionHandler(NSURLSessionResponseAllow);
}

// Detecta os marcadores JPEG para extrair as imagens do stream
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    // Determinar qual fila usar baseado no modo de prioridade
    dispatch_queue_t queue = self.highPriorityMode ? _highPriorityQueue : _processingQueue;
    
    // Processar em fila separada para evitar bloqueio da rede
    dispatch_async(queue, ^{
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
            
            // Processar o frame imediatamente
            dispatch_async(self.highPriorityMode ? _highPriorityQueue : _processingQueue, ^{
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
        // Reduzir logs para evitar sobrecarga
        static int frameCount = 0;
        frameCount++;
        if (frameCount % 1000 == 0) {  // Reduzido para log a cada 1000 frames
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
            
            // Converter para CMSampleBuffer utilizando o método de GetFrame que é mais eficiente
            CMSampleBufferRef sampleBuffer = [[GetFrame sharedInstance] createSampleBufferFromJPEGData:jpegData withSize:image.size];
            
            if (sampleBuffer && CMSampleBufferIsValid(sampleBuffer)) {
                // Enviar diretamente para GetFrame para processamento - MÉTODO CRÍTICO
                [[GetFrame sharedInstance] processNewMJPEGFrame:sampleBuffer];
                
                // Liberar o sampleBuffer após uso
                CFRelease(sampleBuffer);
            }
        } else {
            writeLog(@"[MJPEG] Falha ao criar imagem a partir dos dados JPEG");
        }
    }
}

// Método para criar um CMSampleBuffer a partir de dados JPEG - mantido por compatibilidade
- (CMSampleBufferRef)createSampleBufferFromJPEGData:(NSData *)jpegData withSize:(CGSize)size {
    // Usar o método da classe GetFrame, que é mais eficiente e mantém compatibilidade
    return [[GetFrame sharedInstance] createSampleBufferFromJPEGData:jpegData withSize:size];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        if (error.code != NSURLErrorCancelled) { // Ignorar cancelamento intencional
            writeLog(@"[MJPEG] Erro no streaming: %@", error);
            [self resetWithError:error];
        } else {
            writeLog(@"[MJPEG] Streaming cancelado intencionalmente");
            @synchronized(self) {
                self.isConnected = NO;
                self.isReconnecting = NO;
                self.dataTask = nil;
                // Não alteramos gGlobalReaderConnected aqui para permitir que a janela de UI mostre o estado correto
            }
        }
    } else {
        writeLog(@"[MJPEG] Streaming concluído normalmente");
        @synchronized(self) {
            self.isConnected = NO;
            self.isReconnecting = NO;
            self.dataTask = nil;
        }
        
        // Verificar se o tweak ainda está ativo para tentar reconectar
        BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"VCamMJPEG_Enabled"];
        
        // Se a tarefa terminou normalmente e o tweak ainda está ativo, tente reconectar
        if (isEnabled && self.currentURL) {
            writeLog(@"[MJPEG] Reconectando após finalização normal...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self startStreamingFromURL:self.currentURL];
            });
        }
    }
}

@end
