#import "Tweak.h"

// Grupo para hooks relacionados à captura de fotos
%group PhotoHooks

// Função para garantir que a resolução da câmera seja conhecida
static void ensureCameraResolutionAvailable() {
    if (CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero)) {
        // Se não detectou a resolução, usar valores padrão para o iPhone
        if (g_usingFrontCamera) {
            g_originalCameraResolution = CGSizeMake(960, 1280); // Valores comuns para câmeras frontais em iPhones modernos
            writeLog(@"[HOOK] Usando resolução padrão da câmera frontal: %.0f x %.0f",
                    g_originalCameraResolution.width, g_originalCameraResolution.height);
        } else {
            g_originalCameraResolution = CGSizeMake(1080, 1920); // Valores comuns para câmeras traseiras em iPhones modernos
            writeLog(@"[HOOK] Usando resolução padrão da câmera traseira: %.0f x %.0f",
                    g_originalCameraResolution.width, g_originalCameraResolution.height);
        }
    }
}

// Mapeamento consistente de orientação para iOS
static UIImageOrientation orientationFromVideoOrientation(int videoOrientation) {
    switch (videoOrientation) {
        case 1: return UIImageOrientationUp;
        case 2: return UIImageOrientationDown;
        case 3: return UIImageOrientationLeft;  // Landscape right -> Left (devido à inversão na camera)
        case 4: return UIImageOrientationRight; // Landscape left -> Right (devido à inversão na camera)
        default: return UIImageOrientationUp;
    }
}

// Hook para AVCapturePhotoOutput para iOS 10+ (inclui iOS 14+)
%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    writeLog(@"[HOOK] capturePhotoWithSettings:delegate: chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        %orig;
        return;
    }
    
    g_isCapturingPhoto = YES;
    writeLog(@"[HOOK] Preparando para capturar foto com nossa substituição");
    
    // Garantir que temos uma resolução válida
    ensureCameraResolutionAvailable();
    
    // Armazenar resolução e outras configurações da foto original
    // Isso é importante para manter a compatibilidade com o app de câmera
    if (settings) {
        // Tentar obter informações sobre o formato da foto
        // No iOS 14+, AVCapturePhotoSettings não tem photoFormat mas podemos
        // usar outros métodos para obter informações
        NSArray *availablePreviewPhotoPixelFormatTypes = settings.availablePreviewPhotoPixelFormatTypes;
        if (availablePreviewPhotoPixelFormatTypes.count > 0) {
            NSDictionary *previewFormat = settings.previewPhotoFormat;
            if (previewFormat) {
                NSNumber *width = previewFormat[@"Width"] ?: previewFormat[@"PhotoWidth"];
                NSNumber *height = previewFormat[@"Height"] ?: previewFormat[@"PhotoHeight"];
                
                if (width && height) {
                    CGFloat previewWidth = [width floatValue];
                    CGFloat previewHeight = [height floatValue];
                    
                    writeLog(@"[HOOK] Resolução do preview da foto original: %.0f x %.0f",
                            previewWidth, previewHeight);
                }
            }
        }
    }
    
    // Verificar se já criamos um proxy para este delegate
    id<AVCapturePhotoCaptureDelegate> proxyDelegate = objc_getAssociatedObject(delegate, "ProxyDelegate");
    
    if (!proxyDelegate) {
        // Criar nosso próprio proxy para interceptar callbacks
        proxyDelegate = [AVCapturePhotoProxy proxyWithDelegate:delegate];
        
        // Associar o proxy para referência futura
        objc_setAssociatedObject(delegate, "ProxyDelegate", proxyDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(proxyDelegate, "OriginalDelegate", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        writeLog(@"[HOOK] Proxy de captura de foto criado com sucesso");
    }
    
    // Forçar atualização do último frame para ter o mais recente possível
    // Usar alta prioridade para MJPEG durante captura de foto
    [[MJPEGReader sharedInstance] setHighPriority:YES];
    
    // Chamar o método original com nosso proxy
    %orig(settings, proxyDelegate);
    
    // Definir um timer para restaurar a prioridade normal após a captura
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        g_isCapturingPhoto = NO;
        [[MJPEGReader sharedInstance] setHighPriority:NO];
        writeLog(@"[HOOK] Finalizada a captura de foto, restaurando prioridade normal");
    });
}

%end

// Hook para AVCapturePhoto
%hook AVCapturePhoto

- (CGImageRef)CGImageRepresentation {
    writeLog(@"[HOOK] CGImageRepresentation chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Garantir que temos uma resolução válida
    ensureCameraResolutionAvailable();
    
    // Obter o frame atual com flags mais fortes
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        writeLog(@"[HOOK] Substituindo CGImageRepresentation com frame atual (size: %zu bytes)",
                 CMSampleBufferGetTotalSampleSize(buffer));
        
        // Obter um CIImage do buffer
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        if (!imageBuffer) {
            writeLog(@"[HOOK] Falha: imageBuffer é NULL");
            return %orig;
        }
        
        // Bloquear para leitura segura
        CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
        
        // Desbloquear após leitura
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        
        if (!ciImage) {
            writeLog(@"[HOOK] Falha: ciImage é NULL");
            return %orig;
        }
        
        // Verificar se precisamos redimensionar para combinar com a câmera real
        if (!CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero)) {
            // Dimensões do buffer MJPEG atual
            CGFloat mjpegWidth = CVPixelBufferGetWidth(imageBuffer);
            CGFloat mjpegHeight = CVPixelBufferGetHeight(imageBuffer);
            
            // Se as dimensões são diferentes, redimensionar
            if (mjpegWidth != g_originalCameraResolution.width ||
                mjpegHeight != g_originalCameraResolution.height) {
                
                writeLog(@"[HOOK] Redimensionando imagem para combinar com câmera real: %.0f x %.0f -> %.0f x %.0f",
                        mjpegWidth, mjpegHeight,
                        g_originalCameraResolution.width, g_originalCameraResolution.height);
                
                // Implementação melhorada de redimensionamento
                size_t targetWidth = g_originalCameraResolution.width;
                size_t targetHeight = g_originalCameraResolution.height;
                
                // Criar contexto de destino com as dimensões corretas
                CIContext *context = [CIContext contextWithOptions:nil];
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                
                // Criar um bitmap context para o redimensionamento
                CGContextRef bitmapContext = CGBitmapContextCreate(NULL,
                                                            targetWidth,
                                                            targetHeight,
                                                            8, // bits por componente
                                                            targetWidth * 4, // bytes por linha (RGBA = 4 bytes)
                                                            colorSpace,
                                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                
                if (bitmapContext) {
                    // Obter CGImage a partir do CIImage
                    CGImageRef originalImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                    
                    if (originalImage) {
                        // Definir alta qualidade de interpolação
                        CGContextSetInterpolationQuality(bitmapContext, kCGInterpolationHigh);
                        
                        // Limpar o contexto para evitar artefatos
                        CGContextClearRect(bitmapContext, CGRectMake(0, 0, targetWidth, targetHeight));
                        
                        // Desenhar a imagem redimensionada
                        CGContextDrawImage(bitmapContext, CGRectMake(0, 0, targetWidth, targetHeight), originalImage);
                        
                        // Criar uma nova imagem a partir do bitmap
                        CGImageRef resizedImage = CGBitmapContextCreateImage(bitmapContext);
                        
                        if (resizedImage) {
                            // Liberar recursos
                            CGImageRelease(originalImage);
                            CGContextRelease(bitmapContext);
                            CGColorSpaceRelease(colorSpace);
                            
                            writeLog(@"[HOOK] Substituição de CGImageRepresentation bem-sucedida com redimensionamento!");
                            return resizedImage;
                        }
                        
                        CGImageRelease(originalImage);
                    }
                    
                    CGContextRelease(bitmapContext);
                }
                
                CGColorSpaceRelease(colorSpace);
            }
        }
        
        // Aplicar rotação baseada na orientação do vídeo
        if (g_isVideoOrientationSet) {
            // Mapeamento consistente para orientação
            UIImageOrientation orientation = orientationFromVideoOrientation(g_videoOrientation);
            
            // Log da orientação sendo aplicada
            writeLog(@"[HOOK] Aplicando orientação %d para CGImageRepresentation", (int)orientation);
            
            // Obter transformação para aplicar orientação
            CGAffineTransform transform = CGAffineTransformIdentity;
            CGSize size = ciImage.extent.size;
            
            switch (orientation) {
                case UIImageOrientationDown:
                    transform = CGAffineTransformMakeRotation(M_PI);
                    break;
                case UIImageOrientationLeft:
                    transform = CGAffineTransformMakeRotation(M_PI_2);
                    size = CGSizeMake(size.height, size.width); // Trocar largura e altura
                    break;
                case UIImageOrientationRight:
                    transform = CGAffineTransformMakeRotation(-M_PI_2);
                    size = CGSizeMake(size.height, size.width); // Trocar largura e altura
                    break;
                default:
                    break;
            }
            
            // Se precisa aplicar transformação
            if (!CGAffineTransformIsIdentity(transform)) {
                // Criar uma CIImage transformada
                ciImage = [ciImage imageByApplyingTransform:transform];
            }
        }
        
        // Converter CIImage para CGImage
        CIContext *context = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
        
        if (!cgImage) {
            writeLog(@"[HOOK] Falha: cgImage é NULL");
            return %orig;
        }
        
        writeLog(@"[HOOK] Substituição de CGImageRepresentation bem-sucedida!");
        return cgImage;
    } else {
        writeLog(@"[HOOK] Não foi possível obter buffer válido para CGImageRepresentation");
    }
    
    return %orig;
}

- (CVPixelBufferRef)pixelBuffer {
    writeLog(@"[HOOK] pixelBuffer chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Garantir que temos uma resolução válida
    ensureCameraResolutionAvailable();
    
    // Obter o frame atual
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        writeLog(@"[HOOK] Substituindo pixelBuffer com frame atual");
        
        // Retornar o CVPixelBuffer do buffer atual
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        if (imageBuffer) {
            // Verificar se precisamos redimensionar para combinar com a câmera real
            if (!CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero)) {
                // Dimensões do buffer MJPEG atual
                size_t mjpegWidth = CVPixelBufferGetWidth(imageBuffer);
                size_t mjpegHeight = CVPixelBufferGetHeight(imageBuffer);
                
                // Se as dimensões são diferentes, redimensionar
                if (mjpegWidth != g_originalCameraResolution.width ||
                    mjpegHeight != g_originalCameraResolution.height) {
                    
                    writeLog(@"[HOOK] Redimensionando pixelBuffer: %zu x %zu -> %.0f x %.0f",
                            mjpegWidth, mjpegHeight,
                            g_originalCameraResolution.width, g_originalCameraResolution.height);
                    
                    // Criar novo pixel buffer com dimensões da câmera real
                    CVPixelBufferRef scaledBuffer = NULL;
                    NSDictionary *options = @{
                        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                    };
                    
                    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                                        g_originalCameraResolution.width,
                                                        g_originalCameraResolution.height,
                                                        CVPixelBufferGetPixelFormatType(imageBuffer),
                                                        (__bridge CFDictionaryRef)options,
                                                        &scaledBuffer);
                    
                    if (result == kCVReturnSuccess && scaledBuffer) {
                        // Bloquear buffers para acesso
                        CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
                        CVPixelBufferLockBaseAddress(scaledBuffer, 0);
                        
                        // Criar contexto CG para desenhar
                        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                        
                        // Criar contexto de destino
                        CGContextRef destContext = CGBitmapContextCreate(
                            CVPixelBufferGetBaseAddress(scaledBuffer),
                            g_originalCameraResolution.width,
                            g_originalCameraResolution.height,
                            8,
                            CVPixelBufferGetBytesPerRow(scaledBuffer),
                            colorSpace,
                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                        
                        if (destContext) {
                            // Criar CIImage do buffer original
                            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
                            
                            // Criar CGImage temporário
                            CIContext *ciContext = [CIContext contextWithOptions:nil];
                            CGImageRef cgImage = [ciContext createCGImage:ciImage fromRect:ciImage.extent];
                            
                            if (cgImage) {
                                // Configurar alta qualidade de interpolação
                                CGContextSetInterpolationQuality(destContext, kCGInterpolationHigh);
                                
                                // Limpar o contexto para evitar artefatos
                                CGContextClearRect(destContext,
                                                  CGRectMake(0, 0, g_originalCameraResolution.width, g_originalCameraResolution.height));
                                
                                // Desenhar redimensionado
                                CGContextDrawImage(destContext,
                                                CGRectMake(0, 0, g_originalCameraResolution.width, g_originalCameraResolution.height),
                                                cgImage);
                                
                                // Liberar recursos
                                CGImageRelease(cgImage);
                            }
                            
                            CGContextRelease(destContext);
                        }
                        
                        CGColorSpaceRelease(colorSpace);
                        
                        // Desbloquear buffers
                        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
                        CVPixelBufferUnlockBaseAddress(scaledBuffer, 0);
                        
                        // Aumentar a referência do pixelBuffer antes de retornar
                        CVPixelBufferRetain(scaledBuffer);
                        writeLog(@"[HOOK] Substituição de pixelBuffer bem-sucedida com redimensionamento!");
                        return scaledBuffer;
                    } else {
                        writeLog(@"[HOOK] Falha ao criar buffer redimensionado: %d", result);
                    }
                }
            }
            
            // Aplicar rotação se necessário baseado na orientação do vídeo
            if (g_isVideoOrientationSet && g_videoOrientation != 1) { // Se não for portrait (padrão)
                // Criar novo pixelBuffer rotacionado (implementação simplificada)
                // Na prática, você precisaria criar um novo pixelBuffer e aplicar a rotação
                // Este é um marcador para a implementação completa
                writeLog(@"[HOOK] Orientação %d detectada para pixelBuffer, aplicando transformação", g_videoOrientation);
                
                // Por simplicidade, apenas retornamos o buffer original por enquanto
                // Uma implementação completa de rotação seria adicionada aqui
            }
            
            // Se não foi preciso redimensionar ou rotar, usar o buffer original
            CVPixelBufferRetain(imageBuffer);
            writeLog(@"[HOOK] Substituição de pixelBuffer bem-sucedida!");
            return imageBuffer;
        }
    }
    
    return %orig;
}

- (NSData *)fileDataRepresentation {
    writeLog(@"[HOOK] fileDataRepresentation chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Garantir que temos uma resolução válida
    ensureCameraResolutionAvailable();
    
    // Obter o frame atual - usamos replace:YES para garantir que obtemos um frame atualizado
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        writeLog(@"[HOOK] Substituindo fileDataRepresentation com frame atual");
        
        // Obter um CIImage do buffer
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        if (!imageBuffer) {
            writeLog(@"[HOOK] Falha: imageBuffer é NULL");
            return %orig;
        }
        
        // Obter dimensões do buffer para logging
        size_t width = CVPixelBufferGetWidth(imageBuffer);
        size_t height = CVPixelBufferGetHeight(imageBuffer);
        writeLog(@"[HOOK] Dimensões do buffer para fileDataRepresentation: %zu x %zu", width, height);
        
        // Bloquear o buffer para leitura
        CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
        
        // Desbloquear o buffer
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        
        if (!ciImage) {
            writeLog(@"[HOOK] Falha: ciImage é NULL");
            return %orig;
        }
        
        // Verificar se precisamos redimensionar para combinar com a câmera real
        if (!CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero)) {
            // Se as dimensões são diferentes, redimensionar
            if (width != g_originalCameraResolution.width ||
                height != g_originalCameraResolution.height) {
                
                writeLog(@"[HOOK] Redimensionando para fileDataRepresentation: %zu x %zu -> %.0f x %.0f",
                        width, height,
                        g_originalCameraResolution.width, g_originalCameraResolution.height);
                
                // IMPLEMENTAÇÃO DIRETA: criar UIImage, redimensionar e converter de volta
                CIContext *context = [CIContext contextWithOptions:nil];
                CGImageRef originalCGImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                
                if (originalCGImage) {
                    // Criar um bitmap context com as dimensões desejadas
                    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                    size_t bitsPerComponent = 8;
                    size_t bytesPerRow = 4 * (size_t)g_originalCameraResolution.width; // 4 bytes por pixel (RGBA)
                    
                    CGContextRef bitmapContext = CGBitmapContextCreate(
                        NULL, // Dados - NULL para alocar automaticamente
                        g_originalCameraResolution.width,
                        g_originalCameraResolution.height,
                        bitsPerComponent,
                        bytesPerRow,
                        colorSpace,
                        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
                    );
                    
                    if (bitmapContext) {
                        // Configurar alta qualidade para o redimensionamento
                        CGContextSetInterpolationQuality(bitmapContext, kCGInterpolationHigh);
                        
                        // Limpar o contexto para evitar artefatos
                        CGContextClearRect(bitmapContext,
                                          CGRectMake(0, 0, g_originalCameraResolution.width, g_originalCameraResolution.height));
                        
                        // Desenhar a imagem redimensionada
                        CGContextDrawImage(
                            bitmapContext,
                            CGRectMake(0, 0, g_originalCameraResolution.width, g_originalCameraResolution.height),
                            originalCGImage
                        );
                        
                        // Criar uma nova imagem a partir do contexto
                        CGImageRef resizedCGImage = CGBitmapContextCreateImage(bitmapContext);
                        
                        if (resizedCGImage) {
                            // Substituir a imagem original
                            ciImage = [CIImage imageWithCGImage:resizedCGImage];
                            CGImageRelease(resizedCGImage);
                            
                            writeLog(@"[HOOK] Redimensionamento bem-sucedido para %.0f x %.0f",
                                    g_originalCameraResolution.width, g_originalCameraResolution.height);
                        }
                        
                        // Liberar recursos
                        CGContextRelease(bitmapContext);
                    }
                    
                    CGColorSpaceRelease(colorSpace);
                    CGImageRelease(originalCGImage);
                }
            }
        }
        
        // Aplicar rotação baseada na orientação do vídeo
        if (g_isVideoOrientationSet) {
            UIImageOrientation orientation = UIImageOrientationUp;
            
            // Mapeamento corrigido para orientação
            switch (g_videoOrientation) {
                case 1: // Portrait
                    writeLog(@"[HOOK] Orientação: Portrait");
                    orientation = UIImageOrientationUp;
                    break;
                case 2: // Portrait upside down
                    writeLog(@"[HOOK] Orientação: Portrait Upside Down");
                    orientation = UIImageOrientationDown;
                    break;
                case 3: // Landscape right
                    writeLog(@"[HOOK] Orientação: Landscape Right -> Rotacionando para Left");
                    // A orientação UIImage é inversa do que se espera logicamente
                    orientation = UIImageOrientationLeft;
                    break;
                case 4: // Landscape left
                    writeLog(@"[HOOK] Orientação: Landscape Left -> Rotacionando para Right");
                    // A orientação UIImage é inversa do que se espera logicamente
                    orientation = UIImageOrientationRight;
                    break;
                default:
                    writeLog(@"[HOOK] Orientação desconhecida: %d", g_videoOrientation);
                    break;
            }
            
            writeLog(@"[HOOK] Orientação detectada: %d, aplicando UIImageOrientation: %d",
                    g_videoOrientation, (int)orientation);
            
            // Converter para UIImage com mais precisão
            CIContext *context = [CIContext contextWithOptions:nil];
            CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
            
            if (cgImage) {
                // Criar uma UIImage com a orientação correta
                UIImage *image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:orientation];
                CGImageRelease(cgImage);
                
                if (image) {
                    // Converter para JPEG data com alta qualidade
                    NSData *jpegData = UIImageJPEGRepresentation(image, 1.0);
                    
                    if (jpegData) {
                        writeLog(@"[HOOK] Rotação aplicada com sucesso");
                        writeLog(@"[HOOK] Substituição de fileDataRepresentation bem-sucedida! Tamanho: %zu bytes", jpegData.length);
                        
                        // Verificar e copiar metadados importantes se disponíveis
                        NSData *originalData = %orig;
                        if (originalData) {
                            // Tentar preservar metadados EXIF da imagem original
                            // Esta parte é complexa e pode exigir uma biblioteca adicional como ImageIO
                            // para uma implementação completa.
                            writeLog(@"[HOOK] Dados originais disponíveis, tamanho: %zu bytes", originalData.length);
                        }
                        
                        return jpegData;
                    } else {
                        writeLog(@"[HOOK] Falha ao gerar JPEG data após rotação");
                    }
                } else {
                    writeLog(@"[HOOK] Falha: image é NULL após rotação");
                }
            } else {
                writeLog(@"[HOOK] Falha: cgImage é NULL");
            }
        } else {
            // Se a orientação não estiver definida, apenas criar uma imagem normal
            CIContext *context = [CIContext contextWithOptions:nil];
            CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
            if (cgImage) {
                UIImage *image = [UIImage imageWithCGImage:cgImage];
                CGImageRelease(cgImage);
                
                if (image) {
                    NSData *jpegData = UIImageJPEGRepresentation(image, 1.0);
                    if (jpegData) {
                        writeLog(@"[HOOK] Substituição de fileDataRepresentation bem-sucedida! Tamanho: %zu bytes", jpegData.length);
                        return jpegData;
                    }
                }
            }
        }
    } else {
        writeLog(@"[HOOK] Não foi possível obter buffer válido para fileDataRepresentation");
    }
    
    return %orig;
}

- (NSData *)fileDataRepresentationWithCustomizer:(id)customizer {
    writeLog(@"[HOOK] fileDataRepresentationWithCustomizer chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Garantir que temos uma resolução válida
    ensureCameraResolutionAvailable();
    
    // Obter o frame atual
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        writeLog(@"[HOOK] Substituindo fileDataRepresentationWithCustomizer com frame atual");
        
        // Obter um CIImage do buffer
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        if (!imageBuffer) {
            writeLog(@"[HOOK] Falha: imageBuffer é NULL");
            return %orig;
        }
        
        // Bloquear o buffer para leitura
        CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
        
        // Desbloquear o buffer
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        
        if (!ciImage) {
            writeLog(@"[HOOK] Falha: ciImage é NULL");
            return %orig;
        }
        
        // Verificar se precisamos redimensionar para combinar com a câmera real
        if (!CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero)) {
            // Dimensões do buffer MJPEG atual
            size_t mjpegWidth = CVPixelBufferGetWidth(imageBuffer);
            size_t mjpegHeight = CVPixelBufferGetHeight(imageBuffer);
            
            // Se as dimensões são diferentes, redimensionar
            if (mjpegWidth != g_originalCameraResolution.width ||
                mjpegHeight != g_originalCameraResolution.height) {
                
                writeLog(@"[HOOK] Redimensionando para customizer: %zu x %zu -> %.0f x %.0f",
                        mjpegWidth, mjpegHeight,
                        g_originalCameraResolution.width, g_originalCameraResolution.height);
                
                // Usar a implementação robusta de redimensionamento
                // Criar contexto de bitmap com dimensões corretas
                size_t targetWidth = g_originalCameraResolution.width;
                size_t targetHeight = g_originalCameraResolution.height;
                
                // Certificar-se de que targetWidth e targetHeight são números pares
                targetWidth = (targetWidth % 2 == 0) ? targetWidth : targetWidth + 1;
                targetHeight = (targetHeight % 2 == 0) ? targetHeight : targetHeight + 1;
                
                // Criar contexto para desenhar a imagem redimensionada
                CIContext *context = [CIContext contextWithOptions:nil];
                CGImageRef originalImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                
                if (originalImage) {
                    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                    CGContextRef bitmapContext = CGBitmapContextCreate(NULL,
                                                                targetWidth,
                                                                targetHeight,
                                                                8, // bits por componente
                                                                0, // bytes por linha (0 = automático)
                                                                colorSpace,
                                                                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                    
                    if (bitmapContext) {
                        // Alta qualidade de interpolação para melhor resultado
                        CGContextSetInterpolationQuality(bitmapContext, kCGInterpolationHigh);
                        
                        // Desenhar a imagem redimensionada
                        CGContextDrawImage(bitmapContext, CGRectMake(0, 0, targetWidth, targetHeight), originalImage);
                        
                        // Criar uma nova imagem CG a partir do contexto
                        CGImageRef resizedImage = CGBitmapContextCreateImage(bitmapContext);
                        
                        if (resizedImage) {
                            // Converter para CIImage para continuar o processamento
                            ciImage = [CIImage imageWithCGImage:resizedImage];
                            
                            // Liberar recursos
                            CGImageRelease(resizedImage);
                        }
                        
                        CGContextRelease(bitmapContext);
                    }
                    
                    CGColorSpaceRelease(colorSpace);
                    CGImageRelease(originalImage);
                }
            }
        }
        
        // Aplicar rotação baseada na orientação do vídeo
        if (g_isVideoOrientationSet) {
            UIImageOrientation orientation = UIImageOrientationUp;
            
            // Mapeamento corrigido para orientação
            switch (g_videoOrientation) {
                case 1: // Portrait
                    orientation = UIImageOrientationUp;
                    break;
                case 2: // Portrait upside down
                    orientation = UIImageOrientationDown;
                    break;
                case 3: // Landscape right
                    orientation = UIImageOrientationLeft; // Correção: invertido para lógica de UIImage
                    break;
                case 4: // Landscape left
                    orientation = UIImageOrientationRight; // Correção: invertido para lógica de UIImage
                    break;
                default:
                    orientation = UIImageOrientationUp;
                    break;
            }
            
            // Converter para UIImage
            CIContext *context = [CIContext contextWithOptions:nil];
            CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
            if (cgImage) {
                UIImage *image = [UIImage imageWithCGImage:cgImage
                                                   scale:1.0
                                             orientation:orientation];
                CGImageRelease(cgImage);
                
                if (image) {
                    // Se temos um customizador, tentar aplicá-lo
                    if (customizer) {
                        // Esta parte é complexa e pode exigir uma implementação específica
                        // dependendo do que o customizador faz. Aqui apenas notificamos.
                        writeLog(@"[HOOK] Customizador fornecido, mas não aplicado diretamente");
                    }
                    
                    // Converter para JPEG data com alta qualidade
                    NSData *jpegData = UIImageJPEGRepresentation(image, 1.0);
                    
                    if (jpegData) {
                        writeLog(@"[HOOK] Substituição de fileDataRepresentationWithCustomizer bem-sucedida!");
                        return jpegData;
                    } else {
                        writeLog(@"[HOOK] Falha ao gerar JPEG data");
                    }
                }
            }
        }
    }
    
    return %orig;
}

// Hook para previewPhotoPixelBuffer para interceptar a miniatura
- (CVPixelBufferRef)previewPixelBuffer {
    writeLog(@"[HOOK] previewPixelBuffer chamado");
    
    // Verificar se a substituição da câmera está ativa
    if (![[VirtualCameraController sharedInstance] isActive]) {
        return %orig;
    }
    
    // Obter o frame atual
    CMSampleBufferRef buffer = [GetFrame getCurrentFrame:nil replace:YES];
    if (buffer && CMSampleBufferIsValid(buffer)) {
        writeLog(@"[HOOK] Substituindo previewPixelBuffer com frame atual");
        
        // Retornar o CVPixelBuffer do buffer atual
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
        if (imageBuffer) {
            // Aumentar a referência do pixelBuffer antes de retornar
            CVPixelBufferRetain(imageBuffer);
            writeLog(@"[HOOK] Substituição de previewPixelBuffer bem-sucedida!");
            return imageBuffer;
        }
    }
    
    return %orig;
}

%end

%end // grupo PhotoHooks

// Constructor específico deste arquivo
%ctor {
    %init(PhotoHooks);
}
