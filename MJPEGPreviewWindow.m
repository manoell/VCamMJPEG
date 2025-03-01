#import "MJPEGPreviewWindow.h"
#import "MJPEGReader.h"
#import "logger.h"

// URL do servidor MJPEG padrão
static NSString *const kDefaultServerURL = @"http://192.168.0.178:8080/mjpeg";

@implementation MJPEGPreviewWindow

+ (instancetype)sharedInstance {
    static MJPEGPreviewWindow *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initWithFrame:CGRectMake(20, 60, 200, 290)];
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
        
        // Servidor TextField
        self.serverTextField = [[UITextField alloc] initWithFrame:CGRectMake(10, 220, 180, 25)];
        self.serverTextField.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
        self.serverTextField.textColor = [UIColor whiteColor];
        self.serverTextField.font = [UIFont systemFontOfSize:12];
        self.serverTextField.placeholder = @"IP:porta/mjpeg";
        self.serverTextField.text = [kDefaultServerURL stringByReplacingOccurrencesOfString:@"http://" withString:@""];
        self.serverTextField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.serverTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.serverTextField.layer.cornerRadius = 4;
        self.serverTextField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 5, 25)];
        self.serverTextField.leftViewMode = UITextFieldViewModeAlways;
        [self addSubview:self.serverTextField];
        
        // Connect button
        self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.connectButton.frame = CGRectMake(10, 255, 180, 25);
        [self.connectButton setTitle:@"Conectar" forState:UIControlStateNormal];
        self.connectButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
        self.connectButton.layer.cornerRadius = 6;
        [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.connectButton addTarget:self action:@selector(connectButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.connectButton];
        
        // Inicializar contadores de FPS
        self.frameCount = 0;
        self.lastFPSUpdate = [NSDate date];
        
        // Adicionar gesture recognizer para arrastar
        self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:self.panGesture];
        
        writeLog(@"[UI] MJPEGPreviewWindow inicializado");
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    // Mover a janela
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    
    // Resetar a translação
    [gesture setTranslation:CGPointZero inView:self];
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
        
        // Obter URL do servidor do campo de texto
        NSString *serverUrl = self.serverTextField.text;
        if (![serverUrl hasPrefix:@"http://"]) {
            serverUrl = [@"http://" stringByAppendingString:serverUrl];
        }
        
        // Configurar leitor MJPEG
        MJPEGReader *reader = [MJPEGReader sharedInstance];
        
        // Configurar callback para frames recebidos
        __weak typeof(self) weakSelf = self;
        reader.frameCallback = ^(UIImage *image) {
            [weakSelf updatePreviewImage:image];
        };
        
        // Iniciar streaming
        NSURL *url = [NSURL URLWithString:serverUrl];
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
