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
- Suporte a diferentes resoluções
- Otimizado para uso em tempo real

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

## Estado Atual de Desenvolvimento

- ✅ Recepção e processamento de streams MJPEG
- ✅ Interface de preview com opção de ativar/desativar
- ✅ Substituição do feed de visualização da câmera
- ✅ Substituição durante captura de fotos
- 🔄 Preservação de resolução e metadados
- 🔄 Substituição de miniaturas (thumbnails)
- 🔄 Compatibilidade com câmeras frontal/traseira
- 🔄 Suporte completo a vídeos
- 🔄 Configurações avançadas de qualidade e performance

## Como Usar

1. Configure um servidor MJPEG na sua rede local
   - Use o servidor Node.js incluído ou outro software compatível

2. Instale o tweak no seu dispositivo com jailbreak
3. Abra a interface do tweak no SpringBoard
4. Digite o endereço do servidor MJPEG (ex: `192.168.0.178:8080/mjpeg`)
5. Clique em "Conectar" para iniciar a captura
6. Você pode ativar/desativar o preview conforme necessário
7. Abra qualquer aplicativo que use a câmera para ver a substituição em ação
8. Tire fotos normalmente - elas serão capturadas do stream MJPEG

## Servidor MJPEG Incluído

O projeto inclui um servidor MJPEG básico escrito em Node.js que pode ser configurado para:

- Capturar de webcams conectadas ao computador
- Transmitir em formato MJPEG compatível com iOS
- Configurar qualidade e resolução do stream

## Requisitos

- iOS 14.0 até 16.7.10
- Dispositivo com jailbreak
- Servidor MJPEG na rede local

## Problemas Conhecidos

- Algumas operações de processamento de vídeo avançadas ainda não são suportadas
- Pode ocorrer consumo elevado de bateria devido ao processamento contínuo
- A orientação do vídeo pode precisar de ajustes em algumas situações

## Próximos Passos

- Melhorar a detecção e uso de câmeras frontal/traseira
- Aprimorar o suporte a diferentes resoluções
- Adicionar suporte para Live Photos
- Implementar controles de qualidade e performance
- Otimizar o uso de bateria
- Melhorar a compatibilidade com diversos aplicativos

## Compatibilidade

- iOS 14.1 (iPhone 7) atualmente
- iOS 15.8.3 (iPhone 7) falta testar
- iOS 16.7.10 (iPhone 8) falta testar

## Créditos

Este projeto foi desenvolvido combinando técnicas de diferentes fontes para criar uma solução robusta de substituição de câmera via MJPEG.

## Licença

Código fonte disponível para uso pessoal e educacional.
