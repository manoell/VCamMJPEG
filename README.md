# VCamMJPEG - Integração de Streaming MJPEG com Câmera iOS

## Visão Geral
VCamMJPEG é um tweak avançado para iOS que permite utilizar um stream MJPEG como feed da câmera nativa do dispositivo. O tweak recebe streams de vídeo via protocolo MJPEG e permite substituir a câmera nativa em qualquer aplicativo, mantendo a experiência original e sendo completamente indetectável.

## Características Atuais
- **Recepção de Streaming MJPEG**
  - Conexão estável com servidores MJPEG
  - Processamento eficiente de frames
  - Suporte a diferentes resoluções

- **Interface de Preview**
  - Janela flutuante com controles
  - Visualização em tempo real do stream
  - Contador de FPS para monitoramento de desempenho
  - Botão para conectar/desconectar

## Estado Atual
Atualmente, o tweak é capaz de:
- Iniciar com o SpringBoard e mostrar uma janela de controle flutuante
- Conectar-se a um servidor MJPEG e exibir o stream recebido na janela de preview
- Medir e exibir o FPS do stream recebido

## Próximos Passos
Para que o tweak fique totalmente funcional e indetectável, precisamos implementar:

1. **Substituição da Câmera Nativa**
   - Hooks no sistema AVFoundation para interceptar o feed da câmera
   - Conversão dos frames MJPEG para o formato adequado do iOS
   - Substituição do buffer de imagem da câmera nativa

2. **Otimizações de Desempenho**
   - Minimizar a latência entre recepção e exibição
   - Otimizar o processamento de imagem para economia de bateria
   - Melhorar a sincronização entre o áudio nativo e o vídeo recebido

3. **Compatibilidade Ampla**
   - Garantir funcionamento em todos os aplicativos de câmera
   - Lidar com diferentes orientações (retrato/paisagem)
   - Adaptar para diferentes modelos de iPhone

## Requisitos
- iOS 14.0 ou posterior
- Dispositivo com jailbreak
- Servidor MJPEG na rede local

## Instalação
1. Adicione o repositório ao gerenciador de pacotes
2. Instale o pacote VCamMJPEG
3. Faça respring do dispositivo
4. Configure o servidor MJPEG no arquivo de configuração (ou através da interface)

## Configuração
Atualmente, o endereço do servidor MJPEG é configurado diretamente no código:
```objc
static NSString *const kDefaultServerURL = @"http://192.168.0.178:8080/mjpeg";
```

## Servidor MJPEG
Para utilizar este tweak, você precisa de um servidor MJPEG rodando na sua rede local. Um exemplo de implementação usando Node.js está disponível no repositório do projeto.

## Solução de Problemas
Se você não conseguir ver o stream no preview:
- Verifique se o servidor MJPEG está acessível no endereço configurado
- Certifique-se de que o dispositivo iOS está na mesma rede do servidor
- Verifique os logs para identificar possíveis erros

## Licença
Este projeto está licenciado sob termos proprietários.
Todos os direitos reservados.

## Histórico de Versões
- **0.1.0 (Desenvolvimento)**
  - Implementação inicial do cliente MJPEG
  - Interface de preview funcional
  - Preparação para hooks no sistema de câmera
