# Kidicom

Visualizador DICOM leve e nativo para Macs com Apple Silicon, para quem lê ultrassom, raio X, mamografia, densitometria, TC e RM no próprio computador sem PACS.

Bundle id: `com.salomao.kidicom`. Código aberto no GitHub, distribuído fora da Mac App Store (assinado e notarizado).

## Replaces
Horos e OsiriX para leitura local: abrir CDs e zips de laboratório, rolar séries, comparar com exames anteriores.

## Main jobs
1. Importar exames por `+` ou arrastar e soltar (arquivos, pastas, zips de laboratório, `DICOMDIR`), escolhendo copiar para a base do Kidicom ou manter no local de origem.
2. Abrir um exame da worklist e ler: layout de 1 a 4 viewports, rolar imagens com roda e arraste, janela/nível, zoom, pan, girar e espelhar, cine play/pause para ultrassom multiframe.
3. Reformatar TC e RM axiais: MPR (axial, coronal, sagital), MIP com espessura de corte ajustável e reconstrução 3D por volume rendering com janelamento e rotação.
4. Comparar com exames anteriores do mesmo paciente lado a lado, com rolagem sincronizada pela posição anatômica e deslocamento ajustável.
5. Medir distância e ângulo.

## Data
- Patient: nome, ID, data de nascimento, sexo
- Study: UID, data, descrição, modalidades, nº de acesso, origem (copiado ou referenciado)
- Series: UID, número, descrição, modalidade, orientação, nº de imagens
- Instance: UID, caminho do arquivo, número, posição e orientação da imagem, transfer syntax, frames

Base em `~/Library/Application Support/Kidicom/` (SwiftData para o índice, pasta `Files/` para as cópias). Arquivos referenciados guardam o caminho e, se a pasta sumir, o exame aparece como offline.

## Shape
Janela com sidebar (worklist) e janela de visualização por exame, macOS 26 ou mais novo, Apple Silicon. Dados locais, funciona offline, sem contas, sem conexão com PACS ou servidores DICOM.

## Import
Zips de laboratório trazem estrutura de CD (`DICOMDIR`, pastas como `5WKSINVZ/KUHL4U42`, arquivos sem extensão), mais JPG, PDF de laudo e lixo do macOS (`__MACOSX`, `._*`). O importador reconhece DICOM pelo conteúdo (`DICM` no byte 128, com fallback para dataset sem preâmbulo), ignora o resto e informa quantos arquivos pulou. Amostra real: dossiê pessoal com 19 zips e 33 `DICOMDIR` (fora do repositório, nunca usado como fixture).

## Decoding (decided by the agent)
Parser DICOM próprio em Swift. Decoders próprios para JPEG Lossless (`1.2.840.10008.1.2.4.70`) e RLE. ImageIO do sistema para JPEG baseline e JPEG 2000 (`.4.90/.4.91`). Renderização e volume rendering em Metal. Sem DCMTK. Se o JPEG 2000 de 16 bits falhar no ImageIO, entra OpenJPEG só para esse caso. Formatos medidos na base Horos do usuário: 68% sem compressão, 27% JPEG Lossless, 5% JPEG 2000.

## System hooks
Abrir arquivos e pastas pelo Finder (Abrir com, arrastar para o ícone no Dock). Nada além disso.

## Reference
Horos e OsiriX para comportamento de leitura e atalhos de mouse. Sem clonar a interface.

## Look
Nativo, com a cor de destaque do sistema. Área de imagem sempre preta, com overlays de texto nos cantos (paciente, série, W/L, posição), como os viewers radiológicos.

## Interface
Inglês e português desde a primeira versão (String Catalog).

## Not in version one
- Conexão com PACS, C-FIND, C-MOVE, envio DICOM
- Laudo, anotações persistentes, ROI com estatística, exportação de imagens e vídeo
- Corte do volume 3D, fusão PET/CT, curvas MPR, anonimização, gravação de CD
