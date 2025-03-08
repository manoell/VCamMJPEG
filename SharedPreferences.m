#import "SharedPreferences.h"
#import "logger.h"

// Domínio compartilhado
static NSString *const kDomain = @"com.vcam.mjpeg.preferences";

// Chaves
static NSString *const kEnabledKey = @"VCamMJPEG_Enabled";
static NSString *const kServerURLKey = @"VCamMJPEG_ServerURL";

@implementation SharedPreferences

+ (BOOL)isTweakEnabled {
    Boolean exists;
    Boolean value = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)kEnabledKey,
                                                  (__bridge CFStringRef)kDomain,
                                                  &exists);
    
    if (!exists) {
        writeLog(@"[PREFS] Chave de ativação não encontrada, retornando false");
        return NO;
    }
    
    writeLog(@"[PREFS] Verificando status: isTweakEnabled=%d", value);
    return value;
}

+ (void)setTweakEnabled:(BOOL)enabled {
    CFPreferencesSetAppValue((__bridge CFStringRef)kEnabledKey,
                            enabled ? kCFBooleanTrue : kCFBooleanFalse,
                            (__bridge CFStringRef)kDomain);
    
    // Sincronizar imediatamente
    [self synchronize];
    
    writeLog(@"[PREFS] Definido status: setTweakEnabled=%d", enabled);
}

+ (NSString *)serverURL {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)kServerURLKey,
                                                      (__bridge CFStringRef)kDomain);
    
    if (!value) {
        writeLog(@"[PREFS] Chave de URL não encontrada, retornando nil");
        return nil;
    }
    
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        writeLog(@"[PREFS] Tipo de valor inválido para URL, retornando nil");
        return nil;
    }
    
    NSString *url = (__bridge_transfer NSString *)value;
    writeLog(@"[PREFS] Obtendo serverURL: %@", url);
    return url;
}

+ (void)setServerURL:(NSString *)url {
    if (!url) {
        CFPreferencesSetAppValue((__bridge CFStringRef)kServerURLKey,
                                NULL,
                                (__bridge CFStringRef)kDomain);
    } else {
        CFPreferencesSetAppValue((__bridge CFStringRef)kServerURLKey,
                                (__bridge CFStringRef)url,
                                (__bridge CFStringRef)kDomain);
    }
    
    // Sincronizar imediatamente
    [self synchronize];
    
    writeLog(@"[PREFS] Definido serverURL: %@", url);
}

+ (void)synchronize {
    Boolean success = CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    writeLog(@"[PREFS] Sincronização de preferências: %@", success ? @"Sucesso" : @"Falha");
}

@end
