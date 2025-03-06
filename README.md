# VCamMJPEG

## Streaming MJPEG para câmera iOS

![Badge](https://img.shields.io/badge/iOS-14.0%2B-blue)
![Badge](https://img.shields.io/badge/Status-Em%20Desenvolvimento-yellow)

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

### Interface de Controle
- Janela flutuante com controles
- Preview opcional com botão para ativar/desativar
- Contador de FPS para monitoramento de desempenho
- Campo para configurar o endereço do servidor
- Interface minimizável para reduzir sobrecarga

## Arquitetura do Projeto

O projeto está dividido em várias classes principais:

- **MJPEGReader**: Responsável pela conexão com o servidor MJPEG, recepção e processamento do stream
- **MJPEGPreviewWindow**: Gerencia a interface de usuário, controles e opções de preview
- **VirtualCameraController**: Controla a substituição do feed da câmera nativa
- **GetFrame**: Componente central para gerenciar o armazenamento e a recuperação dos frames para substituição
- **Tweak.xm**: Contém os hooks para interceptar as chamadas da câmera e injetar nossas camadas

## Como Funciona

O VCamMJPEG utiliza uma abordagem focada na substituição da camada de visualização da câmera:

1. O servidor MJPEG envia um fluxo constante de imagens JPEG
2. O MJPEGReader captura e processa estas imagens
3. As imagens são convertidas em CMSampleBuffers pelo GetFrame
4. O tweak injeta uma AVSampleBufferDisplayLayer personalizada sobre a camada de preview original da câmera
5. Os frames MJPEG são enviados para esta camada personalizada
6. Um CADisplayLink mantém a atualização constante da camada

## Estado Atual de Desenvolvimento

- ✅ Recepção e processamento de streams MJPEG
- ✅ Interface de preview com opção de ativar/desativar
- ✅ Substituição do feed de visualização da câmera
- 🔄 Substituição do feed durante captura de fotos (em desenvolvimento)
- 🔄 Estabilidade em diferentes aplicativos (trabalho em andamento)
- 🔄 Suporte para orientação variável (parcialmente implementado)
- 🔄 Seleção entre câmeras frontal/traseira
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

## Servidor MJPEG Incluído

O projeto inclui um servidor MJPEG básico escrito em Node.js que pode ser configurado para:

- Capturar de webcams conectadas ao computador
- Transmitir em formato MJPEG compatível com iOS
- Configurar qualidade e resolução do stream

## Requisitos

- iOS 14.0 ou posterior
- Dispositivo com jailbreak
- Servidor MJPEG na rede local

## Problemas Conhecidos

- A captura de fotos ainda usa a câmera real em vez do stream MJPEG (em desenvolvimento)
- Pode ocorrer consumo elevado de bateria devido ao processamento contínuo
- A orientação do vídeo pode não corresponder perfeitamente à orientação do dispositivo

## Próximos Passos

- Implementar a substituição durante a captura de fotos
- Melhorar a estabilidade e evitar crashes
- Aprimorar o suporte a diferentes orientações de tela
- Adicionar suporte para múltiplas câmeras (frontal/traseira)
- Implementar controles de qualidade e performance
- Otimizar o uso de bateria

## Créditos

Este projeto foi inspirado por outros tweaks de câmera virtual, combinando técnicas de diferentes fontes para criar uma solução robusta de substituição de câmera via MJPEG.

## Licença

Código fonte disponível para uso pessoal e educacional.
