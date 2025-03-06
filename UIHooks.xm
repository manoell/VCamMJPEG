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
                    // Usar a imagem MJPEG em vez da original
                    writeLog(@"[HOOK] Substituindo miniatura com imagem MJPEG");
                    UIImage *result = %orig(mjpegImage, scale, orientation);
                    CGImageRelease(mjpegImage);
                    return result;
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
                            // Criar UIImage a partir da nossa imagem
                            UIImage *result = [UIImage imageWithCGImage:mjpegImage];
                            CGImageRelease(mjpegImage);
                            
                            if (result) {
                                writeLog(@"[HOOK] Substituindo imageWithData com imagem MJPEG");
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
                        // Pegar orientação da imagem original se disponível
                        UIImageOrientation orientation = UIImageOrientationUp;
                        if (image) {
                            orientation = image.imageOrientation;
                        }
                        
                        // Criar UIImage com orientação correta
                        UIImage *mjpegUIImage = [UIImage imageWithCGImage:mjpegImage scale:1.0 orientation:orientation];
                        CGImageRelease(mjpegImage);
                        
                        if (mjpegUIImage) {
                            writeLog(@"[HOOK] Substituindo imagem em UIImageView com frame MJPEG");
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
