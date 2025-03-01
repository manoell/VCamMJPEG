# VCamMJPEG - Integração de Streaming MJPEG com Câmera iOS

## Visão Geral
VCamMJPEG é um tweak avançado para iOS que permite utilizar um stream MJPEG como feed da câmera nativa do dispositivo. O tweak recebe streams de vídeo via protocolo MJPEG e substitui a câmera nativa em qualquer aplicativo, mantendo a experiência original e sendo completamente indetectável.

## Características
- **Recepção de Streaming MJPEG**
  - Conexão estável com servidores MJPEG
  - Processamento eficiente de frames
  - Suporte a diferentes resoluções
  - Baixa latência otimizada para uso em tempo real

- **Substituição da Câmera Nativa**
  - Hooks no sistema AVFoundation para interceptar o feed da câmera
  - Conversão dos frames MJPEG para o formato nativo do iOS
  - Substituição transparente em qualquer aplicativo que use a câmera

- **Interface de Preview**
  - Janela flutuante com controles
  - Visualização em tempo real do stream
  - Contador de FPS para monitoramento de desempenho
  - Campo para configurar o endereço do servidor
  - Facilmente movimentável pela tela

## Arquitetura do Projeto
O projeto está dividido em várias classes para facilitar a manutenção:

1. **MJPEGReader**: Responsável pela conexão com o servidor MJPEG, recepção e processamento do stream
2. **MJPEGPreviewWindow**: Gerencia a janela flutuante de preview e controles
3. **VirtualCameraController**: Controla a substituição do feed da câmera nativa
4. **Logger**: Sistema de logging para debug e monitoramento

## Requisitos
- iOS 14.0 ou posterior
- Dispositivo com jailbreak
- Servidor MJPEG na rede local

## Servidor MJPEG
O projeto inclui um servidor MJPEG otimizado baseado em Node.js que:
- Captura de webcams ou dispositivos de captura virtual
- Transmite em formato MJPEG compatível com iOS
- Oferece configurações de qualidade e resolução
- Fornece estatísticas de desempenho em tempo real

## Instalação
1. Adicione o repositório ao gerenciador de pacotes
2. Instale o pacote VCamMJPEG
3. Faça respring do dispositivo
4. Configure o endereço do servidor MJPEG através da interface flutuante

## Configuração do Servidor
1. Instale Node.js e as dependências necessárias
2. Execute o servidor.js em um computador na mesma rede do dispositivo iOS
3. Siga as instruções na interface web do servidor para configurar a câmera desejada
4. Copie o endereço exibido no servidor para a interface do tweak no dispositivo

## Uso Típico
1. Inicie o servidor MJPEG no computador
2. No dispositivo iOS, conecte-se ao servidor através da interface do tweak
3. Abra qualquer aplicativo que use a câmera - o stream será substituído automaticamente
4. A janela de preview pode ser minimizada ou movida conforme necessário

## Solução de Problemas
Se você não conseguir ver o stream no preview:
- Verifique se o servidor MJPEG está acessível no endereço configurado
- Certifique-se de que o dispositivo iOS está na mesma rede do servidor
- Verifique os logs para identificar possíveis erros
- Tente reiniciar o servidor e reconectar o cliente

## Estado do Desenvolvimento
- [x] Recepção e processamento de streams MJPEG
- [x] Interface de preview funcional
- [x] Hooks no sistema de câmera do iOS
- [x] Substituição de câmera em aplicativos nativos
- [ ] Suporte para orientação variável (landscape/portrait)
- [ ] Seleção entre câmeras frontal/traseira
- [ ] Configurações avançadas de qualidade e performance

## Licença
Este projeto está licenciado sob termos proprietários.
Todos os direitos reservados.

## Histórico de Versões
- **0.2.0 (Atual)**
  - Implementação dos hooks de AVFoundation
  - Substituição funcional do feed da câmera
  - Interface melhorada com configuração de servidor
  - Melhorias na estabilidade e performance

- **0.1.0 (Inicial)**
  - Implementação inicial do cliente MJPEG
  - Interface de preview básica
  - Preparação para hooks no sistema de câmera