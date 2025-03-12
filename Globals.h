#ifndef GLOBALS_H
#define GLOBALS_H

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Definição para verificação de versão do iOS
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)

// Variáveis globais compartilhadas entre arquivos
extern dispatch_queue_t g_processingQueue;
extern AVSampleBufferDisplayLayer *g_customDisplayLayer;
extern CALayer *g_maskLayer;
extern CADisplayLink *g_displayLink;
extern NSString *g_tempFile;
extern BOOL g_isVideoOrientationSet;
extern int g_videoOrientation;
extern BOOL g_isCapturingPhoto;
extern CGSize g_originalCameraResolution;
extern CGSize g_originalFrontCameraResolution;
extern CGSize g_originalBackCameraResolution;
extern BOOL g_usingFrontCamera;
extern BOOL g_isRecordingVideo; // Indica se estamos gravando vídeo

// Função para registro de delegados ativos
void logDelegates(void);

// Função para detectar dimensões da câmera
void detectCameraResolutions(void);

// Nova função para mapeamento de orientação
UIImageOrientation getOrientationFromVideoOrientation(int videoOrientation);

#endif /* GLOBALS_H */
