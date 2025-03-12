#import "Tweak.h"

// Grupo para hooks relacionados a UI e imagens
%group UIHooks

// Mapeamento consistente da orientação de vídeo para UIImageOrientation
static UIImageOrientation getOrientationFromVideoOrientation(int videoOrientation) {
    switch (videoOrientation) {
        case 1: return UIImageOrientationUp;    // Portrait
        case 2: return UIImageOrientationDown;  // Portrait upside down
        case 3: return UIImageOrientationLeft;  // Landscape Right -> Left (invertido na lógica UIImage)
        case 4: return UIImageOrientationRight; // Landscape Left -> Right (invertido na lógica UIImage)
        default: return UIImageOrientationUp;   // Default to portrait
    }
}

// Hook para UIImage para interceptar a geração de miniaturas
%hook UIImage

// Este método é usado para criar miniaturas
+ (UIImage *)imageWithCGImage:(CGImageRef)cgImage scale:(CGFloat)scale orientation:(UIImageOrientation)orientation {
    // Se não estamos durante uma captura de foto, seguir normalmente
    if (!g_isCapturingPhoto || ![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    static int replacementCount = 0;
    if (++replacementCount % 100 == 0) {
        writeLog(@"[HOOK] imageWithCGImage:scale:orientation: chamado #%d", replacementCount);
    }
    
    // Verificar se temos um buffer válido
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        if (imageBuffer) {
            // Bloquear para acesso seguro
            CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
            
            // Criar uma imagem do nosso buffer MJPEG para a miniatura
            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
            
            // Desbloquear após uso
            CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
            
            if (ciImage) {
                CIContext *context = [CIContext contextWithOptions:nil];
                CGImageRef mjpegImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                
                if (mjpegImage) {
                    // SOLUÇÃO CRÍTICA: Forçar orientação correta com base em g_videoOrientation
                    UIImageOrientation forceOrientation = orientation;
                    
                    if (g_isVideoOrientationSet) {
                        forceOrientation = getOrientationFromVideoOrientation(g_videoOrientation);
                        
                        writeLog(@"[HOOK] FORÇANDO orientação %d para %d com base em videoOrientation %d",
                               (int)orientation, (int)forceOrientation, g_videoOrientation);
                    }
                    
                    // Usar a imagem MJPEG em vez da original com a orientação forçada
                    UIImage *result = %orig(mjpegImage, scale, forceOrientation);
                    CGImageRelease(mjpegImage);
                    
                    if (replacementCount % 100 == 0) {
                        // Log limitado para não afetar performance
                        writeLog(@"[HOOK] Substituindo imagem para miniatura (orientação: %d, escala: %.1f)",
                               (int)forceOrientation, scale);
                    }
                    
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
                    // Bloquear buffer
                    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
                    
                    // Criar uma imagem do nosso buffer MJPEG
                    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
                    
                    // Desbloquear buffer
                    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
                    
                    if (ciImage) {
                        CIContext *context = [CIContext contextWithOptions:nil];
                        CGImageRef mjpegImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                        
                        if (mjpegImage) {
                            // Determinar a orientação correta baseada no estado da câmera
                            UIImageOrientation orientation = UIImageOrientationUp;
                            if (g_isVideoOrientationSet) {
                                orientation = getOrientationFromVideoOrientation(g_videoOrientation);
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

// Método para atualizar a posição e dimensões da imagem conforme necessário
- (void)setFrame:(CGRect)frame {
    %orig;
    
    // Se não estamos capturando foto ou a substituição não está ativa, seguir normalmente
    if (!g_isCapturingPhoto || ![[VirtualCameraController sharedInstance] isActive]) {
        return;
    }
    
    // Verificar proporção da imagem atual se disponível
    if (self.image) {
        CGSize imageSize = self.image.size;
        CGFloat imageRatio = imageSize.width / imageSize.height;
        
        // Verificar proporção do frame
        CGFloat frameRatio = frame.size.width / frame.size.height;
        
        // Se a diferença de proporção for significativa, pode ser necessário ajustar o contentMode
        if (fabs(imageRatio - frameRatio) > 0.1) {
            // Priorizar preenchimento para evitar espaços vazios
            self.contentMode = UIViewContentModeScaleAspectFill;
            self.clipsToBounds = YES;
        }
    }
}

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
            [className containsString:@"Camera"] ||
            [className containsString:@"Photo"]) {
            mightBeThumbnail = YES;
            break;
        }
        
        view = view.superview;
    }

    // Se parece ser uma miniatura e estamos capturando, tentar substituir
    if (mightBeThumbnail) {
        static int thumbnailCount = 0;
        if (++thumbnailCount % 50 == 0) {
            writeLog(@"[HOOK] Detectada possível imageView de miniatura: %@", NSStringFromClass([self class]));
        }
        
        // Verificar se temos um buffer válido
        CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
        if (buffer && CMSampleBufferIsValid(buffer)) {
            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
            if (imageBuffer) {
                // Bloquear buffer
                CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
                
                // Criar uma imagem do nosso buffer MJPEG
                CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
                
                // Desbloquear buffer
                CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
                
                if (ciImage) {
                    CIContext *context = [CIContext contextWithOptions:nil];
                    CGImageRef mjpegImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                    
                    if (mjpegImage) {
                        // CORREÇÃO: Mapear corretamente a orientação com base na orientação do dispositivo
                        UIImageOrientation orientation = UIImageOrientationUp;
                        
                        // Verificar se temos uma orientação definida
                        if (g_isVideoOrientationSet) {
                            // Mapear corretamente orientação do vídeo para UIImageOrientation
                            orientation = getOrientationFromVideoOrientation(g_videoOrientation);
                        } else if (image) {
                            // Se não temos orientação definida mas temos imagem original, usar sua orientação
                            orientation = image.imageOrientation;
                        }
                        
                        if (thumbnailCount % 50 == 0) {
                            writeLog(@"[HOOK] Aplicando orientação %d para thumbnail baseado na orientação de vídeo %d",
                                    (int)orientation, g_videoOrientation);
                        }
                        
                        // Obter a escala da imagem original para manter consistência
                        CGFloat scale = image ? image.scale : 1.0;
                        
                        // Criar UIImage com orientação correta
                        UIImage *mjpegUIImage = [UIImage imageWithCGImage:mjpegImage scale:scale orientation:orientation];
                        CGImageRelease(mjpegImage);
                        
                        if (mjpegUIImage) {
                            if (thumbnailCount % 50 == 0) {
                                writeLog(@"[HOOK] Substituindo imagem em UIImageView com frame MJPEG (orientação: %d)",
                                        (int)orientation);
                            }
                            
                            // Configurar contentMode para apresentação ideal
                            self.contentMode = UIViewContentModeScaleAspectFill;
                            self.clipsToBounds = YES;
                            
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
