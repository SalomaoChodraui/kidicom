# Auditoria de uso do Kidicom

Data: 06/11/2026. Escopo: leitura local de exames, biblioteca, importação, viewer 2D, MPR, 3D e Ajustes. Referências: CLAUDE.md, BRIEF.md, STORIES.md, GLOSSARY.md e regras mac-design e ux-design.

## Design plan

Arquétipo: biblioteca com sidebar e janelas de leitura por exame. Navegação: Todos os Exames, Importados Recentemente, modalidades e álbuns. A leitura mantém a imagem como conteúdo principal, com uma faixa recolhível de séries e inspector de tags.

Sensação pretendida: confiança na identificação do exame e rapidez para alternar os modos de leitura. Estados vazios existentes usam ContentUnavailableView; reconstrução mantém progresso inline; comandos indisponíveis continuam visíveis e desabilitados no menu.

Mapa dos comandos novos: Visualizar > Mostrar/Ocultar Séries (⌘⇧S), Layout (⌃⇧1 a ⌃⇧5), Ferramenta (⌃⇧ e tecla configurada em Ajustes), Janela (0 a 4), MPR (⌘⇧M), 3D (⌘⇧D), Tags DICOM (⌘I), Reproduzir/Pausar (⌃⇧Espaço no menu, Espaço com foco na imagem). Os comandos agem sobre o viewer da janela ativa. Os presets usam o número simples também no menu, e um número digitado num campo de texto vai para o campo; os atalhos modificados no menu permitem digitar na busca de tags.

## Achados e tratamento

1. Feito na comparação 2D: overlay do exame anterior usava a descrição do exame atual. Cada viewport passa a mostrar a descrição da série exibida, junto da data já individualizada. Checks distinguem duas descrições para evitar falso positivo com exames de nomes iguais.
2. Feito: faixa de séries fixa consome 184 pt inclusive durante MPR, 3D e leitura de uma imagem. Permitir recolher pelo toolbar ou ⌘⇧S, sem alterar o layout nem a seleção.
3. Feito: menu Visualizar só oferece controle dos overlays. Ferramentas, presets, layouts e reconstruções dependem de ícones e atalhos que precisam ser memorizados. Expor os comandos frequentes no menu, com estado e atalhos.
4. Adiado: toolbar fica congestionada a 1.000 pt e leva controles para overflow. Acesso pelo menu reduz o bloqueio imediato; uma reorganização completa dos grupos requer validar larguras e prioridades por modo.
5. Adiado: botão Comparar não informa visualmente a ausência de anteriores e o clique principal pode não agir. O menu informa a ausência; revisão da ação dividida e dos sincronismos fica para um fluxo de comparação separado.
6. Adiado: atalhos e funções dos segmentos de ferramentas dependem de uma tooltip conjunta. O menu nomeado melhora descoberta; tooltips por segmento dependem de substituir ou adaptar o Picker nativo.
7. Adiado: ajustes de presets WL/WW têm rótulos acessíveis genéricos repetidos. Labels específicos por preset e verificação com VoiceOver devem acompanhar uma revisão dos Ajustes.
8. Adiado: remoção e importação não têm todos os estados de erro/vazio no conjunto padrão de snapshots. Precisam de fixtures e capturas próprias, sem uso de dados reais.
9. Adiado: contexto de miniatura executa comparação imediatamente com botão direito. A interação já consta em S-010; trocar por menu exige decisão sobre compatibilidade do gesto existente.

10. Adiado: Orientação, projeção, paletas 3D e sincronismos ainda dependem de menus do toolbar. A entrega prioriza os comandos mais frequentes; ampliar o mapa restante exige atalhos próprios sem colisão com ferramentas configuráveis.
11. Parcial: a instrumentação existente gerava arquivos sem probes. O viewer agora mede as áreas de séries e imagens, inclusive com faixa recolhida, e mantém o divisor dentro dos 184 pt da faixa. Biblioteca e Ajustes ainda precisam de instrumentação interna para medir cada controle.
12. Feito: o conjunto sintético não produzia uma captura de comparação, porque o roteiro só pedia PT e o seed contém TC, US e CR. O roteiro agora percorre todas as modalidades presentes na sidebar, captura a comparação de TC e leitura sem séries em 2D, MPR e 3D; a captura aguarda a ativação da janela antes de fotografar o chrome.

13. Adiado: a rodada ampliada registrou dois avisos de reentrância do NSTableView ao percorrer modalidades. Os scripts e testes não falharam; falta reproduzir a troca manualmente e isolar a atualização de seleção/tabela antes de alterar a biblioteca.
14. Adiado: metadados do exame anterior em reconstruções MPR e 3D precisam de um vínculo próprio com o exame de origem. A correção desta entrega cobre a comparação 2D e os reformats que já mantêm baseStack; a propagação de identidade para sessões de reconstrução pede checks específicos.

## Evidência

Commits de implementação:

- `52b26cc`: Mostra a descrição correta de cada exame na comparação.
- `0b82c9c`: Permite ampliar a imagem ocultando a faixa de séries.
- `b23d30f`: Permite escolher ferramentas e reconstruções pelo menu Visualizar.
- `b75c431`: Permite conferir comparação e área de leitura nos snapshots.

Verificações da versão final:

| Verificação | Resultado | Evidência |
| --- | --- | --- |
| `./build.sh` | PASS, sem erros nem warnings | `/tmp/kidicom-build.log`, build release de 18,07 s |
| `swift test --scratch-path ~/Library/Developer/Kidicom/test-build` | PASS, 109 testes em 27 suites | `/tmp/kidicom-tests.log` |
| `tools/selftest.sh` | PASS, exit 0, 184 checks | `/tmp/kidicom-selftest.log`, incluindo descrição por exame e preservação da seleção ao recolher séries |
| `tools/grid-lint.sh` | PASS, exit 0 | `/tmp/kidicom-grid.log` |
| `tools/localize.sh` | PASS, 232 strings, nenhuma tradução ausente | `/tmp/kidicom-localize-final.log` |
| `tools/snap.sh` | PASS, exit 0, 54 imagens claras/escuras revisadas | `/tmp/Kidicom-shots`, `/tmp/kidicom-snap-final.log` |
| `swift tools/check-layout.swift /tmp/Kidicom-shots/*-layout.json` | PASS, exit 0, 54 arquivos | `/tmp/kidicom-layout.log`, probes medem as duas áreas do viewer |

Snapshots iniciais: 42 imagens revisadas em `/tmp/Kidicom-shots-before`. Os dados sintéticos disponíveis cobrem TC, US e CR; variantes de RM e PT são omitidas pelo roteiro por falta dessas modalidades no seed. As reconstruções MPR, MIP, oblíquas e 3D são verificadas em TC. Não foram usados dados de pacientes nem o banco real.

O pipeline de carregamento e renderização foi preservado. SeriesStack recebeu apenas dois acessos de metadados para identificar a descrição do exame no overlay, sem mudanças em decode, cache, prefetch, reslice ou montagem de volume.

Revisão visual final: biblioteca, todas as modalidades presentes, importação comum e ZIP, 2D, comparação, 2x2, medidas, rotação, tags, MPR, MIP, oblíquas, 3D e quatro abas de Ajustes. Foram vistas as versões claras e escuras de cada captura. Em uma janela de 1.000 pt, recolher a faixa amplia a área de imagens de 816 para 1.000 pt. As pranchas de revisão estão em `/tmp/kidicom-final-0.jpg` a `/tmp/kidicom-final-6.jpg`.
