#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Variável global para status da conexão
extern BOOL gGlobalReaderConnected;

// Leitor de MJPEG
@interface MJPEGReader : NSObject <NSURLSessionDataDelegate>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *dataTask;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, copy) void (^frameCallback)(UIImage *);
@property (nonatomic, copy) void (^sampleBufferCallback)(CMSampleBufferRef);
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isReconnecting;
@property (nonatomic, assign) CGSize lastKnownResolution;
@property (nonatomic, strong) NSURL *currentURL;
@property (nonatomic, assign) CMSampleBufferRef lastReceivedSampleBuffer;
@property (nonatomic, assign) BOOL highPriorityMode; // Propriedade para modo de alta prioridade

+ (instancetype)sharedInstance;
- (void)startStreamingFromURL:(NSURL *)url;
- (void)stopStreaming;
- (CMSampleBufferRef)createSampleBufferFromJPEGData:(NSData *)jpegData withSize:(CGSize)size;
- (void)setHighPriority:(BOOL)enabled; // Método para configurar prioridade

@end
