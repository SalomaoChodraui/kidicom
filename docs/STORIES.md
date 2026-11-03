# Kidicom: histórias

Fonte: `docs/BRIEF.md`. Páginas de snapshot citadas em `Screens:` são as do modo snapshot do app (`worklist`, `import-sheet`, `viewer-1x1`, `viewer-2x2`, `viewer-mpr`, `viewer-3d`, `viewer-compare`, `settings`).

Dados de teste: base Horos do usuário (`~/Documents/Horos Data.nosync/Horos Data/DATABASE.noindex`, CT, MR, PT com JPEG Lossless e JPEG 2000) e um conjunto público pequeno em `Tests/Fixtures/` (US multiframe, CR/DX, RLE). Zips reais de laboratório: dossiê pessoal do usuário (US, RX, MG, densitometria, RM). Dados de pacientes ficam fora do repositório; testes automatizados usam só os fixtures públicos.

## M1 Núcleo: importar, listar, abrir

### S-001 Ler um arquivo DICOM sem compressão
Como usuário, abro um arquivo DICOM Explicit ou Implicit VR Little Endian e vejo a imagem.
Screens: viewer-1x1
Acceptance:
- [unit] O parser lê Part 10 com e sem preâmbulo, VR explícito e implícito, sequências de tamanho indefinido e o pixel data de 8 e 16 bits, com e sem sinal.
- [unit] Rescale slope/intercept e MONOCHROME1 viram valores corretos (HU em TC).
- [unit] Um arquivo truncado ou que não é DICOM gera erro, sem crash.
Status: done

### S-002 Ler JPEG Lossless, JPEG 2000, JPEG baseline e RLE
Como usuário, abro exames comprimidos como os da minha base Horos.
Depends: S-001
Acceptance:
- [unit] JPEG Lossless (`.4.57`, `.4.70`) decodifica igual ao pixel data de referência, bit a bit.
- [unit] JPEG 2000 (`.4.90`, `.4.91`) de 12 e 16 bits decodifica via OpenJPEG embutido com diferença máxima de 0 em lossless.
- [unit] RLE e JPEG baseline (`.4.50`, US colorido YBR_FULL_422) decodificam.
- [manual] 100 arquivos sorteados da base Horos abrem sem erro.
Status: done

### S-003 Importar por botão + ou arrastar e soltar
Como usuário, clico em + ou arrasto arquivos, pastas ou zips para a worklist e os exames aparecem agrupados por paciente e estudo.
Screens: worklist, import-sheet
Depends: S-001
Acceptance:
- [unit] Pastas são varridas recursivamente; `DICOMDIR` e arquivos sem extensão são reconhecidos pelo conteúdo.
- [unit] Zips são extraídos para uma pasta temporária e importados; JPG, PDF, `__MACOSX` e `._*` são ignorados e contados no resumo da importação.
- [self] Importar 2.000 imagens não trava a interface e mostra progresso.
- [unit] Importar o mesmo exame duas vezes não duplica instâncias (chave: SOP Instance UID).
UX:
- Flow: File > Import… (⌘O), toolbar +, drop files, folders, or zips on the worklist or on the Dock icon -> scan (progress inline) -> Import sheet (S-004) unless a choice is remembered -> progress bar "Importing 120 of 2,000 images" with Cancel -> new studies appear, selected, in Recently Imported
- Surface: open panel for picking; drop target is the whole study list, highlighted while dragging (direct manipulation on a sidebar page)
- States: empty "No Studies" with button "Import…"; scanning "Looking for DICOM files…"; nothing found: inline message "No DICOM images found in the selection." with the skipped count; done: footer "Imported 3 studies, 412 images. Skipped 18 files." for five seconds
- Words: "Import…", tooltip "Import DICOM files, folders, or zips (⌘O)", "Cancel"
- Access: ⌘O, Return in the panel; VoiceOver reads progress as "Importing, 120 of 2,000 images"
Status: done

### S-004 Escolher copiar para a base ou manter no lugar
Como usuário, ao importar, escolho entre copiar os arquivos para a base do Kidicom ou só referenciá-los.
Screens: import-sheet
Depends: S-003
Acceptance:
- [snap] A folha de importação mostra as duas opções, a contagem de arquivos e "Lembrar minha escolha".
- [unit] Zips sempre são copiados (a origem é temporária).
- [self] Um exame referenciado cuja pasta foi removida aparece como offline e não abre.
UX:
- Flow: after the scan -> sheet "Import 2,000 Images" -> pick Copy to Library or Keep in Place (default Copy) -> optional "Always do this" -> Return imports, Escape cancels and nothing changes
- Surface: sheet (one short task that must finish or cancel before going on)
- States: zip in the selection: Keep in Place disabled with "Files from zips are always copied."; studies already in the worklist: "120 images are already in the worklist and will be skipped."
- Words: title "Import 2,000 Images"; radio "Copy to Library" with "Files stay available if the original folder is moved or removed."; radio "Keep in Place" with "Uses no extra disk space. The study goes offline if the files move."; checkbox "Always do this"; buttons "Import" and "Cancel"
- Access: arrow keys move between the two choices, Return imports, Escape cancels; offline studies show a "Offline" label next to the icon, never color alone
Status: done

### S-005 Ver a worklist
Como usuário, vejo uma lista de estudos com paciente, ID, data, modalidade, descrição e nº de imagens, ordenável e com busca.
Screens: worklist
Depends: S-003
Acceptance:
- [snap] Colunas: Paciente, ID, Data do estudo, Modalidade, Descrição, Imagens, Origem.
- [self] O índice sobrevive a reiniciar o app.
- [self] A busca filtra por nome, ID ou descrição enquanto digito.
UX:
- Flow: worklist opens on All Studies -> type in the search field (⌘F) to filter -> click a column header to sort -> double-click or Return opens the study (S-006)
- Surface: sidebar page with a table (a place people come back to)
- States: empty "No Studies" with "Import…"; no search match "No Results for "silva""; long descriptions truncate with a tooltip; offline rows show "Offline" in the Files column
- Words: columns "Patient", "Patient ID", "Study Date", "Modality", "Description", "Images", "Files"; Files values "Library", "In Place", "Offline"; search prompt "Search patient, ID, or description"
- Access: arrow keys move the selection, Return opens, ⌘F focuses search, Delete removes (S-042)
Status: done

### S-006 Abrir um exame no visualizador
Como usuário, dou duplo clique (ou Return) num estudo e ele abre numa janela de visualização com as séries numa faixa lateral.
Screens: viewer-1x1
Depends: S-002, S-005
Acceptance:
- [snap] Faixa de séries com miniatura, descrição e contagem; área de imagem preta com overlays nos quatro cantos.
- [self] A primeira imagem aparece em menos de 300 ms para uma série de 300 cortes de TC.
- [manual] Arrastar uma miniatura para o viewport troca a série.
UX:
- Flow: double-click a row, or select and press Return -> a Viewer window opens for that study on its largest series -> click a thumbnail, or drag it onto the image, to change series -> ⌘W closes
- Surface: new window (self-contained task people keep open beside the worklist)
- States: offline study shows "Study Offline" with the reason; thumbnails show a spinner until decoded
- Words: thumbnail captions "<series> · <n> images"; overlay corners: patient, ID, date | study, series | Im n/N, Pos, Thk | WL WW, Zoom
- Access: Return opens from the worklist; the thumbnail tooltip says "Show <series> (<n> images)"
Status: done

### S-007 Rolar as imagens da série
Como usuário, rolo os cortes com a roda do mouse ou com as setas para cima e para baixo.
Screens: viewer-1x1
Depends: S-006
Acceptance:
- [self] Rolar uma série de 500 cortes mantém 60 fps no M1 base.
- [snap] O overlay mostra "Im 42/300" e a posição do corte em mm.
- [unit] As imagens são ordenadas pela posição projetada na normal do plano, com Instance Number como desempate.
UX:
- Flow: wheel or trackpad scroll, ↑ ↓, Page Up/Down, Home/End move through the series
- Surface: inline in the viewport
- Words: overlay "Im 13/24" and "Pos -30,0 mm"
Status: done

### S-008 Ajustar janela, zoom e pan
Como usuário, arrasto com o botão esquerdo para mudar janela/nível, seguro e arrasto o botão direito para zoom (também pinça ou Option-roda) e arrasto com o botão do meio para pan.
Screens: viewer-1x1
Depends: S-006
Acceptance:
- [snap] O overlay mostra WL/WW atualizados.
- [self] Presets por tecla: 1 Partes moles, 2 Pulmão, 3 Osso, 4 Cérebro, 0 Padrão do arquivo.
- [manual] Duplo clique na imagem reseta janela, zoom e pan.
UX:
- Flow: left-drag sets window/level; right-drag zooms around the click (up in, down out), also pinch or Option-scroll; middle-drag or ⌘-drag pans; keys 1 to 4 apply presets, 0 the file window; double-click resets
- Surface: inline in the viewport
- Words: overlay "WL 40 WW 400" and "Zoom 100%"
Status: done

## M2 Ferramentas de leitura

### S-010 Dividir a tela em até 4
Como usuário, escolho o layout 1x1, 1x2, 2x1 ou 2x2 na barra de ferramentas e cada viewport recebe uma série.
Screens: viewer-2x2
Depends: S-006
Acceptance:
- [snap] O viewport ativo tem borda na cor de destaque.
- [self] As séries são distribuídas na ordem da faixa ao trocar o layout.
UX:
- Flow: toolbar layout control (1, 2 side by side, 2 stacked, 4) -> empty viewports get the next series not shown, skipping scouts -> click a viewport to make it active -> thumbnail click or drag fills the active or target viewport
- Surface: segmented control in the viewer toolbar
- Double-click a viewport in a split layout: it fills the whole image area; Esc or another double-click returns. In a single layout, double-click resets the view
- ⌘W closes the active viewport while several show (MPR and 3D leave their mode first); with one left, ⌘W closes the study window
- Right-click a thumbnail: the series opens beside the others to compare, 1 -> 2 side by side -> 3 side by side -> 2x2; with four open it replaces the active viewport
- Words: "1 Viewport", "2 Side by Side", "3 Side by Side", "2 Stacked", "4 Viewports"; tooltip "Split the image area into up to four viewports"
- Access: the active viewport has an accent outline; the viewer is always dark
Status: done

### S-011 Girar e espelhar a imagem
Como usuário, giro 90° e espelho horizontal ou verticalmente o viewport ativo.
Screens: viewer-1x1
Depends: S-006
Acceptance:
- [snap] Os marcadores de orientação (A, P, R, L, H, F) nas bordas acompanham a rotação.
- [unit] Os marcadores vêm de Image Orientation (Patient).
UX:
- Flow: toolbar Orientation menu (Rotate Right ⌃R, Rotate Left ⌃L, Flip Horizontal H, Flip Vertical V, Reset View ⌘R) on the active viewport; ⌘R resets window, zoom, pan, rotation, and flips
- Surface: toolbar menu (a few related choices tied to one control)
- Words: menu items above; tooltip "Rotate or flip the active viewport (⌃R, ⌃L, H, V); ⌘R resets the view"; edge letters R/L, A/P, H/F, two letters for oblique planes
- Access: flips act on the screen axes, whatever the rotation
Status: done

### S-012 Tocar e pausar cine de ultrassom
Como usuário, aperto espaço para tocar ou pausar um ultrassom multiframe na taxa gravada no arquivo.
Screens: viewer-1x1
Depends: S-006
Acceptance:
- [unit] A taxa vem de Frame Time ou Cine Rate, com 30 fps como padrão.
- [self] O loop toca sem frames perdidos em 60 Hz.
UX:
- Flow: Space or the toolbar Play button plays the active viewport in a loop; Space or Pause stops on the current frame
- Surface: toolbar button and key
- Words: "Play", "Pause"; tooltip "Play the images as a cine (Space)"; overlay "▶ 25 fps" while playing
Status: done

### S-013 Medir distância
Como usuário, escolho a régua e arrasto entre dois pontos para ver a distância em mm.
Screens: viewer-1x1
Depends: S-006
Acceptance:
- [unit] Usa Pixel Spacing; em US, Sequence of Ultrasound Regions; sem calibração, mostra "px".
- [manual] Delete apaga a medida selecionada; as medidas somem ao fechar o exame.
UX:
- Flow: toolbar Distance tool -> press and drag from one point to the other -> label shows mm (px without calibration) -> drag a handle to adjust -> click a measurement to select, Delete removes -> Esc returns to Window/Level
- Surface: tool in the toolbar, drawing on the image
- Words: tools "Window/Level", "Distance", "Angle"; labels "118,2 mm", "4,35 mm", "120 px"
- Access: selected measurement in cyan, others yellow; handles stay editable with any tool
Status: done

### S-014 Medir ângulo
Como usuário, marco três pontos e vejo o ângulo em graus.
Screens: viewer-1x1
Depends: S-013
Acceptance:
- [unit] O ângulo usa o espaçamento real do pixel, com pixels não quadrados.
UX:
- Flow: toolbar Angle tool -> drag the first arm ending at the vertex -> click the end of the second arm (drag to adjust) -> label at the vertex in degrees
- Words: label "90,0°"
Status: done

### S-016 Medir área com o laço
Como usuário, escolho o laço e contorno uma estrutura com o botão esquerdo; ao soltar, o contorno se fecha e mostra a área.
Screens: viewer-ct-measure
Depends: S-013
Acceptance:
- [unit] Área pela fórmula do laço (shoelace) no espaço físico, certa com pixels não quadrados.
- [self] Um contorno de 20 x 20 px em pixels de 5 mm mede 100 cm².
- [self] Arrastar dentro do contorno move o contorno inteiro.
UX:
- Flow: toolbar Area tool (lasso, key O) -> press, trace the outline, release -> it closes, fills lightly, and shows mm² (cm² from 1 cm²; px² without calibration) -> click on or inside it to select, drag to move, Delete removes
- Words: tool "Area"; labels "45,6 mm²", "17,02 cm²", "1200 px²"
Status: done

### S-015 Ver informações DICOM
Como usuário, abro um painel com as tags do arquivo atual.
Screens: viewer-1x1
Depends: S-006
Acceptance:
- [snap] Lista tag, nome, VR e valor, com busca.
UX:
- Flow: toolbar ⓘ or ⌘I opens the DICOM Tags inspector for the image in the active viewport; it follows scrolling; type to filter by tag, name, or value
- Surface: inspector (details of the selection while people keep working)
- Words: "DICOM Tags", columns "Tag", "Name", "VR", "Value"; search prompt "Search tag, name, or value"; sequences show "n items" with indented items
- Access: values are selectable for copying
Status: done

## M3 Reformatação

### S-020 Montar o volume de uma série axial
Como usuário, abro uma série de TC ou RM e o app monta o volume em memória para as reconstruções.
Depends: S-007
Acceptance:
- [unit] Detecta espaçamento irregular e cortes faltando, avisando no overlay.
- [unit] Séries com orientações misturadas não habilitam MPR.
- [self] Um volume de 512x512x600 em 16 bits monta em menos de 2 s.
UX:
- Flow: built when MPR starts; progress "Building volume…"; refusal inline: "This series mixes image orientations and can't be reformatted."
- Words: overlay warnings "n gaps between slices", "Uneven slice spacing"
Status: done

### S-021 Ver MPR axial, coronal e sagital
Como usuário, ativo MPR e vejo três viewports com os três planos e linhas de referência cruzadas.
Screens: viewer-mpr
Depends: S-020, S-010
Acceptance:
- [snap] Cada plano mostra as linhas dos outros dois; clicar move o cruzamento.
- [self] Rolar em um plano atualiza as linhas nos outros a 60 fps.
UX:
- Flow: toolbar MPR toggle on the active series -> three viewports side by side: the acquired plane and two reformats, named Axial, Coronal, Sagittal by their real orientation -> scroll any plane; colored reference lines show the other two -> click (no drag) moves the other planes there -> W/L follows across the three -> MPR toggle again restores the previous layout
- Surface: toolbar toggle; viewports
- Words: "MPR", tooltip "Reformat the active series in three planes (MPR)", "Leave MPR"
- Access: reformats follow reading conventions whatever the acquisition: head up (anterior up in axial), patient right on screen left, anterior left in sagittal
- Oblique: drag a reference line (away from the crossing) to tilt the other two planes around the plane you are in, always perpendicular; the pointer turns into the rotate icon over a line and the move icon over the crossing; drag the crossing to move all three; ⌘R straightens them
Status: done

### S-022 Ligar MIP com espessura ajustável
Como usuário, ativo MIP em qualquer viewport do MPR e ajusto a espessura em mm com um controle deslizante.
Screens: viewer-mpr
Depends: S-021
Acceptance:
- [snap] O overlay mostra "MIP 10 mm".
- [unit] O MIP de espessura igual a um corte é idêntico ao corte original.
UX:
- Flow: toolbar Slab button on an MPR plane -> popover with "Maximum Intensity Projection (MIP)" and Thickness 1 to 50 mm -> the plane updates live; overlay "MIP 20 mm" and "Thk 20,0 mm"
- Surface: popover (a few related choices tied to one control)
Status: done

### S-023 Ver reconstrução 3D com janelamento
Como usuário, abro a visão 3D de uma série axial, giro o volume com o mouse e ajusto a janela.
Screens: viewer-3d
Depends: S-020
Acceptance:
- [self] Volume rendering em Metal acima de 30 fps durante a rotação num volume de 512x512x600.
- [snap] Presets: Osso, Partes moles, Pulmão, Vascular.
- [manual] O arraste com o botão esquerdo gira; Shift + esquerdo ajusta a janela; o direito dá zoom e o da rodinha move, como no 2D.
UX:
- Flow: toolbar 3D toggle on the active series (or the MPR series) -> builds or reuses the volume -> front view, head up, patient right on screen left -> left-drag rotates, Shift-left-drag sets the window, right-drag or wheel zooms, wheel-button drag pans, double-click resets the camera -> palette menu picks Bone, Soft Tissue, Lung, Vascular, Automatic (MR default, from the volume's values), Current Window -> 3D toggle or Esc leaves
- Surface: replaces the image area; toolbar toggle and menu
- Words: "3D", "Leave 3D (Esc)", presets above; hint line "Drag to rotate · Shift-drag: window · Right-drag: zoom · Wheel button: pan"
Status: done

## M4 Comparação

### S-030 Abrir um exame anterior ao lado
Como usuário, no visualizador abro um exame anterior do mesmo paciente num viewport ao lado.
Screens: viewer-compare
Depends: S-010
Acceptance:
- [self] O menu "Anteriores" lista os outros estudos com o mesmo Patient ID, do mais recente ao mais antigo.
- [snap] O overlay de cada viewport mostra a data do estudo.
UX:
- Flow: toolbar Compare menu (badge with the count) lists the patient's other studies, newest first -> choosing one opens its series most like the active one (same modality and plane, closest image count) beside the current images; its series appear in the strip under "Prior · <date>"
- Surface: toolbar menu
- Words: "Compare", "No other studies of this patient", tooltip "Open a prior study of this patient beside the current one, and set what scrolls together"; each viewport shows its own study date
Status: done

### S-031 Sincronizar a rolagem entre exames
Como usuário, rolo um exame e o outro acompanha pela posição anatômica.
Screens: viewer-compare
Depends: S-030
Acceptance:
- [unit] O corte correspondente é o de posição mais próxima no mesmo Frame of Reference ou, se diferente, pela posição relativa.
- [manual] Um botão liga e desliga o sincronismo; com Shift-roda rolo só um lado para ajustar o deslocamento, que fica guardado.
- [self] Janela/nível podem ser sincronizados à parte.
UX:
- Flow: scrolling a viewport moves every visible viewport in a parallel plane to the nearest position; the same frame of reference aligns by absolute position, others by relative position when opened; Shift-scroll or Shift-↑↓ moves one viewport alone and keeps the new offset; Compare menu toggles "Sync Scrolling" (on), "Sync Zoom" (on, zoom and pan), and "Sync Window/Level" (off)
- Words: overlay "Sync Δ 12,5 mm" when an offset is kept
Status: done

## M5 Acabamento

### S-040 Usar o app em inglês ou português
Como usuário, vejo a interface no idioma do sistema, inglês ou português.
Acceptance:
- [self] tools/localize.sh lista zero strings sem tradução.
- [snap] Snapshots em pt-BR e en.
UX:
- English in code, Portuguese (Brazil) in Resources/Localization/Localizable.xcstrings; tools/localize.sh refreshes the catalog from the code and lists any string without a translation; build.sh compiles it into the app
- Words follow docs/GLOSSARY.md (Study = Exame, Viewport = Quadro, Library = Biblioteca)
Status: done

### S-041 Abrir arquivos pelo Finder
Como usuário, arrasto uma pasta para o ícone do Dock ou uso "Abrir com" e ela vai para a importação.
Depends: S-003
Acceptance:
- [manual] O app aceita pastas, `.dcm`, `.zip` e `DICOMDIR`.
UX:
- Flow: drop files, folders, zips, or DICOMDIR on the Dock icon, or Open With > Kidicom in the Finder -> requests in a burst become one Import sheet -> same flow as S-003
- Access: no window activates per file; imports that arrive during another wait their turn
Status: done

### S-042 Apagar um estudo
Como usuário, apago um estudo da worklist; se foi copiado, os arquivos vão para o Lixo.
Screens: worklist
Depends: S-005
Acceptance:
- [self] Arquivos referenciados nunca são apagados, só o índice.
- [self] Confirmação antes de apagar, com ⌘Z para desfazer; remoção definitiva na próxima abertura.
UX:
- Flow: Delete key, or right-click > Delete… -> confirmation "Delete the study of Silva, Maria C?" (setting to skip it) -> the study leaves the worklist at once -> ⌘Z (Edit > Undo Delete Study) brings it back -> at the next launch it is removed; copied files go to the Trash, files kept in place are never touched
- Surface: confirmation dialog (destroys data)
- Words: "Delete…", "Delete", "Cancel", message "Copied files go to the Trash. Files kept in place are not touched. You can undo with ⌘Z."
Status: done

### S-043 Ajustar preferências
Como usuário, defino a pasta da base, a escolha padrão de importação e os presets de janela.
Screens: settings
Acceptance:
- [snap] Abas Geral, Ferramentas, Janelas e Aparência.
UX:
- Tabs: General (When importing: Ask Each Time, Copy to Library, Keep in Place; Ask before deleting a study; Library path with Show in Finder), Tools (a letter per left-button tool: W Window/Level, B Scroll, L Distance, A Angle; refuses keys the viewer uses; Restore Defaults), Windows (WL and WW for presets 1 to 4; Restore Defaults), Appearance (accent color)
- Surface: Settings window (⌘,)
Status: done

### S-044 Ícone e build para o GitHub
Como mantenedor, gero um `.app` assinado e notarizado e publico no GitHub Releases.
Acceptance:
- [manual] O DMG abre no macOS 26 em Apple Silicon sem alerta do Gatekeeper.
Note: tools/release.sh builds, signs, and makes dist/Kidicom-<version>.dmg, and notarizes with NOTARY_PROFILE. Blocked: this Mac has only an Apple Development certificate; a Developer ID Application certificate (Apple Developer Program) and a notary profile are needed for a DMG that opens on other Macs without a warning.
Status: todo

## Dropped
- Conexão com PACS, C-FIND, C-MOVE, envio DICOM
- Laudo e anotações persistentes
- ROI com estatística
- Exportar imagem ou vídeo
- Corte do volume 3D
- Fusão PET/CT
- Anonimização
- Gravação de CD
- Contas, sincronização, analytics
