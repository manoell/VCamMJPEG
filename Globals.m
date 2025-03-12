#import "Globals.h"
#import "logger.h"

// Implementação da função de mapeamento de orientação
UIImageOrientation getOrientationFromVideoOrientation(int videoOrientation) {
    switch (videoOrientation) {
        case 1: return UIImageOrientationUp;    // Portrait
        case 2: return UIImageOrientationDown;  // Portrait upside down
        case 3: return UIImageOrientationLeft;  // Landscape Right -> Left (invertido na lógica UIImage)
        case 4: return UIImageOrientationRight; // Landscape Left -> Right (invertido na lógica UIImage)
        default: return UIImageOrientationUp;   // Default to portrait
    }
}

// Implementação da função de log de delegados
void logDelegates(void) {
    writeLog(@"[HOOK] Buscando delegados de câmera ativos...");
    
    NSArray *activeDelegateClasses = @[
        @"CAMCaptureEngine",
        @"PLCameraController",
        @"PLCaptureSession",
        @"SCCapture",
        @"TGCameraController",
        @"AVCaptureSession"
    ];
    
    for (NSString *className in activeDelegateClasses) {
        Class delegateClass = NSClassFromString(className);
        if (delegateClass) {
            writeLog(@"[HOOK] Encontrado delegado potencial: %@", className);
        }
    }
}

// Implementação da função para detectar dimensões da câmera
void detectCameraResolutions(void) {
    // Configurar resoluções da câmera baseadas no diagnóstico
    g_originalFrontCameraResolution = CGSizeMake(1334, 750); // Baseado no diagnóstico
    g_originalBackCameraResolution = CGSizeMake(4032, 3024); // Baseado no diagnóstico
    
    // A detecção real ocorre via hooks em AVCaptureDevice em CameraHooks.xm
    writeLog(@"[INIT] Configurando resoluções de câmera: Front %@, Back %@",
             NSStringFromCGSize(g_originalFrontCameraResolution),
             NSStringFromCGSize(g_originalBackCameraResolution));
}
