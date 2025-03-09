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
    dispatch_queue_t _highPriorityQueue; // Nova fila de alta prioridade
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
        
        // Salvar URL nas configurações para todos os processos
        [[NSUserDefaults standardUserDefaults] setObject:url.absoluteString forKey:@"VCamMJPEG_ServerURL"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"VCamMJPEG_Enabled"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
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
            
            if (httpResponse.statusCode == 200) {
                // Temos uma conexão bem-sucedida - notificar
                self.isConnected = YES;
                self.isReconnecting = NO;
                gGlobalReaderConnected = YES;
                
                // CORREÇÃO CRÍTICA: Verificar o tipo de conteúdo
                NSString *contentType = [httpResponse.allHeaderFields objectForKey:@"Content-Type"];
                if (contentType) {
                    writeLog(@"[MJPEG] Content-Type: %@", contentType);
                    
                    // Apenas considerar como conectado se for um tipo MJPEG válido
                    if ([contentType containsString:@"multipart/x-mixed-replace"]) {
                        writeLog(@"[MJPEG] Tipo de conteúdo MJPEG válido detectado");
                        // Temos certeza que é um stream MJPEG
                        self.isConnected = YES;
                        gGlobalReaderConnected = YES;
                        
                        // Enviar a notificação para todos os processos
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[NSNotificationCenter defaultCenter] postNotificationName:@"MJPEGReaderConnectionEstablished"
                                                                             object:self
                                                                           userInfo:nil];
                        });
                    } else {
                        // Se não for multipart/x-mixed-replace, ainda pode ser uma resposta válida mas não um stream
                        writeLog(@"[MJPEG] Aviso: Resposta válida mas não é um stream MJPEG");
                    }
                }
            } else {
                // Resposta com erro
                self.isConnected = NO;
                gGlobalReaderConnected = NO;
                writeLog(@"[MJPEG] Código de resposta de erro: %ld", (long)httpResponse.statusCode);
            }
        }
        
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
        // Adicionar log para saber se está recebendo frames - limitado a cada 300 frames
        static int frameCount = 0;
        frameCount++;
        
        // Para o primeiro frame processado, garantir que isConnected está TRUE
        if (frameCount == 1) {
            if (!self.isConnected) {
                writeLog(@"[MJPEG] Primeiro frame processado - atualizando status de conexão");
                self.isConnected = YES;
                gGlobalReaderConnected = YES;
                
                // Enviar a notificação para todos os processos
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"MJPEGReaderConnectionEstablished"
                                                                       object:self
                                                                     userInfo:nil];
                });
            }
        }
        
        if (frameCount % 300 == 0) {  // Log a cada 300 frames para não encher o log
            writeLog(@"[MJPEG] Processado frame #%d (%d bytes)", frameCount, (int)jpegData.length);
        }
        
        // Criar imagem a partir dos dados JPEG - mover para GetFrame para processamento mais eficiente
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
        if (error.code != NSURLErrorCancelled) { // Ignore cancelamento intencional
            writeLog(@"[MJPEG] Erro no streaming: %@", error);
            self.isConnected = NO;
            
            // Notificar observadores da desconexão
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MJPEGReaderConnectionLost"
                                                                object:self
                                                              userInfo:@{@"error": error}];
                                                              
            [self resetWithError:error];
        }
    } else {
        writeLog(@"[MJPEG] Streaming concluído");
        self.isConnected = NO;
        self.isReconnecting = NO;
        gGlobalReaderConnected = NO;
        
        // Também notificar neste caso
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MJPEGReaderConnectionLost"
                                                            object:self
                                                          userInfo:nil];
    }
}

@end
