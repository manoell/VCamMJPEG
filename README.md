# VCamMJPEG

## Streaming MJPEG para câmera iOS

![Badge](https://img.shields.io/badge/iOS-14.0%2B-blue)
![Badge](https://img.shields.io/badge/Status-Beta-yellow)

## Visão Geral

VCamMJPEG é um tweak para iOS jailbroken que permite substituir o feed da câmera nativa do dispositivo por um stream MJPEG via rede. Isso possibilita usar qualquer dispositivo capaz de transmitir MJPEG (como uma webcam conectada a um computador, câmera IP, ou smartphone) como uma câmera virtual para seu dispositivo iOS.

## Características

### Recepção de Streaming MJPEG
- Conexão com servidores MJPEG via HTTP
- Processamento eficiente de frames
- Suporte a diferentes resoluções (otimizado para 1920x1080)
- Alta performance com até 30fps

### Substituição da Câmera Nativa
- Injeção de camada visual personalizada
- Interação com o sistema AVFoundation
- Substituição transparente em aplicativos que usam a câmera
- Preservação da resolução e metadados originais da câmera

### Captura de Fotos
- Substituição do feed durante captura de fotos
- Preservação de miniaturas (thumbnails) e previews
- Redimensionamento automático para combinar com a câmera real
- Manutenção da orientação da imagem baseada na orientação do dispositivo

### Interface de Controle
- Janela flutuante com controles
- Preview opcional com botão para ativar/desativar
- Contador de FPS para monitoramento de desempenho
- Campo para configurar o endereço do servidor
- Interface minimizável para reduzir sobrecarga

## Arquitetura do Projeto

O projeto está dividido em vários componentes:

- **Tweak.xm**: Arquivo principal com inicialização e definições globais
- **CameraHooks.xm**: Hooks relacionados à câmera (AVCaptureSession, AVCaptureDevice)
- **PhotoHooks.xm**: Hooks específicos para captura de fotos (AVCapturePhoto)
- **PreviewHooks.xm**: Hooks relacionados ao preview da câmera
- **UIHooks.xm**: Hooks relacionados à UI (miniaturas, imagens)
- **MJPEGReader**: Responsável pela conexão e processamento do stream MJPEG
- **GetFrame**: Gerencia frames para substituição
- **VirtualCameraController**: Controla a substituição do feed da câmera
- **MJPEGPreviewWindow**: Interface de usuário, controles e opções

## Como Funciona

O VCamMJPEG utiliza uma abordagem multicamada para a substituição da câmera:

1. **Injeção em Processos**: Intercepta chamadas para a câmera em apps relevantes
2. **Detecção Automática**: Identifica a resolução e configurações da câmera real
3. **Recepção MJPEG**: Recebe e processa stream via MJPEGReader
4. **Substituição de Buffers**: Substitui frames de vídeo e captura de fotos
5. **Adaptação de Formato**: Redimensiona automaticamente para combinar com a câmera real
6. **Preservação de Metadados**: Mantém informações essenciais como orientação e timestamps

## Como Usar

### Configuração do Servidor MJPEG

1. Configure o servidor Node.js incluído:
   ```bash
   # Instale as dependências
   npm install chalk@4.1.2
   
   # Execute o servidor
   node server.js
   ```

2. Selecione o **ManyCam Virtual Webcam** quando solicitado no terminal

### Configuração do ManyCam

1. Configure a saída do ManyCam:
   - Resolução: 1920x1080 (Full HD)
   - Taxa de frames: 30fps
   - Formato: MJPEG
   - Qualidade: 90%

2. Defina sua fonte (webcam, vídeo, imagem, etc.)

### No Dispositivo iOS

1. Instale o tweak no seu dispositivo com jailbreak
2. Abra a interface do tweak no SpringBoard
3. Digite o endereço do servidor MJPEG (ex: `http://192.168.0.178:8080/mjpeg`)
4. Clique em "Conectar" para iniciar a captura
5. Você pode ativar/desativar o preview conforme necessário
6. Abra qualquer aplicativo que use a câmera para ver a substituição em ação
7. Tire fotos normalmente - elas serão capturadas do stream MJPEG

## Otimizações de Performance

Para obter o melhor desempenho:

- Use uma conexão Wi-Fi de 5GHz entre o dispositivo iOS e o servidor
- Mantenha o ManyCam e o servidor MJPEG no mesmo computador
- Desative o preview na interface quando não for necessário
- Em caso de problemas de performance, reduza a resolução para 1280x720

## Solução de Problemas

Se você encontrar problemas:

1. **Conexão**:
   - Verifique se o dispositivo iOS e o servidor estão na mesma rede
   - Confirme se nenhum firewall está bloqueando a porta 8080
   - Teste o stream MJPEG em um navegador: `http://seu-ip:8080/mjpeg`

2. **Performance**:
   - Reduza a resolução para 1280x720
   - Diminua a qualidade JPEG para 80%
   - Desative o preview na interface

3. **Compatibilidade**:
   - Em caso de problemas com apps específicos, reinicie o tweak e o aplicativo
   - Alguns aplicativos podem exigir reinicialização para reconhecer o stream

## Requisitos

- iOS 14.0 até 16.7.10
- Dispositivo com jailbreak
- Servidor MJPEG na rede local
- PC com ManyCam ou software similar

## Compatibilidade

- iOS 14.x: Testado e funcionando (iPhone 7)
- iOS 15.x: Falta testar (iPhone 7)
- iOS 16.x: Falta testar (iPhone 8)

## Próximos Passos

- Implementação completa de redimensionamento automático
- Melhorias na detecção de orientação
- Otimizações de performance para streaming em alta resolução
- Suporte para Live Photos
- Interface de configuração avançada

## Créditos

Este projeto foi desenvolvido utilizando técnicas avançadas de hooking do sistema de câmera iOS e processamento de stream MJPEG.

## Licença

Código fonte disponível para uso pessoal e educacional.
