#import "MJPEGPreviewWindow.h"
#import "MJPEGReader.h"
#import "logger.h"
#import "VirtualCameraController.h"

// URL do servidor MJPEG padrão
static NSString *const kDefaultServerURL = @"http://192.168.0.178:8080/mjpeg";

// Tamanhos e constantes
static CGFloat const kMinimizedSize = 44.0;
static CGFloat const kExpandedWidth = 240.0;
static CGFloat const kExpandedHeight = 150.0;
static CGFloat const kMargin = 10.0;
static CGFloat const kButtonHeight = 40.0;
static CGFloat const kCornerRadius = 22.0;

@implementation MJPEGPreviewWindow

+ (instancetype)sharedInstance {
    static MJPEGPreviewWindow *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Inicializar com tamanho minimizado e posição padrão
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGRect initialFrame = CGRectMake(screenBounds.size.width - kMinimizedSize - 20,
                                        screenBounds.size.height / 2,
                                        kMinimizedSize,
                                        kMinimizedSize);
        sharedInstance = [[self alloc] initWithFrame:initialFrame];
    });
    return sharedInstance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Configuração básica da janela
        self.windowLevel = UIWindowLevelNormal + 50;
        self.layer.cornerRadius = kCornerRadius;
        self.clipsToBounds = YES;
        self.hidden = YES;
        
        // Estado inicial
        _isExpanded = NO;
        _connectionState = ConnectionStateDisconnected;
        
        // Inicializar visualizações
        [self setupMinimizedView];
        [self setupExpandedView];
        
        // Configurar gestos
        [self setupGestures];
        
        // Mostrar visualização correta para o estado inicial
        self.expandedView.hidden = YES;
        self.minimizedView.hidden = NO;
        
        writeLog(@"[UI] MJPEGPreviewWindow inicializado em modo minimizado");
    }
    return self;
}

#pragma mark - Configuração de Views

- (void)setupMinimizedView {
    // Criar a view minimizada (círculo)
    self.minimizedView = [[UIView alloc] initWithFrame:self.bounds];
    self.minimizedView.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.9]; // Vermelho para desconectado
    [self addSubview:self.minimizedView];
    
    // Ícone ou símbolo para indicar camera virtual
    UIImageView *cameraIcon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
    cameraIcon.center = CGPointMake(kMinimizedSize/2, kMinimizedSize/2);
    cameraIcon.contentMode = UIViewContentModeScaleAspectFit;
    cameraIcon.tintColor = [UIColor whiteColor];
    
    // Usar símbolo de câmera se disponível, ou texto se não
    if (@available(iOS 13.0, *)) {
        UIImage *image = [UIImage systemImageNamed:@"camera.fill"];
        if (image) {
            cameraIcon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        } else {
            cameraIcon.image = nil;
            
            // Usar texto se não tiver ícone
            UILabel *vcLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, kMinimizedSize, kMinimizedSize)];
            vcLabel.text = @"VC";
            vcLabel.textAlignment = NSTextAlignmentCenter;
            vcLabel.textColor = [UIColor whiteColor];
            vcLabel.font = [UIFont boldSystemFontOfSize:16];
            [self.minimizedView addSubview:vcLabel];
        }
    } else {
        // Fallback para versões mais antigas - usar texto
        UILabel *vcLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, kMinimizedSize, kMinimizedSize)];
        vcLabel.text = @"VC";
        vcLabel.textAlignment = NSTextAlignmentCenter;
        vcLabel.textColor = [UIColor whiteColor];
        vcLabel.font = [UIFont boldSystemFontOfSize:16];
        [self.minimizedView addSubview:vcLabel];
    }
    
    if (cameraIcon.image) {
        [self.minimizedView addSubview:cameraIcon];
    }
}

- (void)setupExpandedView {
    // Criar a view expandida
    self.expandedView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kExpandedWidth, kExpandedHeight)];
    self.expandedView.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.9]; // Fundo escuro
    [self addSubview:self.expandedView];
    
    // Status label
    CGFloat yPos = kMargin;
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(kMargin, yPos, kExpandedWidth - kMargin*2, 30)];
    self.statusLabel.text = @"VirtualCam Desconectado";
    self.statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.expandedView addSubview:self.statusLabel];
    
    // Campo de texto para servidor
    yPos += self.statusLabel.frame.size.height + kMargin;
    self.serverTextField = [[UITextField alloc] initWithFrame:CGRectMake(kMargin, yPos, kExpandedWidth - kMargin*2, 36)];
    self.serverTextField.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    self.serverTextField.textColor = [UIColor whiteColor];
    self.serverTextField.font = [UIFont systemFontOfSize:14];
    self.serverTextField.placeholder = @"IP:porta/mjpeg";
    self.serverTextField.text = [kDefaultServerURL stringByReplacingOccurrencesOfString:@"http://" withString:@""];
    self.serverTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.serverTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.serverTextField.layer.cornerRadius = 8;
    self.serverTextField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 36)];
    self.serverTextField.leftViewMode = UITextFieldViewModeAlways;
    self.serverTextField.returnKeyType = UIReturnKeyDone;
    [self.expandedView addSubview:self.serverTextField];
    
    // Botão conectar/desconectar
    yPos += self.serverTextField.frame.size.height + kMargin;
    self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.connectButton.frame = CGRectMake(kMargin, yPos, kExpandedWidth - kMargin*2, kButtonHeight);
    [self.connectButton setTitle:@"Conectar" forState:UIControlStateNormal];
    self.connectButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.8]; // Verde
    self.connectButton.layer.cornerRadius = 8;
    [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.connectButton addTarget:self action:@selector(connectButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.expandedView addSubview:self.connectButton];
    
    // Removido o botão de minimizar pois agora usamos duplo toque
}

- (void)setupGestures {
    // Gesture para arrastar
    self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:self.panGesture];
    
    // Gesture para dois toques (expandir/minimizar)
    self.doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleExpanded)];
    self.doubleTapGesture.numberOfTapsRequired = 2;
    [self addGestureRecognizer:self.doubleTapGesture];
}

#pragma mark - Controle de Estado

- (void)toggleExpanded {
    // Calcular nova posição para centralizar quando expandir
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGRect newFrame;
    
    if (!self.isExpanded) {
        // Expandir
        CGFloat expandedX = self.frame.origin.x - (kExpandedWidth - kMinimizedSize) / 2;
        CGFloat expandedY = self.frame.origin.y - (kExpandedHeight - kMinimizedSize) / 2;
        
        // Certificar que o frame expandido não saia da tela
        if (expandedX < 0) expandedX = 10;
        if (expandedY < 0) expandedY = 10;
        if (expandedX + kExpandedWidth > screenBounds.size.width)
            expandedX = screenBounds.size.width - kExpandedWidth - 10;
        if (expandedY + kExpandedHeight > screenBounds.size.height)
            expandedY = screenBounds.size.height - kExpandedHeight - 10;
        
        newFrame = CGRectMake(expandedX, expandedY, kExpandedWidth, kExpandedHeight);
    } else {
        // Minimizar - manter a mesma posição central
        CGFloat minimizedX = self.frame.origin.x + (kExpandedWidth - kMinimizedSize) / 2;
        CGFloat minimizedY = self.frame.origin.y + (kExpandedHeight - kMinimizedSize) / 2;
        
        // Garantir que fique dentro da tela
        if (minimizedX < 0) minimizedX = 10;
        if (minimizedY < 0) minimizedY = 10;
        if (minimizedX + kMinimizedSize > screenBounds.size.width)
            minimizedX = screenBounds.size.width - kMinimizedSize - 10;
        if (minimizedY + kMinimizedSize > screenBounds.size.height)
            minimizedY = screenBounds.size.height - kMinimizedSize - 10;
        
        newFrame = CGRectMake(minimizedX, minimizedY, kMinimizedSize, kMinimizedSize);
    }
    
    // Animar a transição
    [UIView animateWithDuration:0.25 animations:^{
        self.frame = newFrame;
        self.layer.cornerRadius = self.isExpanded ? 12 : kCornerRadius;
    } completion:^(BOOL finished) {
        // Atualizar estado e visibilidades
        self.isExpanded = !self.isExpanded;
        self.expandedView.hidden = !self.isExpanded;
        self.minimizedView.hidden = self.isExpanded;
    }];
}

- (void)updateConnectionState:(ConnectionState)state {
    self.connectionState = state;
    
    UIColor *backgroundColor;
    NSString *statusText;
    UIColor *buttonColor;
    NSString *buttonText;
    
    switch (state) {
        case ConnectionStateConnected:
            backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.9]; // Verde
            statusText = @"VirtualCam Conectado";
            buttonColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.8]; // Vermelho
            buttonText = @"Desconectar";
            break;
            
        case ConnectionStateError:
            backgroundColor = [UIColor colorWithRed:0.9 green:0.5 blue:0.1 alpha:0.9]; // Laranja
            statusText = @"VirtualCam ERRO";
            buttonColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.8]; // Verde
            buttonText = @"Tentar Novamente";
            break;
            
        case ConnectionStateDisconnected:
        default:
            backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.9]; // Vermelho
            statusText = @"VirtualCam Desconectado";
            buttonColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.8]; // Verde
            buttonText = @"Conectar";
            break;
    }
    
    // Atualizar visualmente
    [UIView animateWithDuration:0.3 animations:^{
        self.minimizedView.backgroundColor = backgroundColor;
        self.statusLabel.text = statusText;
        self.connectButton.backgroundColor = buttonColor;
        [self.connectButton setTitle:buttonText forState:UIControlStateNormal];
    }];
}

#pragma mark - Gestos e Interações

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    // Obter nova posição
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    
    // Limitar aos limites da tela
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat halfWidth = self.bounds.size.width / 2;
    CGFloat halfHeight = self.bounds.size.height / 2;
    
    // Limites de x
    if (newCenter.x - halfWidth < 0) {
        newCenter.x = halfWidth;
    } else if (newCenter.x + halfWidth > bounds.size.width) {
        newCenter.x = bounds.size.width - halfWidth;
    }
    
    // Limites de y
    if (newCenter.y - halfHeight < 0) {
        newCenter.y = halfHeight;
    } else if (newCenter.y + halfHeight > bounds.size.height) {
        newCenter.y = bounds.size.height - halfHeight;
    }
    
    // Atualizar posição
    self.center = newCenter;
    
    // Resetar a translação
    [gesture setTranslation:CGPointZero inView:self];
}

#pragma mark - Ações de Botões

- (void)connectButtonTapped {
    @try {
        BOOL isConnected = (self.connectionState == ConnectionStateConnected);
        
        if (!isConnected) {
            writeLog(@"[UI] Botão conectar pressionado");
            [self updateStatus:@"VirtualCam\nConectando..."];
            
            NSString *serverUrl = self.serverTextField.text;
            if (![serverUrl hasPrefix:@"http://"]) {
                serverUrl = [@"http://" stringByAppendingString:serverUrl];
            }
            
            // Criar URL e verificar validade
            NSURL *url = [NSURL URLWithString:serverUrl];
            if (!url) {
                [self updateConnectionState:ConnectionStateError];
                [self updateStatus:@"VirtualCam\nURL inválida"];
                return;
            }
            
            // Ativar o VirtualCameraController
            [[VirtualCameraController sharedInstance] startCapturing];
            
            // Configurar MJPEGReader
            MJPEGReader *reader = [MJPEGReader sharedInstance];
            
            // Iniciar streaming de forma protegida
            @try {
                [reader startStreamingFromURL:url];
                [self updateConnectionState:ConnectionStateConnected];
            } @catch (NSException *e) {
                writeLog(@"[UI] Erro ao iniciar streaming: %@", e);
                [self updateConnectionState:ConnectionStateError];
            }
        } else {
            // Desconectar de forma protegida
            @try {
                [[MJPEGReader sharedInstance] stopStreaming];
                [[VirtualCameraController sharedInstance] stopCapturing];
                [self updateConnectionState:ConnectionStateDisconnected];
            } @catch (NSException *e) {
                writeLog(@"[UI] Erro ao parar streaming: %@", e);
                [self updateConnectionState:ConnectionStateError];
            }
        }
    } @catch (NSException *exception) {
        writeLog(@"[UI] Erro geral em connectButtonTapped: %@", exception);
        [self updateConnectionState:ConnectionStateError];
    }
}

#pragma mark - Métodos Públicos

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Verificar se estamos no processo certo
        if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) {
            writeLog(@"[UI] Tentativa de mostrar janela fora do SpringBoard!");
            return;
        }
        
        self.hidden = NO;
        [self makeKeyAndVisible];
        writeLog(@"[UI] MJPEGPreviewWindow mostrado com segurança (minimizado)");
    });
}

- (void)updateStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
    });
}

@end
