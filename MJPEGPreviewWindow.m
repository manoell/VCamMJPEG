#import "MJPEGPreviewWindow.h"
#import "MJPEGReader.h"
#import "logger.h"
#import "VirtualCameraController.h"
#import <notify.h>

// URL do servidor MJPEG padrão
static NSString *const kDefaultServerURL = @"http://192.168.0.178:8080/mjpeg";

@implementation MJPEGPreviewWindow {
    UITapGestureRecognizer *_doubleTapGesture;
    BOOL _isMinimized;
    CGRect _normalFrame;
    CGRect _minimizedFrame;
}

+ (instancetype)sharedInstance {
    static MJPEGPreviewWindow *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initWithFrame:CGRectMake(20, 60, 200, 120)];
    });
    return sharedInstance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Configuração básica - reduzir nível da janela
        self.windowLevel = UIWindowLevelNormal + 50;
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.9];
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        self.hidden = YES;
        
        // Salvar dimensões para minimizar/maximizar
        _normalFrame = frame;
        _minimizedFrame = CGRectMake(20, 60, 40, 40);
        _isMinimized = NO;
        
        // Status label
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 180, 30)];
        self.statusLabel.text = @"VirtualCam";
        self.statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        self.statusLabel.textColor = [UIColor whiteColor];
        self.statusLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:self.statusLabel];
        
        // Servidor TextField
        self.serverTextField = [[UITextField alloc] initWithFrame:CGRectMake(10, 50, 180, 25)];
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
        
        // Connect/Toggle button - INICIALMENTE DESATIVADO (VERMELHO)
        self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.connectButton.frame = CGRectMake(10, 85, 180, 25);
        [self.connectButton setTitle:@"Ativar Câmera Virtual" forState:UIControlStateNormal];
        self.connectButton.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.9]; // Vermelho para desativado
        self.connectButton.layer.cornerRadius = 6;
        [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.connectButton addTarget:self action:@selector(connectButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.connectButton];
        
        // Adicionar gesture recognizer para arrastar
        self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:self.panGesture];
        
        // Gesture recognizer para minimizar com duplo toque
        _doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        _doubleTapGesture.numberOfTapsRequired = 2;
        [self addGestureRecognizer:_doubleTapGesture];
        
        // Inicializar estado - SEMPRE DESATIVADO POR PADRÃO
        self.isConnected = NO;
        [self updateStatus:@"VirtualCam\nInativo"];
        
        // Forçar desativação nos NSUserDefaults no início
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"VCamMJPEG_Enabled"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        writeLog(@"[UI] MJPEGPreviewWindow inicializado");
    }
    return self;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    if (_isMinimized) {
        [self maximizeWindow];
    } else {
        [self minimizeWindow];
    }
}

- (void)minimizeWindow {
    if (_isMinimized) return;
    
    // Animação para minimizar
    [UIView animateWithDuration:0.3 animations:^{
        self.frame = _minimizedFrame;
        self.statusLabel.frame = CGRectMake(0, 0, 40, 40);
        self.statusLabel.text = @"VC";
        
        // Esconder os outros elementos
        self.serverTextField.alpha = 0;
        self.connectButton.alpha = 0;
    } completion:^(BOOL finished) {
        _isMinimized = YES;
    }];
}

- (void)maximizeWindow {
    if (!_isMinimized) return;
    
    // Animação para maximizar
    [UIView animateWithDuration:0.3 animations:^{
        self.frame = _normalFrame;
        self.statusLabel.frame = CGRectMake(10, 10, 180, 30);
        self.statusLabel.text = @"VirtualCam";
        
        // Mostrar os outros elementos
        self.serverTextField.alpha = 1;
        self.connectButton.alpha = 1;
    } completion:^(BOOL finished) {
        _isMinimized = NO;
    }];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    // Mover a janela
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    
    // Resetar a translação
    [gesture setTranslation:CGPointZero inView:self];
    
    // Atualizar frames
    if (_isMinimized) {
        _minimizedFrame = self.frame;
    } else {
        _normalFrame = self.frame;
    }
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
        if (!_isMinimized) {
            self.statusLabel.text = status;
        }
    });
}

- (void)connectButtonTapped {
    @try {
        if (!self.isConnected) {
            writeLog(@"[UI] Botão ativar pressionado");
            [self updateStatus:@"VirtualCam\nConectando..."];
            
            // Desabilitar o botão temporariamente para evitar cliques múltiplos
            self.connectButton.enabled = NO;
            
            NSString *serverUrl = self.serverTextField.text;
            if (![serverUrl hasPrefix:@"http://"]) {
                serverUrl = [@"http://" stringByAppendingString:serverUrl];
            }
            
            // Criar URL e verificar validade
            NSURL *url = [NSURL URLWithString:serverUrl];
            if (!url) {
                [self updateStatus:@"VirtualCam\nURL inválida"];
                self.connectButton.enabled = YES;
                return;
            }
            
            // Armazenar nos defaults
            writeLog(@"[UI] Salvando URL do servidor: %@", serverUrl);
            [[NSUserDefaults standardUserDefaults] setObject:serverUrl forKey:@"VCamMJPEG_ServerURL"];
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"VCamMJPEG_Enabled"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            
            // Ativar diretamente no MJPEGReader
            MJPEGReader *reader = [MJPEGReader sharedInstance];
            [reader startStreamingFromURL:url];
            
            // Ativar o VirtualCameraController
            [[VirtualCameraController sharedInstance] startCapturing];
            
            // Atualizar UI imediatamente
            self.isConnected = YES;
            [self.connectButton setTitle:@"Desativar Câmera Virtual" forState:UIControlStateNormal];
            [self.connectButton setBackgroundColor:[UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.9]]; // Verde para ativado
            [self updateStatus:@"VirtualCam\nAtivo"];
            
            // Reabilitar o botão
            self.connectButton.enabled = YES;
        } else {
            // Desativar a câmera virtual
            writeLog(@"[UI] Botão desativar pressionado");
            
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"VCamMJPEG_Enabled"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            
            // Desativar diretamente
            [[MJPEGReader sharedInstance] stopStreaming];
            [[VirtualCameraController sharedInstance] stopCapturing];
            
            // Atualizar UI imediatamente
            self.isConnected = NO;
            [self.connectButton setTitle:@"Ativar Câmera Virtual" forState:UIControlStateNormal];
            [self.connectButton setBackgroundColor:[UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.9]]; // Vermelho para desativado
            [self updateStatus:@"VirtualCam\nInativo"];
        }
    } @catch (NSException *exception) {
        writeLog(@"[UI] Erro geral em connectButtonTapped: %@", exception);
        [self updateStatus:@"VirtualCam\nErro"];
        self.connectButton.enabled = YES;
    }
}

@end
