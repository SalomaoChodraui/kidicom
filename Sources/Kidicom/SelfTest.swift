import AppKit
import SwiftData
import KidicomKit
import Foundation
import simd

/// Self-test for agents: runs the app's real functions on a test store,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/Kidicom-self.store ~/Applications/Kidicom.app/Contents/MacOS/Kidicom --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            let context = model.container.mainContext
            func studies() -> [Study] { (try? context.fetch(FetchDescriptor<Study>())) ?? [] }
            func images() -> [ImageFile] { (try? context.fetch(FetchDescriptor<ImageFile>())) ?? [] }
            let folder = FileManager.default.temporaryDirectory.appending(path: "Kidicom-selftest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }

            // S-003: import a folder with images, a JPG, and macOS junk.
            let urls = (try? SampleStudies.write(to: folder.appending(path: "cd"))) ?? []
            try? Data("jpg".utf8).write(to: folder.appending(path: "cd/foto.jpg"))
            try? Data("x".utf8).write(to: folder.appending(path: "cd/._foto.jpg"))
            check("sample files were written", urls.count == 50)
            let scan = try? ImportScanner.scan([folder.appending(path: "cd")], temporaryRoot: Library.temporary)
            check("the scan finds the images and skips the JPG", scan?.files.count == 50 && scan?.skipped == 1)
            let started = Date.now
            let summary = await model.importer.run(scan ?? ImportScan(), copy: true)
            check("importing 50 images takes under 3 seconds", Date.now.timeIntervalSince(started) < 3, "\(Date.now.timeIntervalSince(started)) s")
            check("4 studies and 50 images were imported", summary.studies == 4 && summary.images == 50, "\(summary)")
            check("studies are grouped by patient and date", studies().count == 4)
            let ct = studies().filter { $0.studyDescription.contains("TORAX") && $0.imageCount == 24 }.max { $0.sortDate < $1.sortDate }
            check("the CT has 24 images in one series", ct?.series.count == 1 && ct?.series.first?.images.count == 24)
            check("the patient name reads well", ct?.displayName == "Silva, Maria C")
            check("copied files are in the Library", images().allSatisfy { $0.isCopied && FileManager.default.fileExists(atPath: $0.fileURL.path) })
            check("a new import is in Recently Imported", ct.map { SidebarItem.recent.includes($0) } ?? false)

            // S-005: search ignores case and accents; Study Date sorts.
            check("search finds by name, ID, and description", ct?.matches("maria") == true && ct?.matches("102938") == true && ct?.matches("tórax") == true && ct?.matches("abdome") == false)
            let byDate = studies().sorted(using: KeyPathComparator(\Study.sortDate, order: .reverse))
            check("the newest study sorts first", byDate.first?.studyDescription == "TC TORAX SEM CONTRASTE" && byDate.first?.studyDate == ct?.studyDate)

            // S-006 to S-008: the viewer opens the CT and responds to scroll and window.
            if let ct {
                let viewer = ViewerModel()
                let opened = Date.now
                viewer.load(ct)
                let viewport = viewer.active
                while viewport?.image == nil && Date.now.timeIntervalSince(opened) < 2 { try? await Task.sleep(for: .milliseconds(10)) }
                check("the first image shows in under 300 ms", viewport?.image != nil && Date.now.timeIntervalSince(opened) < 0.3, "\(Date.now.timeIntervalSince(opened)) s")
                check("the viewer starts in the middle of the series", viewport?.index == 12 && viewport?.count == 24)
                check("slices are ordered head to feet", viewport?.stack?.slices.first?.location == 0 && viewport?.stack?.slices.last?.location == -57.5)
                viewport?.step(1)
                check("scrolling moves one image", viewport?.index == 13)
                viewport?.go(to: 100)
                check("scrolling stops at the last image", viewport?.index == 23)
                check("the window comes from the file", viewport?.effectiveWindow == VOIWindow(center: 40, width: 400))
                viewport?.adjustWindow(dx: 30, dy: 0)
                check("dragging right widens the window", (viewport?.effectiveWindow?.width ?? 0) > 400)
                viewport?.apply(.lung)
                check("key 2 applies the lung window", viewport?.effectiveWindow == VOIWindow(center: -600, width: 1500))
                // Real mouse events into a viewport view in an offscreen window.
                if let viewport {
                    viewport.reset()
                    let view = ViewportNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
                    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
                    window.contentView = view
                    view.viewport = viewport
                    check("the viewport clips the image to its bounds", view.layer?.masksToBounds == true)
                    let number = window.windowNumber
                    func send(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
                        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: 0,
                                           windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    }
                    view.rightMouseDown(with: send(.rightMouseDown, 300, 200))
                    view.rightMouseDragged(with: send(.rightMouseDragged, 300, 280))
                    check("holding the right button and dragging up zooms in", viewport.zoom > 1.5, "zoom \(viewport.zoom)")
                    // Clicked right of center: zooming in slides the image left, so the clicked point stays put.
                    check("the zoom keeps the clicked point in place", viewport.pan.width < 0)
                    let zoomed = viewport.zoom
                    view.rightMouseDragged(with: send(.rightMouseDragged, 300, 150))
                    check("dragging down zooms out", viewport.zoom < zoomed)
                    let index = viewport.index
                    check("the right button no longer scrolls", viewport.index == index)
                    let width = viewport.effectiveWindow?.width ?? 0
                    view.mouseDown(with: send(.leftMouseDown, 200, 200))
                    view.mouseDragged(with: send(.leftMouseDragged, 260, 200))
                    check("left-drag right widens the window", (viewport.effectiveWindow?.width ?? 0) > width)
                    // S-013, S-014: draw a distance and an angle with the mouse.
                    viewport.reset()
                    let height = view.bounds.height
                    if let geometry = viewport.geometry(in: view.bounds.size) {
                        func at(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat) {
                            let v = geometry.toView(CGPoint(x: x, y: y))
                            return (v.x, height - v.y)  // window coordinates grow upward
                        }
                        viewport.tool = .distance
                        var p = at(10, 32); view.mouseDown(with: send(.leftMouseDown, p.0, p.1))
                        p = at(30, 32); view.mouseDragged(with: send(.leftMouseDragged, p.0, p.1))
                        view.mouseUp(with: send(.leftMouseUp, p.0, p.1))
                        let ruler = viewport.measurements.first
                        let mm = ruler.map { Measure.distance($0.points[0], $0.points[1], calibration: viewport.calibration(for: $0)) }
                        check("a distance across 20 pixels of 5 mm reads 100 mm", abs((mm ?? 0) - 100) < 0.5, "\(mm ?? -1)")
                        viewport.tool = .angle
                        p = at(40, 10); view.mouseDown(with: send(.leftMouseDown, p.0, p.1))
                        p = at(40, 30); view.mouseDragged(with: send(.leftMouseDragged, p.0, p.1))
                        view.mouseUp(with: send(.leftMouseUp, p.0, p.1))
                        p = at(60, 30); view.mouseDown(with: send(.leftMouseDown, p.0, p.1))
                        view.mouseUp(with: send(.leftMouseUp, p.0, p.1))
                        let angle = viewport.measurements.last
                        let degrees = angle.flatMap { $0.points.count == 3 ? Measure.angle($0.points[0], vertex: $0.points[1], $0.points[2], calibration: viewport.calibration(for: $0)) : nil }
                        check("an angle drawn as an L reads 90 degrees", viewport.measurements.count == 2 && abs((degrees ?? 0) - 90) < 0.5, "\(degrees ?? -1)")
                        check("the new angle is selected", viewport.selected == angle?.id)
                        // A ruler drawn click to click: the end follows the pointer, the second click sets it.
                        viewport.tool = .distance
                        p = at(10, 50); view.mouseDown(with: send(.leftMouseDown, p.0, p.1))
                        view.mouseUp(with: send(.leftMouseUp, p.0, p.1))
                        check("one click leaves a ruler following the pointer", viewport.placingRuler && viewport.measurements.count == 2)
                        p = at(20, 50); view.mouseMoved(with: send(.mouseMoved, p.0, p.1))
                        let following = viewport.draft.map { abs($0.points[1].x - 20) < 0.5 } ?? false
                        check("the ruler's end follows the pointer", following)
                        p = at(30, 50); view.mouseDown(with: send(.leftMouseDown, p.0, p.1))
                        view.mouseUp(with: send(.leftMouseUp, p.0, p.1))
                        let clicked = viewport.measurements.last
                        let clickedMM = clicked.map { Measure.distance($0.points[0], $0.points[1], calibration: viewport.calibration(for: $0)) }
                        check("a second click ends the ruler at 100 mm", viewport.draft == nil && viewport.measurements.count == 3
                              && clicked?.kind == .distance && abs((clickedMM ?? 0) - 100) < 0.5, "\(clickedMM ?? -1)")
                        viewport.tool = .angle
                        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: number,
                                                            context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!)
                        check("Delete removes the selected measurement", viewport.measurements.count == 2)
                        // Area: a 20 x 20 px outline on 5 mm pixels is 100 x 100 mm = 100 cm².
                        viewport.tool = .area
                        let corners: [(CGFloat, CGFloat)] = [(20, 10), (40, 10), (40, 30), (20, 30), (20, 11)]
                        p = at(corners[0].0, corners[0].1); view.mouseDown(with: send(.leftMouseDown, p.0, p.1))
                        for (k, corner) in corners.enumerated().dropFirst() {
                            let previous = corners[k - 1]
                            for s in 1 ... 10 {
                                let f = CGFloat(s) / 10
                                p = at(previous.0 + (corner.0 - previous.0) * f, previous.1 + (corner.1 - previous.1) * f)
                                view.mouseDragged(with: send(.leftMouseDragged, p.0, p.1))
                            }
                        }
                        view.mouseUp(with: send(.leftMouseUp, p.0, p.1))
                        let outline = viewport.measurements.last
                        let mm2 = outline.map { Measure.area($0.points, calibration: viewport.calibration(for: $0)) } ?? 0
                        check("the lasso closes the outline and reads 100 cm²", outline?.kind == .area && abs(mm2 - 10_000) < 300 && viewport.label(for: outline!).contains("cm²"), "\(mm2)")
                        let before = outline?.points.first
                        p = at(30, 20); view.mouseDown(with: send(.leftMouseDown, p.0, p.1))
                        p = at(35, 20); view.mouseDragged(with: send(.leftMouseDragged, p.0, p.1))
                        view.mouseUp(with: send(.leftMouseUp, p.0, p.1))
                        let after = viewport.measurements.last?.points.first
                        check("dragging inside the outline moves it whole", viewport.measurements.count == 3 && abs((after?.x ?? 0) - (before?.x ?? 0) - 5) < 0.5)
                        viewport.measurements.removeLast()
                        let here = viewport.index
                        viewport.go(to: here == 0 ? 1 : here - 1)
                        check("measurements stay on screen while scrolling", viewport.visibleMeasurements.count == viewport.measurements.count && !viewport.measurements.isEmpty)
                        viewport.go(to: here)
                        viewport.tool = .navigate
                    }
                    // Tool keys: B scroll, W window, L distance; the scroll tool drags through images.
                    func key(_ c: String) -> NSEvent {
                        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: number,
                                         context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
                    }
                    var picked: MeasureTool?
                    view.onTool = { picked = $0; viewport.tool = $0 }
                    view.keyDown(with: key("b"))
                    check("B picks the scroll tool", picked == .scroll)
                    let start = viewport.index
                    view.mouseDown(with: send(.leftMouseDown, 200, 300))
                    view.mouseDragged(with: send(.leftMouseDragged, 200, 288))
                    check("with the scroll tool, dragging down 12 points moves 3 images", viewport.index == min(viewport.count - 1, start + 3), "\(start) -> \(viewport.index)")
                    view.keyDown(with: key("l"))
                    check("L picks the ruler", picked == .distance)
                    view.keyDown(with: key("w"))
                    check("W picks window/level", picked == .navigate)
                    check("a key already used by the viewer is refused", ToolKeys.shared.problem(with: "h", for: .angle) != nil && ToolKeys.shared.problem(with: "l", for: .angle) != nil && ToolKeys.shared.tool(for: "r") == .rotate)
                    // Rotate tool: dragging around the center turns the image by any angle.
                    viewport.reset()
                    viewport.tool = .rotate
                    view.setTool(.rotate)
                    // From the right of the center to straight below it (window y grows up): a quarter turn.
                    view.mouseDown(with: send(.leftMouseDown, 300, 200))
                    for k in 1 ... 9 {
                        let a = -Double(k) / 9 * .pi / 2
                        view.mouseDragged(with: send(.leftMouseDragged, 200 + 100 * cos(a), 200 + 100 * sin(a)))
                    }
                    view.mouseUp(with: send(.leftMouseUp, 200, 100))
                    let turned = viewport.freeAngle * 180 / .pi
                    check("dragging around the center rotates the image freely", abs(abs(turned) - 90) < 1, "\(turned)°")
                    view.mouseDown(with: send(.leftMouseDown, 200, 100))
                    view.mouseDragged(with: send(.leftMouseDragged, 200 + 100 * cos(-.pi / 2 + 0.2), 200 + 100 * sin(-.pi / 2 + 0.2), .shift))
                    let snapped = viewport.freeAngle * 180 / .pi
                    check("Shift snaps the rotation to 15 degrees", abs(snapped / 15 - (snapped / 15).rounded()) < 1e-6, "\(snapped)°")
                    view.mouseUp(with: send(.leftMouseUp, 200, 100))
                    check("the edge letters follow a free rotation", viewport.edges?.top != "A")
                    viewport.tool = .navigate
                    view.setTool(.navigate)

                    // ⌃R / ⌃L rotate, ⌘R resets everything.
                    func key(_ c: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
                        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: number,
                                         context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
                    }
                    viewport.reset()
                    view.keyDown(with: key("r", .control))
                    check("⌃R rotates right", viewport.quarterTurns == 1)
                    view.keyDown(with: key("l", .control))
                    view.keyDown(with: key("l", .control))
                    check("⌃L rotates left", viewport.quarterTurns == 3)
                    viewport.zoom = 2
                    viewport.window = VOIWindow(center: 1, width: 2)
                    window.makeFirstResponder(view)
                    _ = view.performKeyEquivalent(with: key("r", .command))
                    check("⌘R resets window, zoom, and rotation", viewport.quarterTurns == 0 && viewport.freeAngle == 0 && viewport.zoom == 1 && viewport.window == nil)
                    viewport.tool = .navigate
                    let pan = viewport.pan
                    view.otherMouseDown(with: send(.otherMouseDown, 200, 200))
                    view.otherMouseDragged(with: send(.otherMouseDragged, 230, 200))
                    check("holding the wheel button and dragging pans with the pointer", viewport.pan.width == pan.width + 30)
                }
                viewport?.zoom = 3
                viewport?.reset()
                // S-011: rotation and flips move the orientation letters.
                check("axial CT shows R on the left and A on top", viewport?.edges == Orientation.Edges(top: "A", bottom: "P", left: "R", right: "L"))
                viewport?.rotate(clockwise: true)
                check("rotate right puts R on top", viewport?.edges?.top == "R" && viewport?.quarterTurns == 1)
                viewport?.flip(horizontal: true)
                check("flip horizontal after a turn swaps the screen's left and right", viewport?.edges?.left == "A" && viewport?.edges?.right == "P")
                viewport?.rotate(clockwise: false)
                viewport?.rotate(clockwise: false)
                check("rotate left twice ends at three quarter turns", viewport?.quarterTurns == 3)
                viewport?.reset()
                check("reset clears rotation and flips", viewport?.quarterTurns == 0 && viewport?.flipHorizontal == false && viewport?.flipVertical == false)

                // S-015: the tag list of the current image.
                if let url = viewport?.stack?.slices.first?.url {
                    let rows = await TagInspector.load(url)
                    check("the tag list shows Patient Name with its value", rows.contains { $0.name == "Patient Name" && $0.value == "SILVA^MARIA^C" })
                }

                // Right-click on thumbnails adds viewports: 2 side by side, 3 side by side, 2x2.
                if let stack = viewport?.stack {
                    viewer.compare(stack)
                    check("right-click on a thumbnail opens it beside the current one", viewer.layout == .sideBySide && viewer.activeIndex == 1 && viewer.viewports[1].stack === stack)
                    viewer.compare(stack)
                    check("a second right-click shows three side by side", viewer.layout == .three && viewer.visible.count == 3)
                    viewer.compare(stack)
                    check("a third right-click shows four, one per quadrant", viewer.layout == .grid && viewer.activeIndex == 3)
                    viewer.compare(stack)
                    check("with four open, right-click replaces the active one", viewer.layout == .grid)
                    viewer.doubleClick(viewer.viewports[2])
                    check("double-click in a split layout shows that viewport alone", viewer.maximized === viewer.viewports[2] && viewer.activeIndex == 2)
                    viewer.escape()
                    check("Esc returns to the split layout", viewer.maximized == nil && viewer.layout == .grid)
                    viewer.doubleClick(viewer.viewports[1])
                    viewer.doubleClick(viewer.viewports[1])
                    check("a second double-click also returns", viewer.maximized == nil)
                    // ⌘W closes the active viewport while several show.
                    viewer.activate(viewer.viewports[1])
                    let kept = viewer.viewports[2]
                    check("⌘W in a 2x2 closes one viewport", viewer.closeActiveViewport() && viewer.layout == .three && viewer.viewports[1] === kept)
                    _ = viewer.closeActiveViewport()
                    _ = viewer.closeActiveViewport()
                    check("down to one viewport, ⌘W lets the window close", viewer.layout == .single && !viewer.closeActiveViewport())
                    viewer.layout = .single
                }

                await mprChecks(ct)
                await compareChecks(ct, prior: studies().first { $0.patientID == ct.patientID && $0.uid != ct.uid })

                viewer.layout = .grid
                check("the 2x2 layout shows four viewports with a series each", viewer.visible.count == 4 && viewer.visible.allSatisfy { $0.source != nil })
                viewer.activate(viewer.viewports[3])
                check("clicking a viewport makes it active", viewer.activeIndex == 3)
                viewer.layout = .sideBySide
                check("a smaller layout moves the active viewport back into view", viewer.activeIndex == 0 && viewer.visible.count == 2)
                viewer.layout = .single
                check("double-click resets window and zoom", viewport?.effectiveWindow == VOIWindow(center: 40, width: 400) && viewport?.zoom == 1)
            }

            // VOIWindow/level also works on color ultrasound (brightness and contrast).
            if let us = studies().first(where: { $0.modalities == "US" }) {
                let viewer = ViewerModel()
                viewer.load(us)
                let viewport = viewer.active
                let started = Date.now
                while viewport?.image == nil && Date.now.timeIntervalSince(started) < 2 { try? await Task.sleep(for: .milliseconds(10)) }
                let before = viewport?.image.flatMap { $0.dataProvider?.data as Data? }
                viewport?.adjustWindow(dx: -60, dy: 20)
                let after = viewport?.image.flatMap { $0.dataProvider?.data as Data? }
                check("dragging changes the window on color ultrasound", viewport?.window != nil && before != nil && before != after)
                // S-012: cine at the file's frame time (40 ms = 25 fps), looping.
                check("cine speed comes from Frame Time", viewport?.framesPerSecond == 25)
                viewport?.go(to: 0)
                viewport?.play()
                try? await Task.sleep(for: .milliseconds(450))
                let played = viewport?.index ?? 0
                check("playing advances about 25 frames a second and loops", viewport?.isPlaying == true && played != 0, "index \(played)")
                viewport?.togglePlay()
                let stopped = viewport?.index
                try? await Task.sleep(for: .milliseconds(200))
                check("pause stops on the current frame", viewport?.isPlaying == false && viewport?.index == stopped)
                viewport?.apply(.lung)
                check("CT presets leave color images alone", viewport?.effectiveWindow != VOIWindow(center: -600, width: 1500))
            }

            // Sidebar: modality pages and albums.
            if let ct {
                let all = studies()
                check("the CT page lists only CT studies", all.filter { SidebarItem.modality(.ct).includes($0) }.count == 2)
                check("the X-ray page includes the radiograph (CR)", all.contains { $0.modalities == "CR" && SidebarItem.modality(.xray).includes($0) })
                check("no study lands in MR when there is none", !all.contains { SidebarItem.modality(.mr).includes($0) })
                let album = model.newAlbum(named: "Ensino", with: [ct])
                check("a new album holds the chosen study", SidebarItem.album(album.uid).includes(ct) && album.studies.count == 1)
                model.add([ct], to: album)
                check("adding the same study twice keeps one", album.studies.count == 1)
                model.remove([ct], from: album)
                check("removing a study from an album keeps the study", !SidebarItem.album(album.uid).includes(ct) && studies().contains { $0.uid == ct.uid })
                model.add([ct], to: album)
                model.deleteAlbum(album)
                check("deleting an album keeps its studies", studies().contains { $0.uid == ct.uid } && ct.albums.isEmpty)
            }

            // The pointer shows the tool: every cursor symbol exists.
            check("each tool has its own pointer", MeasureTool.allCases.allSatisfy { ToolCursor.cursor(for: $0) !== NSCursor.arrow }
                  && ToolCursor.zoom !== NSCursor.arrow && ToolCursor.rotate !== NSCursor.arrow)

            // Importing the same files again adds nothing.
            let again = await model.importer.run(scan ?? ImportScan(), copy: true)
            check("importing twice does not duplicate images", again.images == 0 && again.duplicates == 50 && images().count == 50)

            // S-004: Keep in Place, then the folder goes away: the study is offline.
            let placeFolder = folder.appending(path: "place")
            let us = urls.first { $0.lastPathComponent == "US-1" }
            try? FileManager.default.createDirectory(at: placeFolder, withIntermediateDirectories: true)
            var record = us.flatMap { try? InstanceRecord(contentsOf: $0) }
            record?.url = placeFolder.appending(path: "US-copy")
            if let us { try? FileManager.default.copyItem(at: us, to: placeFolder.appending(path: "US-copy")) }
            // Give the copy new UIDs by rewriting it as a new sample under a new study.
            let rewritten = rewriteAsNewStudy(placeFolder.appending(path: "US-copy"))
            let placeScan = try? ImportScanner.scan([placeFolder], temporaryRoot: Library.temporary)
            let kept = await model.importer.run(placeScan ?? ImportScan(), copy: false)
            check("Keep in Place imports without copying", rewritten && kept.images == 1)
            let keptStudy = studies().first { !$0.isCopied }
            check("a Keep in Place study is online while its files exist", keptStudy?.isOffline == false)
            try? FileManager.default.removeItem(at: placeFolder)
            check("a Keep in Place study goes offline when its folder is removed", keptStudy?.isOffline == true)

            // Zip imports are always copied.
            let zip = folder.appending(path: "exame.zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", folder.appending(path: "cd").path, zip.path]
            try? ditto.run(); ditto.waitUntilExit()
            let zipScan = try? ImportScanner.scan([zip], temporaryRoot: Library.temporary)
            check("a zip is recognized as an archive", zipScan?.containsArchives == true && zipScan?.files.count == 50)

            // S-041: open requests in a burst become one import.
            model.importer.gather([folder.appending(path: "cd/CT-1-1")])
            model.importer.gather([folder.appending(path: "cd/CT-1-2")])
            check("a burst of open requests waits to be gathered", model.importer.phase != .confirm && model.importer.phase != .scanning)
            try? await Task.sleep(for: .milliseconds(700))
            check("then shows one Import sheet for all of them", model.importer.phase == .confirm && model.importer.pendingCount == 2,
                  "\(model.importer.phase) \(model.importer.pendingCount)")
            model.importer.cancel()

            // Library location: move copied files to another folder and back.
            let copiedCount = images().filter(\.isCopied).count
            let external = folder.appending(path: "disk", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let moved = Library.destination(for: external)
            check("a picked folder gets a Kidicom Library inside it", moved.lastPathComponent == "Kidicom Library" && moved.deletingLastPathComponent().path == external.path)
            check("folders in iCloud Drive are refused", Library.isInICloud(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/x")))
            let oldFiles = Library.root.appending(path: "Files")
            var movedOK = true
            do { try await Library.move(to: moved) { _, _ in } } catch { movedOK = false }
            check("the Library moves to the picked folder", movedOK && Library.root.path == moved.path)
            check("every copied image opens from the new folder", copiedCount > 0 && images().filter(\.isCopied).allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
            check("the old copies are gone", !FileManager.default.fileExists(atPath: oldFiles.path))
            try? FileManager.default.moveItem(at: external, to: folder.appending(path: "unplugged"))
            check("copied studies go offline while the disk is missing", !Library.isAvailable && studies().filter(\.isCopied).allSatisfy(\.isOffline))
            let blocked = await model.importer.run(ImportScan(), copy: true)
            check("imports that copy are refused while the disk is missing", blocked.images == 0 && { if case .failed = model.importer.phase { true } else { false } }())
            model.importer.dismissMessage()
            try? FileManager.default.moveItem(at: folder.appending(path: "unplugged"), to: external)
            check("they come back when the disk returns", Library.isAvailable && studies().filter(\.isCopied).allSatisfy { !$0.isOffline })
            var backOK = true
            do { try await Library.move(to: Library.destination(for: nil)) { _, _ in } } catch { backOK = false }
            check("Use Default brings the Library back", backOK && Library.customRoot == nil && images().filter(\.isCopied).allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })

            // S-042: delete hides at once, Undo brings it back, the next launch purges.
            if let ct {
                let undo = UndoManager()
                model.trash([ct], undoManager: undo)
                check("a deleted study leaves the worklist", !SidebarItem.all.includes(ct))
                undo.undo()
                check("Undo brings the study back", SidebarItem.all.includes(ct))
                model.trash([ct], undoManager: undo)
                let libraryFolder = ct.series.first?.images.first?.fileURL.deletingLastPathComponent()
                model.purgeTrash()
                check("the next launch removes it and its images", images().count == 27 && studies().allSatisfy { $0.studyUID != "1.2.826.0.1.3680043.10.1.1" })
                check("copied files of a deleted study go to the Trash", libraryFolder.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false)
            }

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    static func mprChecks(_ ct: Study) async {
        // S-020 to S-022: MPR from the 24-slice CT.
        let viewer = ViewerModel()
        viewer.load(ct)
        // Plane picker: the axial CT shown coronal and sagittal in one viewport, then back.
        check("an axial CT starts axial and can change plane", viewer.activePlane == .axial && viewer.canChangePlane)
        await viewer.show(plane: .coronal)
        check("Coronal reformats the active viewport", viewer.activePlane == .coronal && viewer.active?.reformatBase != nil && viewer.layout == .single)
        check("the coronal plane walks front to back through the volume", (viewer.active?.count ?? 0) > 1)
        await viewer.show(plane: .sagittal)
        check("Sagittal reformats the active viewport", viewer.activePlane == .sagittal)
        await viewer.show(plane: .axial)
        check("Axial brings back the series itself", viewer.activePlane == .axial && viewer.active?.stack != nil && viewer.active?.reformatBase == nil)
        // Slab from the toolbar: a series of files becomes a reformat of its own plane, on the same slice.
        let sliceBefore = viewer.active?.location
        await viewer.setSlab(mode: .mip, mm: 10)
        check("MIP turns the axial series into a 10 mm axial slab", viewer.activePlane == .axial && viewer.activeSlab.mode == .mip && viewer.activeSlab.mm == 10)
        check("the slab stays on the slice that was shown", abs((viewer.active?.location ?? .infinity) - (sliceBefore ?? 0)) < 3, "\(String(describing: sliceBefore)) -> \(String(describing: viewer.active?.location))")
        await viewer.setSlab(mode: .minip, mm: 20)
        check("MinIP and thickness change the slab", viewer.activeSlab.mode == .minip && viewer.activeSlab.mm == 20)
        await viewer.show(plane: .coronal)
        check("changing plane keeps the slab", viewer.activePlane == .coronal && viewer.activeSlab.mode == .minip && viewer.activeSlab.mm == 20)
        await viewer.setSlab(mode: .single, mm: 20)
        await viewer.show(plane: .axial)
        check("Thin and Axial bring back the series itself", viewer.active?.stack != nil && viewer.activeSlab.mode == .single)
        await viewer.enterMPR()
        let planes = viewer.mpr?.sources.map(\.title) ?? []
        check("MPR builds a 64x64x24 volume", viewer.mpr?.volume.width == 64 && viewer.mpr?.volume.depth == 24, "\(String(describing: viewer.mprMessage))")
        check("MPR shows axial, coronal, and sagittal side by side", viewer.layout == .three && viewer.mpr?.sources.map({ PatientPlane(orientation: $0.orientation(0)) }) == [.axial, .coronal, .sagittal], "\(planes)")
        let axial = viewer.viewports[0], coronal = viewer.viewports[1], sagittal = viewer.viewports[2]
        let started = Date.now
        while coronal.image == nil && Date.now.timeIntervalSince(started) < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        check("the coronal reformat is square-pixel: 64 wide, 57.5 mm in 13 rows of 5 mm", coronal.slice?.width == 64 && coronal.slice?.height == 13, "\(coronal.slice?.width ?? 0)x\(coronal.slice?.height ?? 0)")
        check("coronal shows head at the top", coronal.edges?.top == "H" && coronal.edges?.left == "R")
        viewer.click(at: CGPoint(x: 10, y: 0), in: coronal)
        check("clicking the top row of the coronal moves the axial to the top slice", axial.index == 23, "\(axial.index)")
        let sagittalAt = (sagittal.source as? ReformatSource).map { simd_dot($0.volumePoint(SIMD2(0, 0), at: sagittal.index), SIMD3(1, 0, 0)) }
        check("the same click moves the sagittal to column 10 (50 mm)", sagittalAt.map { abs($0 - 50) < 0.01 } ?? false, "\(sagittalAt ?? -1)")

        // Oblique: drag the coronal's line in the axial plane to tilt the other two planes.
        if let session = viewer.mpr, let axialSource = axial.source as? ReformatSource, let coronalSource = coronal.source as? ReformatSource {
            let c = axialSource.canvasPoint(session.frame.center, at: axial.index)
            let d = ViewerModel.lineDirection(of: coronalSource, in: axialSource)
            let onLine = CGPoint(x: c.x + d.x * 20, y: c.y + d.y * 20)
            let grabbed = viewer.mprBegin(at: onLine, in: axial, scale: 4)
            check("pressing on a reference line grabs it to tilt", { if case .rotate = grabbed { true } else { false } }())
            // Turn 30 degrees around the crossing.
            let turned = CGPoint(x: c.x + 20 * cos(atan2(d.y, d.x) + .pi / 6), y: c.y + 20 * sin(atan2(d.y, d.x) + .pi / 6))
            // Several moves in a row, like a real drag: the other planes never go blank.
            var blank = false
            for step in 1 ... 6 {
                let a = atan2(d.y, d.x) + .pi / 6 * Double(step) / 6
                viewer.mprDragged(to: CGPoint(x: c.x + 20 * cos(a), y: c.y + 20 * sin(a)), in: axial)
                if coronal.image == nil || sagittal.image == nil { blank = true }
                try? await Task.sleep(for: .milliseconds(3))
            }
            check("while tilting, the other planes keep a picture", !blank)
            viewer.mprDragged(to: turned, in: axial)
            viewer.mprEnded()
            let n = session.frame.planes.map(\.normal)
            check("tilting keeps the three planes perpendicular", abs(simd_dot(n[0], n[1])) < 1e-9 && abs(simd_dot(n[1], n[2])) < 1e-9 && abs(simd_dot(n[0], n[2])) < 1e-9)
            let tilt = acos(abs(simd_dot(n[1], SIMD3(0, 1, 0)))) * 180 / .pi
            check("the coronal plane turned 30 degrees", abs(tilt - 30) < 0.5, "\(tilt)")
            check("the axial plane itself did not move", abs(simd_dot(n[0], SIMD3(0, 0, 1)) - 1) < 1e-9)
            check("a tilted plane is named Oblique", coronalSource.title == ReformatSource.name(.oblique) || PatientPlane(orientation: coronalSource.orientation(0)) != .oblique)
            let center = session.frame.center
            check("pressing on the crossing moves the planes", { if case .move = viewer.mprBegin(at: CGPoint(x: c.x, y: c.y), in: axial, scale: 4) { true } else { false } }())
            viewer.mprDragged(to: CGPoint(x: c.x + 5, y: c.y), in: axial)
            viewer.mprEnded()
            check("dragging the crossing moves the center in the axial plane", simd_length(session.frame.center - center) > 1 && abs(session.frame.center.z - center.z) < 1e-9)
            axial.reset()
            check("⌘R straightens the planes", !session.frame.isTilted)
            let waited = Date.now
            while viewer.viewports.prefix(3).contains(where: { $0.slice == nil || $0.refreshing }) && Date.now.timeIntervalSince(waited) < 2 {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        axial.adjustWindow(dx: 40, dy: 0)
        check("window/level follows across the three planes", coronal.window == axial.window && sagittal.window == axial.window && axial.window != nil)
        if let source = coronal.source as? ReformatSource {
            let plain = brightest(coronal.slice)
            source.setSlab(40, mode: .mip)
            coronal.reload()
            let started = Date.now
            while coronal.slice == nil && Date.now.timeIntervalSince(started) < 2 { try? await Task.sleep(for: .milliseconds(10)) }
            let mip = brightest(coronal.slice)
            check("a 40 mm MIP is at least as bright as the single plane", mip >= plain && source.mode == .mip)
        }
        // S-023: 3D of the same volume, rendered offscreen.
        if let volume = viewer.mpr?.volume, let session = VolumeSession(volume: volume, title: "CT", window: VOIWindow(center: 40, width: 400), modality: "CT") {
            func lit(_ image: CGImage?) -> Int {
                guard let data = image?.dataProvider?.data as Data? else { return -1 }
                return stride(from: 0, to: data.count, by: 4).filter { data[$0] > 20 || data[$0 + 1] > 20 }.count
            }
            func bytes(_ image: CGImage?) -> Data? { image?.dataProvider?.data as Data? }
            session.renderer.camera = session.camera
            let front = session.renderer.renderImage(width: 96, height: 96)
            check("3D renders the CT with the bone preset", session.camera.preset == .bone && lit(front) > 50, "\(lit(front)) lit pixels")
            session.rotate(dx: 157, dy: 0)
            session.renderer.camera = session.camera
            check("dragging rotates the 3D view", bytes(session.renderer.renderImage(width: 96, height: 96)) != bytes(front))
            // Real mouse events: Shift-drag sets the window; a plain drag rotates.
            let view = VolumeMTKView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), device: session.renderer.device)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = view
            view.session = session
            let number = window.windowNumber
            func send(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: 0,
                                   windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let before = session.camera.window
            let turned = session.camera.rotation
            view.mouseDown(with: send(.leftMouseDown, 100, 100, .shift))
            view.mouseDragged(with: send(.leftMouseDragged, 160, 100, .shift))
            check("Shift-drag in 3D widens the window", session.camera.window.width > before.width, "\(before.width) -> \(session.camera.window.width)")
            check("Shift-drag in 3D does not rotate", session.camera.rotation == turned)
            let rotationBefore = session.camera.rotation
            view.mouseDown(with: send(.leftMouseDown, 100, 100))
            view.mouseDragged(with: send(.leftMouseDragged, 130, 100))
            check("a plain drag in 3D rotates", session.camera.rotation != rotationBefore)
            // With the Window/Level tool, a plain drag sets the window and Shift-drag rotates.
            view.toolWindows = true
            let toolBefore = session.camera.window
            let toolRotation = session.camera.rotation
            view.mouseDown(with: send(.leftMouseDown, 100, 100))
            view.mouseDragged(with: send(.leftMouseDragged, 100, 140))
            check("with the Window/Level tool a plain drag in 3D sets the window", session.camera.window != toolBefore && session.camera.rotation == toolRotation)
            view.mouseDown(with: send(.leftMouseDown, 100, 100, .shift))
            view.mouseDragged(with: send(.leftMouseDragged, 130, 100, .shift))
            check("with the Window/Level tool Shift-drag in 3D rotates", session.camera.rotation != toolRotation)
            view.toolWindows = false
            session.apply(.softTissue)
            session.renderer.camera = session.camera
            check("the soft tissue preset shows more of the body than bone", lit(session.renderer.renderImage(width: 96, height: 96)) > lit(front))
        } else {
            check("3D renders the CT with the bone preset", false, "no Metal renderer")
        }
        // The 3D view opens on Rotate, follows the toolbar tool, and gives the 2D tool back.
        viewer.tool = .distance
        await viewer.enter3D()
        check("3D opens with Scroll, which turns the volume", viewer.volume3D?.tool == .scroll && viewer.tool == .scroll)
        viewer.tool = .navigate
        check("picking Window/Level reaches the 3D view", viewer.volume3D?.tool == .navigate)
        viewer.escape()
        check("leaving 3D brings back the 2D tool", viewer.volume3D == nil && viewer.tool == .distance)
        viewer.tool = .navigate
        viewer.exitMPR()
        check("leaving MPR restores the previous layout and series", viewer.mpr == nil && viewer.layout == .single && viewer.viewports[0].stack != nil)

    }

    static func compareChecks(_ ct: Study, prior: Study?) async {
        guard let prior else { check("the sample CT has a prior", false); return }
        let viewer = ViewerModel()
        viewer.load(ct)
        let current = viewer.viewports[0]
        current.go(to: 10)
        viewer.togglePrior(prior)
        check("a date in the strip shows that study's series", viewer.expandedPriors.contains(prior.uid) && viewer.priors.first?.stacks.count == 1 && viewer.layout == .single)
        viewer.togglePrior(prior)
        check("clicking the date again hides them", !viewer.expandedPriors.contains(prior.uid))
        viewer.openPrior(prior)
        let other = viewer.viewports[1]
        check("a prior opens beside the current study", viewer.layout == .sideBySide && other.stack?.studyUID == prior.uid)
        check("the prior starts at the same relative position", other.index == 10)
        current.step(3)
        check("scrolling the current study moves the prior with it", other.index == 13)
        other.stepAlone(2)
        check("Shift-scroll moves only the prior", other.index == 15 && current.index == 13)
        current.step(-1)
        check("after Shift-scroll the two keep the new offset", other.index == 14 && current.index == 12, "\(other.index)")
        current.zoom = 1.6
        current.pan = CGSize(width: 20, height: -12)
        check("Sync Zoom copies zoom and pan to the prior", other.zoom == 1.6 && other.pan == CGSize(width: 20, height: -12))
        viewer.syncZoom = false
        current.zoom = 2
        check("with Sync Zoom off the prior keeps its zoom", other.zoom == 1.6)
        viewer.syncScroll = false
        current.step(-2)
        check("with Sync Scrolling off the prior stays put", other.index == 14)
        viewer.syncWindowLevel = true
        let started = Date.now
        while current.slice == nil && Date.now.timeIntervalSince(started) < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        current.adjustWindow(dx: 50, dy: 0)
        check("Sync Window/Level copies the window to the prior", other.window == current.window && current.window != nil)
    }

    private static func brightest(_ slice: DecodedSlice?) -> Float {
        guard let slice, case .grayscale(let values) = slice.frame else { return 0 }
        return values.max() ?? 0
    }

    /// Gives a copied file a new Study, Series, and SOP Instance UID.
    private static func rewriteAsNewStudy(_ url: URL) -> Bool {
        guard var data = try? Data(contentsOf: url) else { return false }
        let old = Data("1.2.826.0.1.3680043.10.1.3".utf8)
        let new = Data("1.2.826.0.1.3680043.10.1.8".utf8)
        var replaced = false
        while let range = data.range(of: old) { data.replaceSubrange(range, with: new); replaced = true }
        return replaced && (try? data.write(to: url)) != nil
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
