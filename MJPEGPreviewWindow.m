#import "MJPEGPreviewWindow.h"
#import "MJPEGReader.h"
#import "logger.h"
#import "VirtualCameraController.h"

// URL do servidor MJPEG padrão
static NSString *const kDefaultServerURL = @"http://192.168.0.178:8080/mjpeg";

@implementation MJPEGPreviewWindow

+ (instancetype)sharedInstance {
    static MJPEGPreviewWindow *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initWithFrame:CGRectMake(20, 60, 200, 320)];
    });
    return sharedInstance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Configuração básica - reduzir nível da janela
        self.windowLevel = UIWindowLevelNormal + 50; // Em vez de UIWindowLevelAlert + 100
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
        
        // Preview image view - começa com hidden
        self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(10, 60, 180, 120)];
        self.previewImageView.backgroundColor = [UIColor blackColor];
        self.previewImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.previewImageView.layer.cornerRadius = 6;
        self.previewImageView.clipsToBounds = YES;
        self.previewImageView.hidden = YES; // Inicialmente escondido
        [self addSubview:self.previewImageView];
        
        // Botão para ativar/desativar preview
        UIButton *previewToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        previewToggleButton.frame = CGRectMake(10, 60, 180, 30);
        [previewToggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        previewToggleButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
        previewToggleButton.layer.cornerRadius = 6;
        [previewToggleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [previewToggleButton addTarget:self action:@selector(togglePreview:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:previewToggleButton];
        self.previewToggleButton = previewToggleButton;
        
        // FPS label - inicialmente escondido
        self.fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 190, 180, 20)];
        self.fpsLabel.text = @"FPS: --";
        self.fpsLabel.font = [UIFont systemFontOfSize:12];
        self.fpsLabel.textColor = [UIColor whiteColor];
        self.fpsLabel.textAlignment = NSTextAlignmentCenter;
        self.fpsLabel.hidden = YES; // Inicialmente escondido
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
        
        // Botão de fechar/minimizar
        UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        closeButton.frame = CGRectMake(10, 290, 180, 25);
        [closeButton setTitle:@"Minimizar Interface" forState:UIControlStateNormal];
        closeButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
        closeButton.layer.cornerRadius = 6;
        [closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [closeButton addTarget:self action:@selector(hideInterface) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeButton];
        
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

// Método para ativar/desativar a prévia
- (void)togglePreview:(UIButton *)sender {
    if (self.previewImageView.hidden) {
        // Ativar preview
        self.previewImageView.hidden = NO;
        self.fpsLabel.hidden = NO;
        [sender setTitle:@"Desativar Preview" forState:UIControlStateNormal];
        
        // Ajustar posição do botão para ficar embaixo do preview
        CGRect frame = sender.frame;
        frame.origin.y = 190;
        sender.frame = frame;
    } else {
        // Desativar preview
        self.previewImageView.hidden = YES;
        self.fpsLabel.hidden = YES;
        [sender setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        
        // Retornar botão para posição original
        CGRect frame = sender.frame;
        frame.origin.y = 60;
        sender.frame = frame;
    }
}

// Esconder interface (minimizar)
- (void)hideInterface {
    self.hidden = YES;
    
    // Aguardar alguns segundos e mostrar apenas um pequeno indicador
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIButton *showButton = [UIButton buttonWithType:UIButtonTypeCustom];
        showButton.frame = CGRectMake(5, 60, 30, 30);
        showButton.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0.8 alpha:0.7];
        showButton.layer.cornerRadius = 15;
        [showButton setTitle:@"VC" forState:UIControlStateNormal];
        [showButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [showButton addTarget:self action:@selector(showInterface) forControlEvents:UIControlEventTouchUpInside];
        
        // Adicionar à janela de toque
        UIWindow *touchWindow = [[UIWindow alloc] initWithFrame:CGRectMake(5, 60, 30, 30)];
        touchWindow.windowLevel = UIWindowLevelNormal + 50;
        touchWindow.backgroundColor = [UIColor clearColor];
        [touchWindow addSubview:showButton];
        [touchWindow makeKeyAndVisible];
        self.touchWindow = touchWindow;
    });
}

// Mostrar interface completa novamente
- (void)showInterface {
    self.hidden = NO;
    [self makeKeyAndVisible];
    
    // Remover o botão de toque
    if (self.touchWindow) {
        self.touchWindow.hidden = YES;
        self.touchWindow = nil;
    }
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
        // Verificar se estamos no processo certo
        if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
            writeLog(@"[UI] Tentativa de mostrar janela fora do SpringBoard!");
            return;
        }
        
        self.hidden = NO;
        [self makeKeyAndVisible];
        writeLog(@"[UI] MJPEGPreviewWindow mostrado com segurança");
    });
}

- (void)updateStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
    });
}

- (void)updatePreviewImage:(UIImage *)image {
    // Só atualizar se o preview estiver visível
    if (self.previewImageView.hidden) {
        return;
    }
    
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
    @try {
        if (!self.isConnected) {
            writeLog(@"[UI] Botão conectar pressionado");
            [self updateStatus:@"VirtualCam\nConectando..."];
            
            NSString *serverUrl = self.serverTextField.text;
            if (![serverUrl hasPrefix:@"http://"]) {
                serverUrl = [@"http://" stringByAppendingString:serverUrl];
            }
            
            // Criar URL e verificar validade
            NSURL *url = [NSURL URLWithString:serverUrl];
            if (!url) {
                [self updateStatus:@"VirtualCam\nURL inválida"];
                return;
            }
            
            // IMPORTANTE: Ativar o VirtualCameraController PRIMEIRO
            // Isso garante que qualquer app que use a câmera receba o feed substituído
            [[VirtualCameraController sharedInstance] startCapturing];
            
            // Configurar MJPEGReader
            MJPEGReader *reader = [MJPEGReader sharedInstance];
            
            // Configurar callback para UI - apenas se o preview estiver ativo
            if (!self.previewImageView.hidden) {
                __weak typeof(self) weakSelf = self;
                reader.frameCallback = ^(UIImage *image) {
                    [weakSelf updatePreviewImage:image];
                };
            } else {
                // Desativar callback se preview estiver desativado
                reader.frameCallback = nil;
            }
            
            // Iniciar streaming de forma protegida
            @try {
                [reader startStreamingFromURL:url];
                self.isConnected = YES;
                [self.connectButton setTitle:@"Desconectar" forState:UIControlStateNormal];
                [self updateStatus:@"VirtualCam\nConectado"];
            } @catch (NSException *e) {
                writeLog(@"[UI] Erro ao iniciar streaming: %@", e);
                [self updateStatus:@"VirtualCam\nErro ao conectar"];
            }
        } else {
            // Desconectar de forma protegida
            @try {
                [[MJPEGReader sharedInstance] stopStreaming];
                self.isConnected = NO;
                [self.connectButton setTitle:@"Conectar" forState:UIControlStateNormal];
                [self updateStatus:@"VirtualCam\nDesconectado"];
                self.previewImageView.image = nil;
                self.fpsLabel.text = @"FPS: --";
                
                // Parar o VirtualCameraController também
                [[VirtualCameraController sharedInstance] stopCapturing];
            } @catch (NSException *e) {
                writeLog(@"[UI] Erro ao parar streaming: %@", e);
            }
        }
    } @catch (NSException *exception) {
        writeLog(@"[UI] Erro geral em connectButtonTapped: %@", exception);
    }
}

@end
