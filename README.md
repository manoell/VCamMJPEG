# VCamMJPEG - Integração de Streaming MJPEG com Câmera iOS

## Visão Geral
VCamMJPEG é um tweak para iOS em desenvolvimento que visa permitir a utilização de um stream MJPEG como feed da câmera nativa do dispositivo. O objetivo é receber streams de vídeo via protocolo MJPEG através de rede e substituir o feed da câmera nativa em aplicativos iOS.

## Características Planejadas
- **Recepção de Streaming MJPEG**
  - Conexão com servidores MJPEG via HTTP
  - Processamento eficiente de frames
  - Suporte a diferentes resoluções
  - Otimizado para uso em tempo real

- **Substituição da Câmera Nativa**
  - Hooks no sistema AVFoundation para interceptar o feed da câmera
  - Conversão dos frames MJPEG para o formato nativo do iOS
  - Substituição transparente em aplicativos que usam a câmera

- **Interface de Controle**
  - Janela flutuante com controles
  - Preview opcional com botão para ativar/desativar
  - Contador de FPS para monitoramento de desempenho
  - Campo para configurar o endereço do servidor
  - Interface minimizável para reduzir sobrecarga

## Arquitetura do Projeto
O projeto está dividido em várias classes principais:

1. **MJPEGReader**: Responsável pela conexão com o servidor MJPEG, recepção e processamento do stream
2. **MJPEGPreviewWindow**: Gerencia a interface de usuário, controles e opções de preview
3. **VirtualCameraController**: Controla a substituição do feed da câmera nativa
4. **GetFrame**: Componente central para gerenciar o armazenamento e a recuperação dos frames para substituição
5. **Logger**: Sistema de logging para debug e monitoramento

## Funcionamento Pretendido
1. O servidor MJPEG envia um fluxo constante de imagens JPEG
2. O MJPEGReader captura e processa estas imagens
3. As imagens são convertidas em CMSampleBuffers pelo componente GetFrame
4. O Tweak intercepta chamadas da câmera nativa através de hooks em AVFoundation
5. Os frames originais da câmera são substituídos pelo feed MJPEG
6. O processo deve ser transparente para o aplicativo que usa a câmera

## Estado Atual de Desenvolvimento
- [x] Recepção e processamento de streams MJPEG
- [x] Interface de preview com opção de ativar/desativar
- [x] Hooks básicos no sistema de câmera do iOS
- [ ] **Substituição de feed da câmera** (em desenvolvimento, ainda não funcionando corretamente)
- [ ] Estabilidade em diferentes aplicativos (trabalho em andamento)
- [ ] Suporte para orientação variável (landscape/portrait)
- [ ] Seleção entre câmeras frontal/traseira
- [ ] Configurações avançadas de qualidade e performance

## Como Testar
1. Configure um servidor MJPEG na sua rede local
   - Use o servidor Node.js incluído ou outro software compatível
2. Abra a interface do tweak no SpringBoard
3. Digite o endereço do servidor MJPEG (ex: 192.168.0.178:8080/mjpeg)
4. Clique em "Conectar" para iniciar a captura
5. Você pode ativar/desativar o preview conforme necessário
6. Abra um aplicativo que use a câmera para testar a substituição (ainda em desenvolvimento)

## Configuração do Servidor
O projeto inclui um servidor MJPEG básico escrito em Node.js que pode ser configurado para:
- Capturar de webcams conectadas ao computador
- Transmitir em formato MJPEG compatível com iOS
- Configurar qualidade e resolução do stream

## Requisitos
- iOS 14.0 ou posterior
- Dispositivo com jailbreak
- Servidor MJPEG na rede local

## Problemas Conhecidos
- A substituição do feed da câmera ainda não está funcionando corretamente
- Pode ocorrer crashes em alguns aplicativos
- A orientação do vídeo pode não corresponder à orientação do dispositivo

## Próximos Passos
- Corrigir a substituição do feed da câmera
- Melhorar a estabilidade e evitar crashes
- Implementar suporte a diferentes orientações de tela
- Adicionar suporte para múltiplas câmeras (frontal/traseira)
- Implementar controles de qualidade e performance
