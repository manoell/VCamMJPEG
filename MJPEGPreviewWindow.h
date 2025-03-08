#import <UIKit/UIKit.h>

// Definição dos estados da conexão
typedef NS_ENUM(NSInteger, ConnectionState) {
    ConnectionStateDisconnected = 0,  // Desconectado (vermelho)
    ConnectionStateConnected = 1,     // Conectado (verde)
    ConnectionStateError = 2,         // Erro (laranja)
    ConnectionStateReconnecting = 3   // Reconectando (amarelo)
};

// Janela de preview estilo assistiveTouch
@interface MJPEGPreviewWindow : UIWindow

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UITextField *serverTextField;
@property (nonatomic, strong) UIView *expandedView;   // Conteúdo expandido
@property (nonatomic, strong) UIView *minimizedView;  // Indicador minimizado (círculo)
@property (nonatomic, assign) BOOL isExpanded;        // Estado atual (expandido/minimizado)
@property (nonatomic, assign) ConnectionState connectionState;  // Estado da conexão
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UITapGestureRecognizer *doubleTapGesture;
@property (nonatomic, strong) NSTimer *reconnectTimer;     // Timer para reconexão automática
@property (nonatomic, strong) NSURL *currentServerURL;     // URL atual do servidor MJPEG

+ (instancetype)sharedInstance;
- (void)show;
- (void)updateStatus:(NSString *)status;
- (void)updateConnectionState:(ConnectionState)state;
- (void)toggleExpanded;  // Alternar entre expandido/minimizado
- (void)connectButtonTapped;  // Método para botão conectar/desconectar
- (void)startReconnectionTimer;
- (void)stopReconnectionTimer;
- (void)tryReconnect;

@end
