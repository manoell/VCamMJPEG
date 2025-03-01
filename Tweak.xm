#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"

// URL do servidor MJPEG
static NSString *const kDefaultServerURL = @"http://192.168.0.178:8080/mjpeg";

// Leitor de MJPEG simples
@interface MJPEGReader : NSObject <NSURLSessionDataDelegate>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *dataTask;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, copy) void (^frameCallback)(UIImage *);
@property (nonatomic, assign) BOOL isConnected;

+ (instancetype)sharedInstance;
- (void)startStreamingFromURL:(NSURL *)url;
- (void)stopStreaming;

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
        self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        self.buffer = [NSMutableData data];
        self.isConnected = NO;
    }
    return self;
}

- (void)startStreamingFromURL:(NSURL *)url {
    writeLog(@"[MJPEG] Iniciando streaming de: %@", url.absoluteString);
    
    [self stopStreaming];
    
    self.buffer = [NSMutableData data];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"multipart/x-mixed-replace" forHTTPHeaderField:@"Accept"];
    
    self.dataTask = [self.session dataTaskWithRequest:request];
    [self.dataTask resume];
    
    writeLog(@"[MJPEG] Tarefa de streaming iniciada");
}

- (void)stopStreaming {
    if (self.dataTask) {
        writeLog(@"[MJPEG] Parando streaming");
        [self.dataTask cancel];
        self.dataTask = nil;
        self.isConnected = NO;
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    writeLog(@"[MJPEG] Conexão estabelecida com o servidor");
    self.isConnected = YES;
    [self.buffer setLength:0];
    completionHandler(NSURLSessionResponseAllow);
}

// Detecta os marcadores JPEG para extrair as imagens do stream
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.buffer appendData:data];
    
    // Processar dados recebidos - procurar por frames JPEG
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
}

- (void)processJPEGData:(NSData *)jpegData {
    UIImage *image = [UIImage imageWithData:jpegData];
    if (image && self.frameCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.frameCallback(image);
        });
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        if (error.code != NSURLErrorCancelled) { // Ignore cancelamento intencional
            writeLog(@"[MJPEG] Erro no streaming: %@", error);
            self.isConnected = NO;
            
            // Tentar reconectar
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self startStreamingFromURL:task.originalRequest.URL];
            });
        }
    } else {
        writeLog(@"[MJPEG] Streaming concluído");
        self.isConnected = NO;
    }
}

@end

// Janela de preview
@interface MJPEGPreviewWindow : UIWindow

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, assign) NSInteger frameCount;
@property (nonatomic, strong) NSDate *lastFPSUpdate;

+ (instancetype)sharedInstance;
- (void)show;
- (void)updateStatus:(NSString *)status;
- (void)updatePreviewImage:(UIImage *)image;

@end

@implementation MJPEGPreviewWindow

+ (instancetype)sharedInstance {
    static MJPEGPreviewWindow *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initWithFrame:CGRectMake(20, 60, 200, 260)];
    });
    return sharedInstance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Configuração básica
        self.windowLevel = UIWindowLevelAlert + 100;
        self.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0.8 alpha:0.9];
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        self.hidden = YES;
        
        // Status label
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 180, 40)];
        self.statusLabel.text = @"VirtualCam\nDesconectado";
        self.statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        self.statusLabel.textColor = [UIColor whiteColor];
        self.statusLabel.numberOfLines = 0;
        self.statusLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:self.statusLabel];
        
        // Preview image view
        self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(10, 60, 180, 120)];
        self.previewImageView.backgroundColor = [UIColor blackColor];
        self.previewImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.previewImageView.layer.cornerRadius = 6;
        self.previewImageView.clipsToBounds = YES;
        [self addSubview:self.previewImageView];
        
        // FPS label
        self.fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 190, 180, 20)];
        self.fpsLabel.text = @"FPS: --";
        self.fpsLabel.font = [UIFont systemFontOfSize:12];
        self.fpsLabel.textColor = [UIColor whiteColor];
        self.fpsLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:self.fpsLabel];
        
        // Connect button
        self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.connectButton.frame = CGRectMake(10, 220, 180, 30);
        [self.connectButton setTitle:@"Conectar" forState:UIControlStateNormal];
        self.connectButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
        self.connectButton.layer.cornerRadius = 6;
        [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.connectButton addTarget:self action:@selector(connectButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.connectButton];
        
        // Inicializar contadores de FPS
        self.frameCount = 0;
        self.lastFPSUpdate = [NSDate date];
        
        writeLog(@"[UI] MJPEGPreviewWindow inicializado");
    }
    return self;
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hidden = NO;
        [self makeKeyAndVisible];
        writeLog(@"[UI] MJPEGPreviewWindow mostrado");
    });
}

- (void)updateStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
    });
}

- (void)updatePreviewImage:(UIImage *)image {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.previewImageView.image = image;
        
        // Atualizar contador de FPS
        self.frameCount++;
        NSTimeInterval elapsed = -[self.lastFPSUpdate timeIntervalSinceNow];
        
        if (elapsed >= 1.0) { // Atualizar FPS a cada segundo
            CGFloat fps = self.frameCount / elapsed;
            self.fpsLabel.text = [NSString stringWithFormat:@"FPS: %.1f", fps];
            
            self.frameCount = 0;
            self.lastFPSUpdate = [NSDate date];
        }
    });
}

- (void)connectButtonTapped {
    if (!self.isConnected) {
        writeLog(@"[UI] Botão conectar pressionado");
        [self updateStatus:@"VirtualCam\nConectando..."];
        
        // Configurar leitor MJPEG
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        
        // Configurar callback para frames recebidos
        __weak typeof(self) weakSelf = self;
        reader.frameCallback = ^(UIImage *image) {
            [weakSelf updatePreviewImage:image];
        };
        
        // Iniciar streaming
        NSURL *url = [NSURL URLWithString:kDefaultServerURL];
        [reader startStreamingFromURL:url];
        
        self.isConnected = YES;
        [self.connectButton setTitle:@"Desconectar" forState:UIControlStateNormal];
    } else {
        // Desconectar
        [[MJPEGReader sharedInstance] stopStreaming];
        
        self.isConnected = NO;
        [self.connectButton setTitle:@"Conectar" forState:UIControlStateNormal];
        [self updateStatus:@"VirtualCam\nDesconectado"];
        self.previewImageView.image = nil;
        self.fpsLabel.text = @"FPS: --";
    }
}

@end

// Constructor - roda quando o tweak é carregado
%ctor {
    @autoreleasepool {
        // Configurar nível de log
        setLogLevel(4); // Nível debug para ver logs
        
        NSString *processName = [NSProcessInfo processInfo].processName;
        writeLog(@"[INIT] VirtualCam MJPEG carregado em processo: %@", processName);
        
        // APENAS inicializar no SpringBoard para mostrar a UI
        if ([processName isEqualToString:@"SpringBoard"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                writeLog(@"[INIT] Mostrando janela de preview em SpringBoard");
                [[MJPEGPreviewWindow sharedInstance] show];
            });
        }
    }
}
