#import "VirtualCameraController.h"
#import "MJPEGReader.h"
#import "logger.h"

@interface VirtualCameraController ()
{
    // Usar variáveis de instância em vez de propriedades para tipos C
    CMSampleBufferRef _latestSampleBuffer;
    dispatch_queue_t _processingQueue;
    
    // Contador para limitar logs
    int _frameCounter;
}
@end

@implementation VirtualCameraController

+ (instancetype)sharedInstance {
    static VirtualCameraController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _processingQueue = dispatch_queue_create("com.vcam.mjpeg.virtual-camera", DISPATCH_QUEUE_SERIAL);
        _isActive = NO;
        _latestSampleBuffer = NULL;
        _debugMode = YES;
        _frameCounter = 0;
        
        // Configurar callback para frames MJPEG
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        
        // Armazenar self fraco para evitar retenção circular
        __weak typeof(self) weakSelf = self;
        reader.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
            [weakSelf processSampleBuffer:sampleBuffer];
        };
        
        writeLog(@"[CAMERA] VirtualCameraController inicializado e callback configurado");
    }
    return self;
}

- (void)dealloc {
    [self cleanupBuffer];
}

- (void)cleanupBuffer {
    @synchronized (self) {
        if (_latestSampleBuffer) {
            CFRelease(_latestSampleBuffer);
            _latestSampleBuffer = NULL;
        }
    }
}

- (BOOL)checkAndActivate {
    // Se já estiver ativo, apenas retornar TRUE
    if (self.isActive) {
        return YES;
    }
    
    // Ativar controlador
    [self startCapturing];
    
    // Verificar se agora está ativo
    return self.isActive;
}

- (void)startCapturing {
    if (self.isActive) {
        writeLog(@"[CAMERA] Captura virtual já está ativa");
        return;
    }
    
    writeLog(@"[CAMERA] Iniciando captura virtual");
    
    // Inicializar a fila de processamento se não existir
    if (!_processingQueue) {
        _processingQueue = dispatch_queue_create("com.vcam.mjpeg.virtual-camera", DISPATCH_QUEUE_SERIAL);
    }
    
    // Definir como ativo
    self.isActive = YES;
    writeLog(@"[CAMERA] Captura virtual iniciada com sucesso");
    
    // Verificar se o MJPEGReader está conectado
    MJPEGReader *reader = [MJPEGReader sharedInstance];
    if (!reader.isConnected) {
        writeLog(@"[CAMERA] MJPEGReader não está conectado, tentando conectar...");
        NSURL *url = [NSURL URLWithString:@"http://192.168.0.178:8080/mjpeg"];
        [reader startStreamingFromURL:url];
    }
    
    // Configurar o callback do reader se ainda não foi configurado
    if (!reader.sampleBufferCallback) {
        __weak typeof(self) weakSelf = self;
        reader.sampleBufferCallback = ^(CMSampleBufferRef sampleBuffer) {
            [weakSelf processSampleBuffer:sampleBuffer];
        };
    }
}

- (void)stopCapturing {
    if (!self.isActive) return;
    
    writeLog(@"[CAMERA] Parando captura virtual");
    self.isActive = NO;
    [self cleanupBuffer];
}

- (CMSampleBufferRef)getLatestSampleBuffer {
    CMSampleBufferRef result = NULL;
    
    @synchronized (self) {
        if (_latestSampleBuffer && CMSampleBufferIsValid(_latestSampleBuffer)) {
            // Aumentar a contagem de referência para o chamador
            result = (CMSampleBufferRef)CFRetain(_latestSampleBuffer);
            
            if (_debugMode && (++_frameCounter % 100 == 0)) {
                writeLog(@"[CAMERA] Buffer #%d disponível e válido para substituição", _frameCounter);
            }
        } else {
            // Se não houver buffer válido, vamos tentar criar um novo
            MJPEGReader *reader = [MJPEGReader sharedInstance];
            if (reader.isConnected) {
                if (_debugMode) {
                    writeLog(@"[CAMERA] Solicitando novo frame para substituição");
                }
                // Aqui você pode implementar uma forma de forçar a requisição de um novo frame
            }
        }
    }
    
    // Limitar logs de erros
    if (!result && _debugMode && (++_frameCounter % 100 == 0)) {
        writeLog(@"[CAMERA] Sem buffer disponível para substituição (ocorrência #%d)", _frameCounter);
    }
    
    return result;
}

// Implementação específica para substituição de câmera - baseada no GetFrame::getCurrentFrame__
- (CMSampleBufferRef)getLatestSampleBufferForSubstitution {
    static int callCount = 0;
    
    // Log menos frequente
    if (++callCount % 100 == 0) {
        writeLog(@"[CAMERA] getLatestSampleBufferForSubstitution chamado #%d", callCount);
    }
    
    // Primeira opção: usar o buffer armazenado
    CMSampleBufferRef result = NULL;
    
    @synchronized (self) {
        if (_latestSampleBuffer && CMSampleBufferIsValid(_latestSampleBuffer)) {
            result = (CMSampleBufferRef)CFRetain(_latestSampleBuffer);
            if (callCount % 100 == 0) {
                writeLog(@"[CAMERA] Usando _latestSampleBuffer armazenado");
            }
            return result;
        }
    }
    
    // Segunda opção: usar o último buffer do MJPEGReader
    MJPEGReader *reader = [MJPEGReader sharedInstance];
    if (reader.lastReceivedSampleBuffer && CMSampleBufferIsValid(reader.lastReceivedSampleBuffer)) {
        result = (CMSampleBufferRef)CFRetain(reader.lastReceivedSampleBuffer);
        if (callCount % 100 == 0) {
            writeLog(@"[CAMERA] Usando lastReceivedSampleBuffer do MJPEGReader");
        }
        return result;
    }
    
    // Tentar obter um novo frame diretamente
    if (reader.isConnected) {
        // Aqui podemos tentar forçar uma captura imediata se necessário
        if (callCount % 300 == 0) {
            writeLog(@"[CAMERA] Tentando obter novo frame diretamente");
        }
    }
    
    if (!result && callCount % 300 == 0) {
        writeLog(@"[CAMERA] Nenhum buffer disponível para substituição");
    }
    
    return NULL;
}

// Método principal corrigido para garantir que os frames sejam processados corretamente
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.isActive) return;
    
    @try {
        // Verificar se o buffer é válido
        if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) {
            return;
        }
        
        // Armazenar o sample buffer mais recente com proteção
        @synchronized (self) {
            // Limpar o anterior com verificação
            if (_latestSampleBuffer) {
                CFRelease(_latestSampleBuffer);
                _latestSampleBuffer = NULL;
            }
            
            // Retenha o buffer (aumente a contagem de referência)
            _latestSampleBuffer = (CMSampleBufferRef)CFRetain(sampleBuffer);
            
            if (_debugMode && (++_frameCounter % 300 == 0)) {
                writeLog(@"[CAMERA] Novo frame MJPEG processado e armazenado (#%d)", _frameCounter);
                
                // Detalhes do tipo de buffer para depuração
                CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
                if (formatDesc) {
                    FourCharCode mediaType = CMFormatDescriptionGetMediaType(formatDesc);
                    FourCharCode mediaSubType = CMFormatDescriptionGetMediaSubType(formatDesc);
                    char typeStr[5] = {0};
                    char subTypeStr[5] = {0};
                    
                    // Convertendo FourCharCode para string legível
                    typeStr[0] = (char)((mediaType >> 24) & 0xFF);
                    typeStr[1] = (char)((mediaType >> 16) & 0xFF);
                    typeStr[2] = (char)((mediaType >> 8) & 0xFF);
                    typeStr[3] = (char)(mediaType & 0xFF);
                    
                    subTypeStr[0] = (char)((mediaSubType >> 24) & 0xFF);
                    subTypeStr[1] = (char)((mediaSubType >> 16) & 0xFF);
                    subTypeStr[2] = (char)((mediaSubType >> 8) & 0xFF);
                    subTypeStr[3] = (char)(mediaSubType & 0xFF);
                    
                    writeLog(@"[CAMERA] Media Type: %s, SubType: %s", typeStr, subTypeStr);
                }
                
                // Log de dimensões
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                if (imageBuffer) {
                    size_t width = CVPixelBufferGetWidth(imageBuffer);
                    size_t height = CVPixelBufferGetHeight(imageBuffer);
                    writeLog(@"[CAMERA] Frame dimensões: %zu x %zu", width, height);
                }
            }
        }
    } @catch (NSException *exception) {
        writeLog(@"[CAMERA] Erro ao processar sampleBuffer: %@", exception);
    }
}

@end

// Implementação do substituidor de feed da câmera
@implementation VirtualCameraFeedReplacer

// Método para substituir o buffer da câmera com um buffer de MJPEG
+ (CMSampleBufferRef)replaceCameraSampleBuffer:(CMSampleBufferRef)originalBuffer withMJPEGBuffer:(CMSampleBufferRef)mjpegBuffer {
    if (!mjpegBuffer || !CMSampleBufferIsValid(mjpegBuffer)) {
        return originalBuffer;
    }
    
    // Simplesmente retornar o buffer MJPEG
    return (CMSampleBufferRef)CFRetain(mjpegBuffer);
}

@end
