# Auditoria de uso do Kidicom

Data: 06/11/2026. Escopo: leitura local de exames, biblioteca, importação, viewer 2D, MPR, 3D e Ajustes. Referências: CLAUDE.md, BRIEF.md, STORIES.md, GLOSSARY.md e regras mac-design e ux-design.

## Design plan

Arquétipo: biblioteca com sidebar e janelas de leitura por exame. Navegação: Todos os Exames, Importados Recentemente, modalidades e álbuns. A leitura mantém a imagem como conteúdo principal, com uma faixa recolhível de séries e inspector de tags.

Sensação pretendida: confiança na identificação do exame e rapidez para alternar os modos de leitura. Estados vazios existentes usam ContentUnavailableView; reconstrução mantém progresso inline; comandos indisponíveis continuam visíveis e desabilitados no menu.

Mapa dos comandos novos: Visualizar > Mostrar/Ocultar Séries (⌘⇧S), Layout (⌃⇧1 a ⌃⇧5), Ferramenta (⌃⇧ e tecla configurada em Ajustes), Janela (⌥⌘0 a ⌥⌘4), MPR (⌘⇧M), 3D (⌘⇧D), Tags DICOM (⌘I), Reproduzir/Pausar (⌃⇧Espaço no menu, Espaço com foco na imagem). Os comandos agem sobre o viewer da janela ativa. As teclas simples das ferramentas e dos presets continuam disponíveis com foco na imagem; os atalhos modificados no menu permitem digitar na busca de tags.

## Achados e tratamento

1. Feito: overlay do exame anterior usava a descrição do exame atual. Cada viewport passa a mostrar a descrição da série exibida, junto da data já individualizada. Checks distinguem duas descrições para evitar falso positivo com exames de nomes iguais.
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
12. Feito: o conjunto sintético não produzia uma captura de comparação, porque o roteiro só pedia PT e o seed contém TC, US e CR. O roteiro agora captura a comparação de TC e leitura sem séries em 2D, MPR e 3D; a captura aguarda a ativação da janela antes de fotografar o chrome.

## Evidência

Preencher após a validação final: snapshots, commits e resultados dos comandos exigidos.
