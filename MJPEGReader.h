#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Definir modos de processamento
typedef NS_ENUM(NSInteger, MJPEGReaderProcessingMode) {
   MJPEGReaderProcessingModeDefault = 0,           // Modo padrão
   MJPEGReaderProcessingModeHighPerformance = 1,   // Alta performance - otimizado para vídeo
   MJPEGReaderProcessingModeHighQuality = 2        // Alta qualidade - otimizado para fotos
};

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
@property (nonatomic, assign) MJPEGReaderProcessingMode processingMode; // Novo: modo de processamento

+ (instancetype)sharedInstance;
- (void)startStreamingFromURL:(NSURL *)url;
- (void)stopStreaming;
- (CMSampleBufferRef)createSampleBufferFromJPEGData:(NSData *)jpegData withSize:(CGSize)size;
- (void)setHighPriority:(BOOL)enabled; // Método para configurar prioridade
- (void)setProcessingMode:(MJPEGReaderProcessingMode)mode; // Método para configurar modo de processamento

@end
