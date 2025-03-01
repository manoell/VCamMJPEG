#import "logger.h"

static int gLogLevel = 3; // Valor padrão: aviso

void setLogLevel(int level) {
    gLogLevel = level;
}

void writeLog(NSString *format, ...) {
    // Se log estiver desativado, retorna imediatamente
    if (gLogLevel <= 0) return;
    
    @try {
        va_list args;
        va_start(args, format);
        NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        // Formatar a mensagem com timestamp
        NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n",
                              [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                            dateStyle:NSDateFormatterNoStyle
                                                            timeStyle:NSDateFormatterMediumStyle],
                              formattedString];
        
        // Mostrar log no console (sempre)
        NSLog(@"[VCamMJPEG] %@", formattedString);
        
        // Em modo debug ou superior, salvar em arquivo
        if (gLogLevel >= 4) {
            // Caminho para logs
            NSString *logPath = @"/var/tmp/VCamMJPEG.log";
            
            // Tentar abrir arquivo existente
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
            
            if (fileHandle == nil) {
                // Criar arquivo se não existir
                [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
                
                if (fileHandle == nil) {
                    return; // Não conseguiu criar arquivo
                }
            }
            
            @try {
                [fileHandle seekToEndOfFile];
                [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
                [fileHandle closeFile];
            } @catch (NSException *e) {
                NSLog(@"[VCamMJPEG] Erro ao escrever log: %@", e);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[VCamMJPEG] ERRO NO LOGGER: %@", e);
    }
}
