#import <UIKit/UIKit.h>
#import <notify.h>

// Janela de preview simplificada
@interface MJPEGPreviewWindow : UIWindow

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UITextField *serverTextField;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;

+ (instancetype)sharedInstance;
- (void)show;
- (void)updateStatus:(NSString *)status;
- (void)minimizeWindow;
- (void)maximizeWindow;

@end
