const express = require('express');
const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const app = express();
const server = http.createServer(app);

// Configurações avançadas
const PORT = 8080;
const FRAME_RATE = 30;
const QUALITY = 85; // Aumentado para melhor qualidade
const WIDTH = 1280;
const HEIGHT = 720;
const BUFFER_SIZE = 5; // Número de frames a manter em buffer para suavizar entrega
const KEEP_ALIVE_TIMEOUT = 30000; // Timeout para keep-alive em ms

// Inicializar o cliente MJPEG
let clients = [];
let frameBuffer = [];
let latestImage = null;
let clientCount = 0;
let framesProcessed = 0;
let lastFPSCheck = Date.now();
let serverFPS = 0;
let currentCamera = 'Detectando...';

// Configuração do server para otimizar performance
server.keepAliveTimeout = KEEP_ALIVE_TIMEOUT;
server.headersTimeout = KEEP_ALIVE_TIMEOUT + 5000;

// Detectar capacidades do sistema
const cpuCores = os.cpus().length;
const systemInfo = {
    platform: os.platform(),
    cpuCores: cpuCores,
    totalMemory: Math.round(os.totalmem() / (1024 * 1024 * 1024)) + 'GB',
    freeMemory: Math.round(os.freemem() / (1024 * 1024)) + 'MB'
};

console.log('Sistema detectado:', systemInfo);

// Página principal com painel de status
app.get('/', (req, res) => {
    res.send(`
        <!DOCTYPE html>
        <html>
        <head>
            <title>VCamMJPEG Streaming Server</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body { font-family: Arial, sans-serif; margin: 0; padding: 20px; text-align: center; background-color: #f5f5f5; }
                h1 { color: #333; }
                img { max-width: 100%; border: 1px solid #ddd; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
                .container { max-width: 1000px; margin: 0 auto; background: white; padding: 20px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
                .stats { margin-top: 20px; padding: 15px; background: #eef8ff; border-radius: 6px; text-align: left; }
                .stats-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
                .stat-item { padding: 8px; }
                .header { background: #2c3e50; color: white; padding: 15px; border-radius: 6px 6px 0 0; margin-bottom: 20px; }
                .badge { display: inline-block; padding: 3px 8px; border-radius: 12px; font-size: 12px; font-weight: bold; background: #27ae60; color: white; }
                #serverStatus { font-weight: bold; color: #27ae60; }
                button { background: #3498db; color: white; border: none; padding: 10px 15px; border-radius: 4px; cursor: pointer; margin-top: 10px; }
                button:hover { background: #2980b9; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h1>VCamMJPEG Streaming Server</h1>
                    <div><span class="badge">v1.1</span> <span class="badge">iOS Optimized</span></div>
                </div>
                
                <div>
                    <h3>Preview do Stream</h3>
                    <img src="/mjpeg" alt="MJPEG Stream" width="640" />
                </div>
                
                <div class="stats">
                    <h3>Status do Servidor <span id="serverStatus">ONLINE</span></h3>
                    <div class="stats-grid">
                        <div class="stat-item">
                            <strong>Resolução:</strong> ${WIDTH}x${HEIGHT}
                        </div>
                        <div class="stat-item">
                            <strong>Frame Rate Alvo:</strong> ${FRAME_RATE}fps
                        </div>
                        <div class="stat-item">
                            <strong>Qualidade:</strong> ${QUALITY}%
                        </div>
                        <div class="stat-item">
                            <strong>Câmera:</strong> <span id="cameraName">Detectando...</span>
                        </div>
                        <div class="stat-item">
                            <strong>Clientes:</strong> <span id="clientCount">0</span>
                        </div>
                        <div class="stat-item">
                            <strong>FPS Atual:</strong> <span id="currentFPS">0</span>
                        </div>
                        <div class="stat-item">
                            <strong>CPU:</strong> ${cpuCores} cores
                        </div>
                        <div class="stat-item">
                            <strong>Memória:</strong> ${systemInfo.freeMemory} livre
                        </div>
                    </div>
                </div>
                
                <div style="margin-top: 20px;">
                    <h3>Endpoint do Stream</h3>
                    <code style="background: #f1f1f1; padding: 10px; display: block; border-radius: 4px;">http://<span id="serverIP">localhost</span>:${PORT}/mjpeg</code>
                    <button id="copyButton">Copiar URL</button>
                </div>
            </div>
            
            <script>
                // Preencher IP do servidor
                fetch('/api/server-info')
                    .then(res => res.json())
                    .then(data => {
                        document.getElementById('serverIP').textContent = data.localIP;
                    });
                
                // Atualizar estatísticas a cada segundo
                setInterval(() => {
                    fetch('/api/status')
                        .then(res => res.json())
                        .then(data => {
                            document.getElementById('clientCount').textContent = data.clientCount;
                            document.getElementById('currentFPS').textContent = data.currentFPS.toFixed(1);
                            
                            // Exibir informações da câmera
                            if (data.camera) {
                                document.getElementById('cameraName').textContent = data.camera;
                            }
                            
                            // Atualizar status do servidor
                            if (data.isHealthy) {
                                document.getElementById('serverStatus').textContent = 'ONLINE';
                                document.getElementById('serverStatus').style.color = '#27ae60';
                            } else {
                                document.getElementById('serverStatus').textContent = 'PROBLEMAS DETECTADOS';
                                document.getElementById('serverStatus').style.color = '#e74c3c';
                            }
                        })
                        .catch(err => {
                            document.getElementById('serverStatus').textContent = 'OFFLINE';
                            document.getElementById('serverStatus').style.color = '#e74c3c';
                        });
                }, 1000);
                
                // Botão de copiar URL
                document.getElementById('copyButton').addEventListener('click', () => {
                    const serverIP = document.getElementById('serverIP').textContent;
                    const url = 'http://' + serverIP + ':' + ${PORT} + '/mjpeg';
                    navigator.clipboard.writeText(url)
                        .then(() => {
                            document.getElementById('copyButton').textContent = 'Copiado!';
                            setTimeout(() => {
                                document.getElementById('copyButton').textContent = 'Copiar URL';
                            }, 2000);
                        });
                });
            </script>
        </body>
        </html>
    `);
});

// Endpoint para informações do servidor
app.get('/api/server-info', (req, res) => {
    const networkInterfaces = os.networkInterfaces();
    let localIP = 'localhost';
    
    // Encontrar IP local (não loopback)
    Object.keys(networkInterfaces).forEach(ifname => {
        networkInterfaces[ifname].forEach(iface => {
            if (!iface.internal && iface.family === 'IPv4') {
                localIP = iface.address;
            }
        });
    });
    
    res.json({
        localIP,
        port: PORT,
        system: systemInfo
    });
});

// Endpoint de status API
app.get('/api/status', (req, res) => {
    // Calcular FPS atual
    const now = Date.now();
    const elapsed = (now - lastFPSCheck) / 1000;
    
    if (elapsed >= 1) {
        serverFPS = framesProcessed / elapsed;
        framesProcessed = 0;
        lastFPSCheck = now;
    }
    
    // Verificar saúde do sistema
    const isHealthy = serverFPS > (FRAME_RATE * 0.5); // Se FPS for pelo menos 50% do alvo
    
    res.json({
        clientCount: clients.length,
        currentFPS: serverFPS,
        isHealthy,
        camera: currentCamera,
        config: {
            width: WIDTH,
            height: HEIGHT,
            frameRate: FRAME_RATE,
            quality: QUALITY
        },
        system: {
            freeMemory: Math.round(os.freemem() / (1024 * 1024)) + 'MB',
            uptime: Math.round(os.uptime() / 60) + ' minutos'
        }
    });
});

// Stream MJPEG
app.get('/mjpeg', (req, res) => {
    console.log('Novo cliente conectado');
    
    // Configuração do cabeçalho MJPEG otimizado
    res.writeHead(200, {
        'Content-Type': 'multipart/x-mixed-replace; boundary=mjpegstream',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no' // Desativar buffering para proxies
    });
    
    // Adicionar cliente à lista
    const clientId = Date.now();
    const newClient = {
        id: clientId,
        res,
        lastFrame: 0
    };
    clients.push(newClient);
    clientCount = clients.length;
    
    // Enviar últimos frames em buffer imediatamente para inicialização rápida
    if (frameBuffer.length > 0) {
        for (let frame of frameBuffer) {
            try {
                res.write(frame);
            } catch (error) {
                console.error('Erro ao enviar frame inicial:', error);
            }
        }
    }
    
    // Remover cliente quando a conexão for fechada
    req.on('close', () => {
        console.log('Cliente desconectado');
        clients = clients.filter(client => client.id !== clientId);
        clientCount = clients.length;
    });
    
    // Timeout para clientes inativos
    req.on('timeout', () => {
        console.log('Timeout de cliente');
        clients = clients.filter(client => client.id !== clientId);
        clientCount = clients.length;
    });
});

// Configuração de handlers FFmpeg
function setupFFmpegHandlers(ffmpeg) {
    // Buffer para acumular dados
    let buffer = Buffer.alloc(0);
    
    ffmpeg.stdout.on('data', (data) => {
        // Concatenar ao buffer existente
        buffer = Buffer.concat([buffer, data]);
        
        // Procurar marcadores JPEG (SOI: 0xFF,0xD8 e EOI: 0xFF,0xD9)
        let start = 0;
        
        while (start < buffer.length) {
            // Encontrar início do JPEG (SOI marker)
            const soiPos = buffer.indexOf(Buffer.from([0xFF, 0xD8]), start);
            if (soiPos === -1) break; // Nenhum início encontrado
            
            // Encontrar fim do JPEG (EOI marker)
            const eoiPos = buffer.indexOf(Buffer.from([0xFF, 0xD9]), soiPos + 2);
            if (eoiPos === -1) break; // Fim não encontrado, esperar mais dados
            
            // Extrair o frame JPEG completo (incluindo EOI)
            const jpegEnd = eoiPos + 2;
            const jpegData = buffer.slice(soiPos, jpegEnd);
            
            // Preparar o frame MJPEG
            const boundary = `--mjpegstream\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpegData.length}\r\n\r\n`;
            const mjpegFrame = Buffer.concat([
                Buffer.from(boundary, 'utf8'),
                jpegData,
                Buffer.from('\r\n', 'utf8')
            ]);
            
            // Manter no buffer circular
            frameBuffer.push(mjpegFrame);
            if (frameBuffer.length > BUFFER_SIZE) {
                frameBuffer.shift(); // Remover frame mais antigo
            }
            
            // Armazenar a última imagem para clientes novos
            latestImage = mjpegFrame;
            
            // Enviar para todos os clientes
            for (let i = 0; i < clients.length; i++) {
                try {
                    clients[i].res.write(mjpegFrame);
                } catch (error) {
                    console.error('Erro ao enviar frame para cliente:', error);
                    // Remove cliente com erro
                    clients.splice(i, 1);
                    i--;
                }
            }
            
            // Atualizar estatísticas
            framesProcessed++;
            
            // Avançar para o próximo frame
            start = jpegEnd;
        }
        
        // Manter no buffer o resto não processado
        if (start > 0 && start < buffer.length) {
            buffer = buffer.slice(start);
        } else if (start > 0) {
            buffer = Buffer.alloc(0);
        }
    });

    ffmpeg.stderr.on('data', (data) => {
        // Filtrar logs de ffmpeg para mostrar apenas erros importantes
        const logStr = data.toString();
        if (logStr.includes('Error') || logStr.includes('error') || logStr.includes('fail')) {
            console.error(`ffmpeg erro: ${logStr}`);
        }
    });

    ffmpeg.on('close', (code) => {
        console.log(`ffmpeg encerrado com código ${code}`);
    });
}

// Função para capturar frame da webcam usando ffmpeg
function startCapture(cameraName) {
    // Atualizar a variável global de câmera
    currentCamera = cameraName;
    
    // Usar configuração mais simples e comprovada, baseada na versão anterior que funcionava
    const ffmpegArgs = [
        '-f', 'dshow',                       // Formato DirectShow (Windows)
        '-video_size', `${WIDTH}x${HEIGHT}`, // Tamanho do vídeo
        '-framerate', `${FRAME_RATE}`,       // Taxa de frames
        '-i', `video=${cameraName}`,         // Nome da webcam selecionada
        '-f', 'image2pipe',                  // Saída como pipe de imagens
        '-pix_fmt', 'yuvj420p',              // Formato de pixel para iOS (compatível com JPEG)
        '-q:v', `${Math.round((100-QUALITY)/5)}`, // Qualidade
        '-vf', `fps=${FRAME_RATE}`,          // Forçar FPS consistente
        '-update', '1',                      // Atualização constante
        '-'                                  // Saída para stdout
    ];
    
    console.log('Iniciando ffmpeg com configuração:', ffmpegArgs.join(' '));
    
    const ffmpeg = spawn('ffmpeg', ffmpegArgs);
    setupFFmpegHandlers(ffmpeg);
    
    // Configurar um watchdog para reiniciar se nenhum frame for recebido
    setTimeout(() => {
        if (framesProcessed === 0) {
            console.log(`Nenhum frame recebido da câmera ${cameraName} após 10 segundos.`);
            console.log('Reiniciando ffmpeg...');
            ffmpeg.kill();
            setTimeout(() => startCapture(cameraName), 1000);
        }
    }, 10000);
    
    return ffmpeg;
}

// Função para criar um padrão de teste
function startTestPatternCapture() {
    console.log('Iniciando padrão de teste como fonte de vídeo');
    
    // Atualizar a variável global de câmera
    currentCamera = "Padrão de Teste (Sem câmera)";
    
    // Configuração para geração de padrão de teste
    const ffmpegArgs = [
        '-f', 'lavfi',                       // Formato lavfi (filtros)
        '-i', `testsrc=size=${WIDTH}x${HEIGHT}:rate=${FRAME_RATE}`, // Gerador de padrão de teste
        '-f', 'image2pipe',                  // Saída como pipe de imagens
        '-pix_fmt', 'yuvj420p',              // Formato de pixel
        '-q:v', `${Math.round((100-QUALITY)/5)}`, // Qualidade
        '-vf', `fps=${FRAME_RATE}`,          // Forçar FPS
        '-update', '1',                      // Atualização constante
        '-'                                  // Saída para stdout
    ];
    
    console.log('Iniciando ffmpeg com padrão de teste:', ffmpegArgs.join(' '));
    
    const ffmpeg = spawn('ffmpeg', ffmpegArgs);
    setupFFmpegHandlers(ffmpeg);
    
    // Configurar reinício automático em caso de falha
    ffmpeg.on('close', (code) => {
        if (code !== 0) {
            console.log('Padrão de teste encerrado com erro. Reiniciando...');
            setTimeout(() => startTestPatternCapture(), 2000);
        }
    });
    
    return ffmpeg;
}

// Função para listar e escolher a webcam
async function selectWebcam() {
    console.log('Buscando dispositivos de câmera disponíveis...');
    
    try {
        // Executar FFmpeg para listar dispositivos
        const ffmpeg = spawn('ffmpeg', ['-list_devices', 'true', '-f', 'dshow', '-i', 'dummy']);
        
        // Coletar saída de erro (onde aparecem os dispositivos no dshow)
        let deviceList = '';
        
        ffmpeg.stderr.on('data', (data) => {
            deviceList += data.toString();
        });
        
        // Processar após fechar
        await new Promise((resolve) => {
            ffmpeg.on('close', (code) => {
                console.log('Lista de dispositivos finalizada com código:', code);
                resolve();
            });
        });
        
        // Analisar lista de dispositivos
        const videoDevices = [];
        const lines = deviceList.split('\n');
        let collectingVideo = false;
        
        for (const line of lines) {
            if (line.includes('DirectShow video devices')) {
                collectingVideo = true;
                continue;
            } else if (line.includes('DirectShow audio devices')) {
                collectingVideo = false;
                continue;
            }
            
            if (collectingVideo && line.includes('"')) {
                const deviceName = line.match(/"([^"]*)"/);
                if (deviceName && deviceName[1]) {
                    videoDevices.push(deviceName[1]);
                }
            }
        }
        
        console.log('Dispositivos de vídeo encontrados:', videoDevices);
        
        // Se não encontrou dispositivos, tente alguns nomes comuns
        if (videoDevices.length === 0) {
            console.log('Nenhum dispositivo encontrado via FFmpeg. Adicionando nomes comuns...');
            videoDevices.push(
                'ManyCam Virtual Webcam',
                'Webcam',
                'Camera',
                'HD Camera',
                'USB Camera',
                'Integrated Camera',
                'OBS Virtual Camera',
                '0'  // Índice do dispositivo
            );
        }
        
        // Adicionar opção de teste como última alternativa
        videoDevices.push('TEST PATTERN (Sem câmera)');
        
        // Mostrar menu para escolha
        console.log('\n=======================================');
        console.log('SELECIONE UMA CÂMERA PARA O STREAMING:');
        console.log('=======================================');
        
        videoDevices.forEach((device, index) => {
            console.log(`${index + 1}. ${device}`);
        });
        
        console.log('\nDigite o número da câmera desejada e pressione ENTER:');
        
        // Função para ler a entrada do usuário
        const readUserInput = () => {
            return new Promise((resolve) => {
                const stdin = process.stdin;
                stdin.resume();
                stdin.setEncoding('utf8');
                
                stdin.on('data', (data) => {
                    const input = parseInt(data.trim());
                    if (isNaN(input) || input < 1 || input > videoDevices.length) {
                        console.log(`Por favor, digite um número entre 1 e ${videoDevices.length}:`);
                    } else {
                        stdin.pause();
                        resolve(input - 1); // Índice baseado em zero
                    }
                });
            });
        };
        
        // Esperar a escolha do usuário
        const selectedIndex = await readUserInput();
        const selectedDevice = videoDevices[selectedIndex];
        
        console.log(`\nVocê selecionou: ${selectedDevice}`);
        
        // Se for o padrão de teste
        if (selectedDevice === 'TEST PATTERN (Sem câmera)') {
            return { isTestPattern: true };
        }
        
        return { 
            isTestPattern: false, 
            deviceName: selectedDevice 
        };
    } catch (error) {
        console.error('Erro ao buscar câmeras:', error);
        console.log('Usando padrão de teste como fallback...');
        return { isTestPattern: true };
    }
}

// Iniciar servidor com tratamento de erros
server.listen(PORT, () => {
    console.log(`
╔════════════════════════════════════════════════╗
║  VCamMJPEG Server v1.1 - iOS Optimized         ║
╟────────────────────────────────────────────────╢
║  Server running at:                            ║
║  http://localhost:${PORT}                         ║
║                                                ║
║  MJPEG stream available at:                    ║
║  http://localhost:${PORT}/mjpeg                   ║
╚════════════════════════════════════════════════╝
`);
    
    // Iniciar o processo de seleção e captura
    selectWebcam().then(result => {
        if (result.isTestPattern) {
            console.log('Iniciando com padrão de teste...');
            startTestPatternCapture();
        } else {
            console.log(`Iniciando captura com a câmera: ${result.deviceName}`);
            startCapture(result.deviceName);
        }
    });

    // Configurar tratamento de erros para captura não-crítica
    process.on('uncaughtException', (err) => {
        console.error('Erro não tratado:', err);
        // Não encerrar o servidor para erros não-críticos
    });
});