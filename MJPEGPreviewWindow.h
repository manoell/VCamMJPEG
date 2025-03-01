#import <UIKit/UIKit.h>

// Janela de preview
@interface MJPEGPreviewWindow : UIWindow

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, assign) NSInteger frameCount;
@property (nonatomic, strong) NSDate *lastFPSUpdate;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UITextField *serverTextField;

+ (instancetype)sharedInstance;
- (void)show;
- (void)updateStatus:(NSString *)status;
- (void)updatePreviewImage:(UIImage *)image;

@end
