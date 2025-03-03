#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

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

+ (instancetype)sharedInstance;
- (void)startStreamingFromURL:(NSURL *)url;
- (void)stopStreaming;
- (CMSampleBufferRef)createSampleBufferFromJPEGData:(NSData *)jpegData withSize:(CGSize)size;

@end
