#import "Tweak.h"

// Grupo para hooks relacionados à captura de fotos
%group PhotoHooks

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
        
        // Usar a resolução da câmera para fotos se não tivermos a informação
        if (CGSizeEqualToSize(g_originalCameraResolution, CGSizeZero)) {
            // Definir uma resolução padrão para o tipo de câmera em uso
            if (g_usingFrontCamera) {
                g_originalCameraResolution = CGSizeMake(961, 1280); // Dimensões frontais informadas
            } else {
                g_originalCameraResolution = CGSizeMake(1072, 1920); // Dimensões traseiras informadas
            }
            
            writeLog(@"[HOOK] Usando resolução padrão para câmera %@: %.0f x %.0f",
                    g_usingFrontCamera ? @"frontal" : @"traseira",
                    g_originalCameraResolution.width, g_originalCameraResolution.height);
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
    [[GetFrame sharedInstance] processNewMJPEGFrame:nil];
    
    // Chamar o método original com nosso proxy
    %orig(settings, proxyDelegate);
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
        
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
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
                
                // Criar um contexto de escala para redimensionar a imagem
                CIContext *context = [CIContext contextWithOptions:nil];
                CGRect targetRect = CGRectMake(0, 0, g_originalCameraResolution.width, g_originalCameraResolution.height);
                
                // Aplicar transformação de escala
                CIImage *scaledImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(
                    g_originalCameraResolution.width / mjpegWidth,
                    g_originalCameraResolution.height / mjpegHeight)];
                
                // Criar CGImage redimensionado
                CGImageRef cgImage = [context createCGImage:scaledImage fromRect:targetRect];
                
                if (!cgImage) {
                    writeLog(@"[HOOK] Falha: cgImage redimensionado é NULL");
                    // Tentar com a imagem original
                    cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
                    if (!cgImage) {
                        return %orig;
                    }
                }
                
                writeLog(@"[HOOK] Substituição de CGImageRepresentation bem-sucedida com redimensionamento!");
                return cgImage;
            }
        }
        
        // Converter CIImage para CGImage sem redimensionamento
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
                    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                                        g_originalCameraResolution.width,
                                                        g_originalCameraResolution.height,
                                                        CVPixelBufferGetPixelFormatType(imageBuffer),
                                                        NULL, &scaledBuffer);
                    
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
            
            // Se não foi preciso redimensionar, usar o buffer original
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
                
                // Aplicar transformação de escala
                ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(
                    g_originalCameraResolution.width / width,
                    g_originalCameraResolution.height / height)];
            }
        }
        
        // Converter para UIImage com mais precisão
        CIContext *context = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
        if (!cgImage) {
            writeLog(@"[HOOK] Falha: cgImage é NULL");
            return %orig;
        }
        
        UIImage *image = [UIImage imageWithCGImage:cgImage];
        CGImageRelease(cgImage);
        
        if (!image) {
            writeLog(@"[HOOK] Falha: image é NULL");
            return %orig;
        }
        
        // Aplicar rotação baseada na orientação do vídeo
        if (g_isVideoOrientationSet) {
            UIImageOrientation orientation = UIImageOrientationUp;
            
            switch (g_videoOrientation) {
                case 1: // Portrait
                    orientation = UIImageOrientationUp;
                    break;
                case 2: // Portrait upside down
                    orientation = UIImageOrientationDown;
                    break;
                case 3: // Landscape right
                    orientation = UIImageOrientationRight;
                    break;
                case 4: // Landscape left
                    orientation = UIImageOrientationLeft;
                    break;
            }
            
            if (orientation != UIImageOrientationUp) {
                image = [UIImage imageWithCGImage:image.CGImage
                                        scale:image.scale
                                    orientation:orientation];
                writeLog(@"[HOOK] Aplicada rotação para orientação: %d", g_videoOrientation);
            }
        }
        
        // Converter para JPEG data com alta qualidade
        NSData *jpegData = UIImageJPEGRepresentation(image, 1.0);
        
        if (jpegData) {
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
            writeLog(@"[HOOK] Falha ao gerar JPEG data");
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
                
                // Aplicar transformação de escala
                ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(
                    g_originalCameraResolution.width / mjpegWidth,
                    g_originalCameraResolution.height / mjpegHeight)];
            }
        }
        
        // Converter para UIImage
        CIContext *context = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
        if (!cgImage) {
            writeLog(@"[HOOK] Falha: cgImage é NULL");
            return %orig;
        }
        
        UIImage *image = [UIImage imageWithCGImage:cgImage];
        CGImageRelease(cgImage);
        
        // Aplicar rotação baseada na orientação do vídeo
        if (g_isVideoOrientationSet && image) {
            UIImageOrientation orientation = UIImageOrientationUp;
            
            switch (g_videoOrientation) {
                case 1: // Portrait
                    orientation = UIImageOrientationUp;
                    break;
                case 2: // Portrait upside down
                    orientation = UIImageOrientationDown;
                    break;
                case 3: // Landscape right
                    orientation = UIImageOrientationRight;
                    break;
                case 4: // Landscape left
                    orientation = UIImageOrientationLeft;
                    break;
            }
            
            if (orientation != UIImageOrientationUp) {
                image = [UIImage imageWithCGImage:image.CGImage
                                           scale:image.scale
                                     orientation:orientation];
                writeLog(@"[HOOK] Aplicada rotação para orientação: %d", g_videoOrientation);
            }
        }
        
        if (!image) {
            writeLog(@"[HOOK] Falha: image é NULL após rotação");
            return %orig;
        }
        
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
