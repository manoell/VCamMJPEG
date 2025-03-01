const express = require('express');
const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const app = express();
const server = http.createServer(app);

// Configurações
const PORT = 8080;
const FRAME_RATE = 30;
const QUALITY = 80; // 0-100, maior = melhor qualidade, maior tamanho
const WIDTH = 1280;
const HEIGHT = 720;

// Inicializar o cliente MJPEG
let clients = [];
let latestImage = null;

// Página principal
// Substitua a seção da página principal por esta:
app.get('/', (req, res) => {
    res.send(`
        <!DOCTYPE html>
        <html>
        <head>
            <title>ManyCam MJPEG Stream</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 0; padding: 20px; text-align: center; }
                h1 { color: #333; }
                img { max-width: 100%; border: 1px solid #ddd; }
                .container { max-width: 1000px; margin: 0 auto; }
                .stats { margin-top: 20px; padding: 10px; background: #f5f5f5; border-radius: 4px; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>ManyCam MJPEG Stream</h1>
                <img src="/mjpeg" alt="MJPEG Stream" />
                <div class="stats">
                    <p>Configuração: ${WIDTH}x${HEIGHT} @ ${FRAME_RATE}fps, Qualidade: ${QUALITY}%</p>
                    <p id="clientCount">Clientes conectados: 0</p>
                </div>
            </div>
            <script>
                // Atualizar contagem de clientes a cada segundo
                setInterval(() => {
                    fetch('/status')
                        .then(res => res.json())
                        .then(data => {
                            document.getElementById('clientCount').textContent = 
                                \`Clientes conectados: \${data.clientCount}\`;
                        });
                }, 1000);
            </script>
        </body>
        </html>
    `);
});

// Endpoint de status
app.get('/status', (req, res) => {
    res.json({
        clientCount: clients.length,
        config: {
            width: WIDTH,
            height: HEIGHT,
            frameRate: FRAME_RATE,
            quality: QUALITY
        }
    });
});

// Stream MJPEG
app.get('/mjpeg', (req, res) => {
    console.log('Novo cliente conectado');
    
    // Configuração do cabeçalho MJPEG
    res.writeHead(200, {
        'Content-Type': 'multipart/x-mixed-replace; boundary=mjpegstream',
        'Cache-Control': 'no-cache',
        'Connection': 'close',
        'Pragma': 'no-cache'
    });
    
    // Adicionar cliente à lista
    const clientId = Date.now();
    const newClient = {
        id: clientId,
        res
    };
    clients.push(newClient);
    
    // Enviar última imagem disponível imediatamente se existir
    if (latestImage) {
        res.write(latestImage);
    }
    
    // Remover cliente quando a conexão for fechada
    req.on('close', () => {
        console.log('Cliente desconectado');
        clients = clients.filter(client => client.id !== clientId);
    });
});

// Função para capturar frame da webcam/ManyCam usando ffmpeg
function startCapture() {
    // Usar ffmpeg para capturar da webcam virtual
    const ffmpeg = spawn('ffmpeg', [
        '-f', 'dshow',                       // Formato DirectShow (Windows)
        '-video_size', `${WIDTH}x${HEIGHT}`, // Tamanho do vídeo
        '-framerate', `${FRAME_RATE}`,       // Taxa de frames
        '-i', 'video=ManyCam Virtual Webcam', // Nome da webcam ManyCam - ajuste conforme necessário
        '-f', 'image2pipe',                  // Saída como pipe de imagens
        '-pix_fmt', 'yuvj420p',              // Formato de pixel
        '-q:v', `${Math.round((100-QUALITY)/5)}`, // Qualidade (2-31, menor = melhor)
        '-vf', 'fps=30',                     // Forçar FPS
        '-update', '1',                      // Atualização constante
        '-'                                  // Saída para stdout
    ]);

    ffmpeg.stdout.on('data', (data) => {
        // Preparar o frame MJPEG
        const boundary = '--mjpegstream\r\nContent-Type: image/jpeg\r\nContent-Length: ' + data.length + '\r\n\r\n';
        const mjpegFrame = Buffer.concat([
            Buffer.from(boundary, 'utf8'),
            data,
            Buffer.from('\r\n', 'utf8')
        ]);
        
        // Armazenar a última imagem
        latestImage = mjpegFrame;
        
        // Enviar para todos os clientes
        clients.forEach(client => {
            try {
                client.res.write(mjpegFrame);
            } catch (error) {
                console.error('Erro ao enviar frame para cliente:', error);
            }
        });
    });

    ffmpeg.stderr.on('data', (data) => {
        // Não logar todos os erros do ffmpeg
        //console.log(`ffmpeg log: ${data}`);
    });

    ffmpeg.on('close', (code) => {
        console.log(`ffmpeg encerrado com código ${code}`);
        // Tentar reiniciar após um pequeno atraso
        setTimeout(() => {
            console.log('Tentando reiniciar captura...');
            startCapture();
        }, 5000);
    });
}

// Iniciar servidor
server.listen(PORT, () => {
    console.log(`Servidor MJPEG rodando em http://localhost:${PORT}`);
    console.log(`Stream MJPEG disponível em http://localhost:${PORT}/mjpeg`);
    
    // Iniciar captura
    startCapture();
});