#import "Tweak.h"

// Grupo para hooks relacionados a UI e imagens
%group UIHooks

// Hook para UIImage para interceptar a geração de miniaturas
%hook UIImage

// Este método é usado para criar miniaturas
+ (UIImage *)imageWithCGImage:(CGImageRef)cgImage scale:(CGFloat)scale orientation:(UIImageOrientation)orientation {
    // Se não estamos durante uma captura de foto, seguir normalmente
    if (!g_isCapturingPhoto || ![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Verificar se temos um buffer válido
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        if (imageBuffer) {
            // Criar uma imagem do nosso buffer MJPEG para a miniatura
            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
            if (ciImage) {
                CIContext *context = [CIContext contextWithOptions:nil];
                CGImageRef mjpegImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                
                if (mjpegImage) {
                    // SOLUÇÃO CRÍTICA: Forçar orientação correta com base em g_videoOrientation
                    UIImageOrientation forceOrientation;
                    
                    if (g_isVideoOrientationSet) {
                        switch (g_videoOrientation) {
                            case 1: // Portrait
                                forceOrientation = UIImageOrientationUp;
                                break;
                            case 2: // Portrait upside down
                                forceOrientation = UIImageOrientationDown;
                                break;
                            case 3: // Landscape right - este é o problema
                                forceOrientation = UIImageOrientationLeft;  // IMPORTANTE: Use LEFT para Landscape RIGHT
                                break;
                            case 4: // Landscape left
                                forceOrientation = UIImageOrientationRight;  // IMPORTANTE: Use RIGHT para Landscape LEFT
                                break;
                            default:
                                forceOrientation = orientation;
                                break;
                        }
                        
                        writeLog(@"[HOOK] FORÇANDO orientação %d para %d com base em videoOrientation %d",
                               (int)orientation, (int)forceOrientation, g_videoOrientation);
                        
                        // Usar a imagem MJPEG em vez da original com a orientação forçada
                        UIImage *result = %orig(mjpegImage, scale, forceOrientation);
                        CGImageRelease(mjpegImage);
                        return result;
                    } else {
                        // Se não temos orientação definida, usar a orientação original
                        writeLog(@"[HOOK] Substituindo miniatura com imagem MJPEG (orientação original: %d)", (int)orientation);
                        UIImage *result = %orig(mjpegImage, scale, orientation);
                        CGImageRelease(mjpegImage);
                        return result;
                    }
                }
            }
        }
    }
    
    return %orig;
}

// Outros métodos de criação de imagem que podemos precisar interceptar
+ (UIImage *)imageWithData:(NSData *)data {
    // Se não estamos durante uma captura de foto, seguir normalmente
    if (!g_isCapturingPhoto || ![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Verificar se o dado é de uma imagem JPEG
    if (data.length > 4) {
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        BOOL isJPEG = (bytes[0] == 0xFF && bytes[1] == 0xD8); // JPEG SOI marker
        
        if (isJPEG) {
            // Pode ser uma imagem de câmera que queremos substituir
            writeLog(@"[HOOK] Detectada possível criação de imagem JPEG durante captura de foto");
            
            // Verificar se temos um buffer válido
            CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
            if (buffer && CMSampleBufferIsValid(buffer)) {
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
                if (imageBuffer) {
                    // Criar uma imagem do nosso buffer MJPEG
                    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
                    if (ciImage) {
                        CIContext *context = [CIContext contextWithOptions:nil];
                        CGImageRef mjpegImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                        
                        if (mjpegImage) {
                            // Determinar a orientação correta baseada no estado da câmera
                            UIImageOrientation orientation = UIImageOrientationUp;
                            if (g_isVideoOrientationSet) {
                                switch (g_videoOrientation) {
                                    case 1: // Portrait
                                        orientation = UIImageOrientationUp;
                                        break;
                                    case 2: // Portrait upside down
                                        orientation = UIImageOrientationDown;
                                        break;
                                    case 3: // Landscape right
                                        orientation = UIImageOrientationLeft; // Corrigido
                                        break;
                                    case 4: // Landscape left
                                        orientation = UIImageOrientationRight; // Corrigido
                                        break;
                                }
                            }
                            
                            // Criar UIImage a partir da nossa imagem com orientação correta
                            UIImage *result = [UIImage imageWithCGImage:mjpegImage scale:1.0 orientation:orientation];
                            CGImageRelease(mjpegImage);
                            
                            if (result) {
                                writeLog(@"[HOOK] Substituindo imageWithData com imagem MJPEG (orientação: %d)", (int)orientation);
                                return result;
                            }
                        }
                    }
                }
            }
        }
    }
    
    return %orig;
}

%end

// Hook para UIImageView para garantir que as miniaturas sejam exibidas corretamente
%hook UIImageView

- (void)setImage:(UIImage *)image {
    // Se não estamos durante uma captura de foto, seguir normalmente
    if (!g_isCapturingPhoto || ![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    // Verificar algumas propriedades da view para identificar se é uma miniatura de câmera
    BOOL mightBeThumbnail = NO;

    // Verificar nomes de classes de ancestrais que podem indicar miniaturas de câmera
    UIView *view = self;
    while (view && !mightBeThumbnail) {
        NSString *className = NSStringFromClass([view class]);
        
        if ([className containsString:@"Thumbnail"] ||
            [className containsString:@"Preview"] ||
            [className containsString:@"Camera"]) {
            mightBeThumbnail = YES;
            break;
        }
        
        view = view.superview;
    }

    // Se parece ser uma miniatura e estamos capturando, tentar substituir
    if (mightBeThumbnail) {
        writeLog(@"[HOOK] Detectada possível imageView de miniatura: %@", NSStringFromClass([self class]));
        
        // Verificar se temos um buffer válido
        CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
        if (buffer && CMSampleBufferIsValid(buffer)) {
            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
            if (imageBuffer) {
                // Criar uma imagem do nosso buffer MJPEG
                CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
                if (ciImage) {
                    CIContext *context = [CIContext contextWithOptions:nil];
                    CGImageRef mjpegImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                    
                    if (mjpegImage) {
                        // CORREÇÃO: Mapear corretamente a orientação com base na orientação do dispositivo
                        UIImageOrientation orientation = UIImageOrientationUp;
                        
                        // Verificar se temos uma orientação definida
                        if (g_isVideoOrientationSet) {
                            // Mapear corretamente orientação do vídeo para UIImageOrientation
                            switch (g_videoOrientation) {
                                case 1: // Portrait
                                    orientation = UIImageOrientationUp;
                                    break;
                                case 2: // Portrait upside down
                                    orientation = UIImageOrientationDown;
                                    break;
                                case 3: // Landscape right
                                    // CORREÇÃO: Usar Left em vez de Right
                                    orientation = UIImageOrientationLeft;
                                    break;
                                case 4: // Landscape left
                                    // CORREÇÃO: Usar Right em vez de Left
                                    orientation = UIImageOrientationRight;
                                    break;
                                default:
                                    orientation = UIImageOrientationUp;
                                    break;
                            }
                        } else if (image) {
                            // Se não temos orientação definida mas temos imagem original, usar sua orientação
                            orientation = image.imageOrientation;
                        }
                        
                        writeLog(@"[HOOK] Aplicando orientação %d para thumbnail baseado na orientação de vídeo %d",
                                (int)orientation, g_videoOrientation);
                        
                        // Criar UIImage com orientação correta
                        UIImage *mjpegUIImage = [UIImage imageWithCGImage:mjpegImage scale:1.0 orientation:orientation];
                        CGImageRelease(mjpegImage);
                        
                        if (mjpegUIImage) {
                            writeLog(@"[HOOK] Substituindo imagem em UIImageView com frame MJPEG (orientação: %d)",
                                    (int)orientation);
                            %orig(mjpegUIImage);
                            return;
                        }
                    }
                }
            }
        }
    }
    
    // Se não conseguimos substituir, usar a imagem original
    %orig;
}

%end

%end // grupo UIHooks

// Constructor específico deste arquivo
%ctor {
    %init(UIHooks);
}
