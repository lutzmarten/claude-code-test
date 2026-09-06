#!/bin/bash
# ============================================================
# build_usb_sync_app.sh  –  USBSync v7.0
# Echte Checkboxen via Swift-UI + Python Sync-Engine
# ============================================================

APP_NAME="USBSync"
DEST="$HOME/Desktop/${APP_NAME}.app"

echo "Erstelle ${APP_NAME}.app ..."
rm -rf "${DEST}"
mkdir -p "${DEST}/Contents/MacOS"
mkdir -p "${DEST}/Contents/Resources"

# ============================================================
# 1) Info.plist
# ============================================================
cat > "${DEST}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>USBSync</string>
  <key>CFBundleDisplayName</key>     <string>USB Sync Tool</string>
  <key>CFBundleIdentifier</key>      <string>de.usbsync.app</string>
  <key>CFBundleVersion</key>         <string>7.0</string>
  <key>CFBundleShortVersionString</key> <string>7.0</string>
  <key>CFBundleExecutable</key>      <string>USBSync</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>LSMinimumSystemVersion</key>  <string>12.0</string>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

# ============================================================
# 2) Python Sync-Engine
# ============================================================
cat > "${DEST}/Contents/Resources/usb_sync_engine.py" << 'PYEOF'
#!/usr/bin/env python3
import os, sys, shutil, datetime, logging, unicodedata

def setup_logger(usb_path, opt_v):
    logger = logging.getLogger("USBSync")
    logger.setLevel(logging.DEBUG)
    fmt = logging.Formatter("%(asctime)s  %(levelname)-8s  %(message)s",
                            datefmt="%Y-%m-%d %H:%M:%S")
    ch = logging.StreamHandler(sys.stdout)
    ch.setFormatter(fmt)
    logger.addHandler(ch)
    if opt_v:
        parts = usb_path.split("/")
        usb_root = "/" + "/".join(parts[1:3]) if len(parts) >= 3 else usb_path
        ts = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        log_path = os.path.join(usb_root, f"USBSync_Log_{ts}.txt")
        try:
            fh = logging.FileHandler(log_path, encoding="utf-8")
            fh.setFormatter(fmt)
            logger.addHandler(fh)
            logger.info(f"Log-Datei: {log_path}")
        except Exception as e:
            logger.warning(f"Log konnte nicht erstellt werden: {e}")
    return logger

def norm(name):
    return unicodedata.normalize("NFC", name).lower()

def find_folders(mac_root, target_name):
    target_norm = norm(target_name)
    found = []
    queue = [mac_root]
    while queue:
        current = queue.pop(0)
        try:
            entries = sorted(os.scandir(current), key=lambda e: e.name.lower())
        except (PermissionError, OSError):
            continue
        for entry in entries:
            if not entry.is_dir(follow_symlinks=False):
                continue
            if norm(entry.name) == target_norm:
                found.append(entry.path)
            # Auch bei einem Treffer weiter absteigen: ein gleichnamiger
            # Ordner kann tiefer im Baum erneut vorkommen und wurde bisher
            # uebersehen.
            queue.append(entry.path)
    return found

def copy_tree(src, dst, opt_e, opt_l, opt_newer, logger, stats):
    try:
        os.makedirs(dst, exist_ok=True)
    except Exception as e:
        logger.error(f"FEHLER Ordner erstellen {dst}: {e}")
        stats["errors"] += 1
        return
    try:
        entries = sorted(os.scandir(src), key=lambda e: e.name.lower())
    except (PermissionError, OSError) as e:
        logger.error(f"Kein Lesezugriff: {src} ({e})")
        stats["errors"] += 1
        return
    for entry in entries:
        if entry.name.startswith("."):
            continue
        s = entry.path
        d = os.path.join(dst, entry.name)
        if entry.is_dir(follow_symlinks=False):
            if not os.path.isdir(d):
                logger.info(f"ORDNER ERSTELLT: {d}")
                stats["dirs_created"] = stats.get("dirs_created", 0) + 1
            copy_tree(s, d, opt_e, opt_l, opt_newer, logger, stats)
        else:
            exists = os.path.exists(d)
            # opt_newer: nur ueberspringen wenn die USB-Datei nicht neuer ist
            # UND beide gleich gross sind. Bei abweichender Groesse hat sich
            # der Inhalt geaendert -> trotzdem kopieren (mtime allein reicht
            # als Vergleich nicht aus).
            if exists and opt_newer:
                src_st_cmp = os.stat(s)
                dst_st_cmp = os.stat(d)
                same_size = src_st_cmp.st_size == dst_st_cmp.st_size
                if src_st_cmp.st_mtime <= dst_st_cmp.st_mtime and same_size:
                    import datetime as dt
                    src_ts = dt.datetime.fromtimestamp(src_st_cmp.st_mtime).strftime("%Y-%m-%d %H:%M")
                    dst_ts = dt.datetime.fromtimestamp(dst_st_cmp.st_mtime).strftime("%Y-%m-%d %H:%M")
                    logger.info(f"  ÄLTER/GLEICH -- uebersprungen: {entry.name}  (USB:{src_ts} <= Mac:{dst_ts}, gleiche Groesse)")
                    stats["older"] = stats.get("older", 0) + 1
                    stats.setdefault("older_files", []).append(entry.name)
                    print(f"OLDER:{entry.name}", flush=True)
                    continue
            if exists and not opt_e:
                logger.info(f"  ÜBERSPRUNGEN (vorhanden): {d}")
                stats["skipped"] += 1
            else:
                try:
                    # Datei kopieren: copy() statt copy2() vermeidet
                    # problematische Extended Attributes (xattr) die auf macOS
                    # Backslashes in Dateinamen verursachen koennen
                    src_clean = os.path.normpath(s)
                    dst_clean = os.path.normpath(d)
                    shutil.copy(src_clean, dst_clean)
                    # Nur Zeitstempel uebertragen, keine xattr
                    src_stat = os.stat(src_clean)
                    os.utime(dst_clean, (src_stat.st_atime, src_stat.st_mtime))
                    if exists:
                        logger.info(f"  ERSETZT: {dst_clean}")
                        stats["replaced"] = stats.get("replaced", 0) + 1
                    else:
                        logger.info(f"  KOPIERT: {dst_clean}")
                        stats["copied"] += 1
                    if opt_l:
                        try:
                            # Quelle nur loeschen wenn die Kopie nachweislich
                            # am Ziel liegt und exakt gleich gross ist.
                            if (os.path.exists(dst_clean) and
                                    os.path.getsize(dst_clean) == os.path.getsize(src_clean)):
                                os.remove(s)
                                logger.info(f"  GELÖSCHT (USB): {s}")
                                stats["deleted"] += 1
                            else:
                                logger.error(f"  NICHT GELÖSCHT (Kopie nicht verifiziert): {s}")
                                stats["errors"] += 1
                        except Exception as e:
                            logger.error(f"  FEHLER Löschen {s}: {e}")
                            stats["errors"] += 1
                except Exception as e:
                    logger.error(f"  FEHLER Kopieren {s}: {e}")
                    stats["errors"] += 1
    if opt_l:
        for dirpath, dirnames, filenames in os.walk(src, topdown=False):
            if dirpath == src:
                continue
            if not os.listdir(dirpath):
                try:
                    os.rmdir(dirpath)
                    logger.info(f"ORDNER GELÖSCHT (USB): {dirpath}")
                    stats["deleted"] += 1
                except Exception as e:
                    logger.error(f"FEHLER Ordner löschen {dirpath}: {e}")

def sync(usb_path, mac_path, opt_e, opt_v, opt_l, opt_n=False, opt_newer=False):
    usb_path = os.path.normpath(usb_path)
    mac_path = os.path.normpath(mac_path)
    logger = setup_logger(usb_path, opt_v)
    stats = {"copied": 0, "replaced": 0, "skipped": 0,
             "deleted": 0, "dirs_created": 0, "errors": 0,
             "older": 0, "older_files": []}

    if not os.path.isdir(usb_path):
        logger.error(f"USB-Pfad nicht gefunden: {usb_path}")
        print("RESULT:0:0:0:0:1", flush=True); return
    if not os.path.isdir(mac_path):
        logger.error(f"Mac-Pfad nicht gefunden: {mac_path}")
        print("RESULT:0:0:0:0:1", flush=True); return

    logger.info("=== USB Sync gestartet ===")
    logger.info(f"USB: {usb_path}")
    logger.info(f"MAC: {mac_path}")
    logger.info(f"Optionen: E={opt_e} V={opt_v} L={opt_l} N={opt_n} NUR_NEUER={opt_newer}")

    total_files = sum(len(files) for _, _, files in os.walk(usb_path))
    print(f"TOTAL:{total_files}", flush=True)
    logger.info(f"Dateien gesamt: {total_files}")

    try:
        usb_entries = sorted(os.scandir(usb_path), key=lambda e: e.name.lower())
    except (PermissionError, OSError) as e:
        logger.error(f"Kann USB-Pfad nicht lesen: {e}")
        print("RESULT:0:0:0:0:1", flush=True); return

    not_found = []
    reported  = set()

    for entry in usb_entries:
        name = entry.name
        if name.startswith("."):
            continue

        if entry.is_dir(follow_symlinks=False):
            logger.info(f"")
            logger.info(f"--- Suche Ordner: '{name}' ---")
            print(f"SEARCHING:{name}", flush=True)
            targets = find_folders(mac_path, name)

            if targets:
                if len(targets) > 1 and os.environ.get("USBSYNC_MULTI") != "1":
                    # Mehrdeutig: bisher wurde der USB-Ordner in JEDEN
                    # gleichnamigen Mac-Ordner kopiert -- bei Allerweltsnamen
                    # ("Bilder", "Dokumente") landet der Inhalt so an vielen
                    # Stellen. Jetzt: nur der flachste Treffer wird
                    # synchronisiert, der Rest wird protokolliert.
                    # USBSYNC_MULTI=1 stellt das alte Verhalten wieder her.
                    targets.sort(key=lambda p: (p.count(os.sep), len(p), p.lower()))
                    logger.warning(f"  MEHRDEUTIG: '{name}' {len(targets)}x im Zielbaum gefunden")
                    logger.warning(f"    -> synchronisiert wird nur: {targets[0]}")
                    for ignored in targets[1:]:
                        logger.warning(f"    -> ignoriert: {ignored}")
                    print(f"AMBIG:{name}:{len(targets)}", flush=True)
                    targets = targets[:1]
                for dst in targets:
                    logger.info(f"  GEFUNDEN: {dst}")
                    print(f"SYNCING:{name}", flush=True)
                    copy_tree(entry.path, dst, opt_e, opt_l, opt_newer, logger, stats)
            else:
                if opt_n:
                    dst = os.path.join(mac_path, name)
                    logger.info(f"  NICHT GEFUNDEN -- wird in Mac-Ziel kopiert: '{name}'")
                    print(f"NOTFOUND_COPIED:{name}", flush=True)
                    copy_tree(entry.path, dst, opt_e, opt_l, opt_newer, logger, stats)
                else:
                    logger.warning(f"  NICHT GEFUNDEN -- uebersprungen: '{name}'")
                    print(f"NOTFOUND:{name}", flush=True)
                    not_found.append(name)

        else:
            if name in reported:
                continue
            reported.add(name)
            if opt_n:
                dst = os.path.join(mac_path, name)
                exists = os.path.exists(dst)
                if exists and not opt_e:
                    logger.info(f"  ÜBERSPRUNGEN (vorhanden): {dst}")
                    stats["skipped"] += 1
                else:
                    # Alters-Check fuer Root-Dateien: nur ueberspringen wenn
                    # nicht neuer UND gleich gross (siehe copy_tree).
                    if exists and opt_newer:
                        import datetime as dt
                        src_st_cmp = os.stat(entry.path)
                        dst_st_cmp = os.stat(dst)
                        same_size = src_st_cmp.st_size == dst_st_cmp.st_size
                        if src_st_cmp.st_mtime <= dst_st_cmp.st_mtime and same_size:
                            src_ts = dt.datetime.fromtimestamp(src_st_cmp.st_mtime).strftime("%Y-%m-%d %H:%M")
                            dst_ts = dt.datetime.fromtimestamp(dst_st_cmp.st_mtime).strftime("%Y-%m-%d %H:%M")
                            logger.info(f"  ÄLTER/GLEICH -- uebersprungen: {name}  (USB:{src_ts} <= Mac:{dst_ts}, gleiche Groesse)")
                            stats["older"] = stats.get("older", 0) + 1
                            stats.setdefault("older_files", []).append(name)
                            print(f"OLDER:{name}", flush=True)
                            continue
                    try:
                        src_p = os.path.normpath(entry.path)
                        dst_p = os.path.normpath(dst)
                        shutil.copy(src_p, dst_p)
                        src_st = os.stat(src_p)
                        os.utime(dst_p, (src_st.st_atime, src_st.st_mtime))
                        if exists:
                            logger.info(f"  ERSETZT (Root-Datei): {dst}")
                            stats["replaced"] += 1
                        else:
                            logger.info(f"  KOPIERT (Root-Datei): {dst}")
                            stats["copied"] += 1
                        print(f"NOTFOUND_COPIED:{name}", flush=True)
                    except Exception as e:
                        logger.error(f"  FEHLER Root-Datei {name}: {e}")
                        stats["errors"] += 1
            else:
                logger.warning(f"  NICHT GEFUNDEN (Root-Datei) -- uebersprungen: '{name}'")
                print(f"NOTFOUND:{name}", flush=True)
                not_found.append(name)

    logger.info("")
    logger.info("=== Zusammenfassung ===")
    logger.info(f"Kopiert:       {stats['copied']}")
    logger.info(f"Ersetzt:       {stats.get('replaced',0)}")
    logger.info(f"Übersprungen: {stats['skipped']}")
    logger.info(f"Gelöscht:     {stats['deleted']}")
    logger.info(f"Fehler:        {stats['errors']}")

    if not_found:
        logger.warning("")
        if opt_n:
            logger.warning("Folgende Dateien/Ordner wurden nicht im Mac-Ziel-Pfad")
            logger.warning("gefunden — nicht kopiert:")
        else:
            logger.warning("Folgende Dateien/Ordner wurden nicht im Mac-Ziel-Pfad gefunden:")
        for item in not_found:
            logger.warning(f"  * {item}")
        logger.warning("")
        print(f"NOTFOUND_LIST:{'|'.join(not_found)}", flush=True)

    older = stats.get("older_files", [])
    if older:
        logger.warning("")
        logger.warning("Folgende Dateien auf dem USB-Stick sind älter oder")
        logger.warning("genauso alt wie auf dem Mac — nicht kopiert:")
        for item in older:
            logger.warning(f"  * {item}")
        logger.warning("")
        print("OLDER_LIST\t" + "|".join(older), flush=True)

    logger.info("=== USB Sync beendet ===")
    print(f"RESULT:{stats['copied']}:{stats.get('replaced',0)}:{stats['skipped']}:{stats['deleted']}:{stats['errors']}", flush=True)

if __name__ == "__main__":
    if len(sys.argv) not in (6, 7, 8):
        print("Usage: usb_sync_engine.py <usb> <mac> <e:0|1> <v:0|1> <l:0|1> [n:0|1] [newer:0|1]")
        sys.exit(1)
    opt_n     = (sys.argv[6] == "1") if len(sys.argv) >= 7 else False
    opt_newer = (sys.argv[7] == "1") if len(sys.argv) >= 8 else False
    sync(sys.argv[1], sys.argv[2],
         sys.argv[3]=="1", sys.argv[4]=="1", sys.argv[5]=="1",
         opt_n, opt_newer)

PYEOF
chmod +x "${DEST}/Contents/Resources/usb_sync_engine.py"

# ============================================================
# 3) Swift-App mit nativen Checkboxen
# ============================================================
cat > /tmp/USBSync_main.swift << 'SWEOF'
import Cocoa

// ═══════════════════════════════════════════════════════════
// EINSTELLUNGEN
// ═══════════════════════════════════════════════════════════
let prefsKey = "de.usbsync.prefs"

func loadPrefs() -> [String: Any] {
    return UserDefaults.standard.dictionary(forKey: prefsKey) ?? [
        "usbPath":        "/Volumes/Backup/Daten",
        "macPath":        NSHomeDirectory() + "/Daten",
        "usbHistory":     [String](),
        "macHistory":     [String](),
        "optE": false, "optV": false, "optL": false,
        "copyNotFound":   false,
        "logCopied":      true,  "logReplaced": true,
        "logSkipped":     true,  "logNotFound": true,  "logErrors": true
    ]
}
func savePrefs(_ d: [String: Any]) {
    UserDefaults.standard.set(d, forKey: prefsKey)
}

// Pfad-Verlauf: bis zu 5 zuletzt verwendete Pfade speichern
func addToHistory(_ path: String, key: String, prefs: inout [String: Any]) {
    var hist = prefs[key] as? [String] ?? []
    hist.removeAll { $0 == path }
    hist.insert(path, at: 0)
    if hist.count > 5 { hist = Array(hist.prefix(5)) }
    prefs[key] = hist
}

// ═══════════════════════════════════════════════════════════
// DRAG-AND-DROP TEXTFELD
// ═══════════════════════════════════════════════════════════
class DropTextField: NSTextField {
    override func awakeFromNib() { super.awakeFromNib(); setupDrop() }
    override init(frame: NSRect) { super.init(frame: frame); setupDrop() }
    required init?(coder: NSCoder) { super.init(coder: coder); setupDrop() }
    private func setupDrop() { registerForDraggedTypes([.fileURL, .string]) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        if let urls = s.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first { stringValue = url.path; return true }
        if let str = s.draggingPasteboard.string(forType: .string) {
            stringValue = str.trimmingCharacters(in: .whitespaces); return true }
        return false
    }
}

// ═══════════════════════════════════════════════════════════
// START-DIALOG (NSPanel mit Menüleiste für Paste-Support)
// ═══════════════════════════════════════════════════════════
class StartDialogController: NSObject, NSWindowDelegate {
    var panel:        NSPanel!
    var tfUSB:        DropTextField!
    var tfMAC:        DropTextField!
    var cbE:           NSButton!
    var cbV:           NSButton!
    var cbL:           NSButton!
    var cbCopyNotFound:NSButton!
    var cbNewer:       NSButton!
    var cbLogCopied:   NSButton!
    var cbLogReplaced:NSButton!
    var cbLogSkipped: NSButton!
    var cbLogNotFound:NSButton!
    var cbLogErrors:  NSButton!
    var macWarnLabel: NSTextField!
    var didStart = false

    func buildAndShow(prefs: [String: Any]) {
        // ── Breiter, kompakter, groessere Schrift ─────────
        let W: CGFloat = 680
        let H: CGFloat = 444   // exakt passend zum Inhalt

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        // Normales Fensterverhalten: andere Fenster koennen davor geschoben werden
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.title = "USB Sync Tool"
        panel.minSize = NSSize(width: 560, height: 400)
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = false

        let cv = panel.contentView!

        // ── Titel ─────────────────────────────────────────
        let icon = NSTextField(labelWithString: "🔄")
        icon.font  = NSFont.systemFont(ofSize: 26)
        icon.frame = NSRect(x: 18, y: H-48, width: 36, height: 34)
        cv.addSubview(icon)
        let titleLbl = NSTextField(labelWithString: "USB Sync Tool")
        titleLbl.font  = NSFont.boldSystemFont(ofSize: 17)  // groesser
        titleLbl.frame = NSRect(x: 58, y: H-38, width: W-78, height: 24)
        cv.addSubview(titleLbl)
        let sep1 = NSBox(frame: NSRect(x: 0, y: H-54, width: W, height: 1))
        sep1.boxType = .separator; cv.addSubview(sep1)

        let usbHistory = prefs["usbHistory"] as? [String] ?? []
        let macHistory = prefs["macHistory"] as? [String] ?? []
        let defUSB = prefs["usbPath"] as? String ?? "/Volumes/Backup/Daten"
        let defMAC = prefs["macPath"] as? String ?? NSHomeDirectory() + "/Daten"

        // ── USB-Pfad ──────────────────────────────────────
        let usbLbl = NSTextField(labelWithString: "USB-Quell-Pfad:")
        usbLbl.font = NSFont.systemFont(ofSize: 13, weight: .semibold)  // groesser
        usbLbl.frame = NSRect(x: 20, y: H-78, width: W-40, height: 18)
        cv.addSubview(usbLbl)

        // Textfeld volle Breite
        tfUSB = DropTextField(frame: NSRect(x: 20, y: H-104, width: W-40, height: 28))
        tfUSB.stringValue = defUSB
        tfUSB.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tfUSB.placeholderString = "Pfad eingeben oder Ordner hierher ziehen"
        tfUSB.target = self
        tfUSB.action = #selector(usbPathChanged)
        tfUSB.isBezeled = true
        tfUSB.bezelStyle = .roundedBezel
        tfUSB.drawsBackground = true
        tfUSB.backgroundColor = NSColor.textBackgroundColor
        cv.addSubview(tfUSB)

        // FIX 2: Verlauf-Popup unter dem Textfeld (volle Breite, links)
        let btnUSBHist = makeHistoryPopup(x: 20, y: H-128, w: 220,
                                          history: usbHistory, fieldTag: 200)
        cv.addSubview(btnUSBHist)

        // USB Warn-Label
        let usbWarnLabel = NSTextField(labelWithString: "")
        usbWarnLabel.font = NSFont.systemFont(ofSize: 11)
        usbWarnLabel.textColor = .systemGreen
        usbWarnLabel.tag = 101
        usbWarnLabel.frame = NSRect(x: 248, y: H-128, width: W-268, height: 18)
        cv.addSubview(usbWarnLabel)

        let sep2 = NSBox(frame: NSRect(x: 0, y: H-138, width: W, height: 1))
        sep2.boxType = .separator; cv.addSubview(sep2)

        // ── Mac-Pfad ──────────────────────────────────────
        let macLbl = NSTextField(labelWithString: "Mac-Ziel-Pfad:")
        macLbl.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        macLbl.frame = NSRect(x: 20, y: H-162, width: W-40, height: 18)
        cv.addSubview(macLbl)

        tfMAC = DropTextField(frame: NSRect(x: 20, y: H-188, width: W-40, height: 28))
        tfMAC.stringValue = defMAC
        tfMAC.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tfMAC.placeholderString = "Pfad eingeben oder Ordner hierher ziehen"
        tfMAC.target = self
        tfMAC.action = #selector(macPathChanged)
        tfMAC.isBezeled = true
        tfMAC.bezelStyle = .roundedBezel
        tfMAC.drawsBackground = true
        tfMAC.backgroundColor = NSColor.textBackgroundColor
        cv.addSubview(tfMAC)

        // FIX 2: Verlauf-Popup unter dem Mac-Textfeld
        let btnMACHist = makeHistoryPopup(x: 20, y: H-212, w: 220,
                                          history: macHistory, fieldTag: 201)
        cv.addSubview(btnMACHist)

        macWarnLabel = NSTextField(labelWithString: "")
        macWarnLabel.font = NSFont.systemFont(ofSize: 11)
        macWarnLabel.textColor = .systemGreen
        macWarnLabel.frame = NSRect(x: 248, y: H-212, width: W-268, height: 18)
        cv.addSubview(macWarnLabel)

        let sep3 = NSBox(frame: NSRect(x: 0, y: H-222, width: W, height: 1))
        sep3.boxType = .separator; cv.addSubview(sep3)

        // ── Sync-Optionen + Log-Filter nebeneinander ──────
        // FIX 3: 2-spaltiges Layout — Sync links, Log rechts
        let optLbl = NSTextField(labelWithString: "Sync-Optionen:")
        optLbl.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        optLbl.frame = NSRect(x: 20, y: H-246, width: 300, height: 18)
        cv.addSubview(optLbl)

        let logLbl = NSTextField(labelWithString: "Log anzeigen:")
        logLbl.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        logLbl.frame = NSRect(x: 360, y: H-246, width: 300, height: 18)
        cv.addSubview(logLbl)

        // Sync-Optionen linke Spalte (5 Checkboxen)
        let cbFont = NSFont.systemFont(ofSize: 13)
        cbE = makeCheckbox(" Ersetzen  (-e)",           x: 20,  y: H-268, w: 320, on: prefs["optE"]         as? Bool ?? false)
        cbV = makeCheckbox(" Log auf USB  (-v)",         x: 20,  y: H-290, w: 320, on: prefs["optV"]         as? Bool ?? false)
        cbL = makeCheckbox(" USB löschen  (-l)",        x: 20,  y: H-312, w: 320, on: prefs["optL"]         as? Bool ?? false)
        cbCopyNotFound = makeCheckbox(" Nicht gefunden kopieren  (-n)", x: 20, y: H-334, w: 320,
                                      on: prefs["copyNotFound"] as? Bool ?? false)
        cbNewer = makeCheckbox(" Nur neuere kopieren  (-t)",     x: 20,  y: H-356, w: 320,
                               on: prefs["optNewer"] as? Bool ?? false)
        for cb in [cbE, cbV, cbL, cbCopyNotFound, cbNewer] {
            cb!.font = cbFont; cv.addSubview(cb!)
        }

        // Log-Filter rechte Spalte (5 Checkboxen)
        cbLogCopied   = makeCheckbox(" Kopiert",        x: 360, y: H-268, w: 280, on: prefs["logCopied"]   as? Bool ?? true)
        cbLogReplaced = makeCheckbox(" Ersetzt",        x: 360, y: H-290, w: 280, on: prefs["logReplaced"] as? Bool ?? true)
        cbLogSkipped  = makeCheckbox(" Übersprungen",  x: 360, y: H-312, w: 280, on: prefs["logSkipped"]  as? Bool ?? true)
        cbLogNotFound = makeCheckbox(" Nicht gefunden", x: 360, y: H-334, w: 280, on: prefs["logNotFound"] as? Bool ?? true)
        cbLogErrors   = makeCheckbox(" Fehler",         x: 360, y: H-356, w: 280, on: prefs["logErrors"]   as? Bool ?? true)
        for cb in [cbLogCopied, cbLogReplaced, cbLogSkipped, cbLogNotFound, cbLogErrors] {
            cb!.font = cbFont; cv.addSubview(cb!)
        }

        // Vertikale Trennlinie zwischen den Spalten
        let sepV = NSBox(frame: NSRect(x: 344, y: H-364, width: 1, height: 128))
        sepV.boxType = .separator; cv.addSubview(sepV)

        let sep5 = NSBox(frame: NSRect(x: 0, y: H-372, width: W, height: 1))
        sep5.boxType = .separator; cv.addSubview(sep5)

        // ── Buttons ───────────────────────────────────────
        let btnCancel = NSButton(frame: NSRect(x: W-270, y: 14, width: 120, height: 32))
        btnCancel.title = "Abbrechen"; btnCancel.bezelStyle = .rounded
        btnCancel.keyEquivalent = "\u{1B}"
        btnCancel.target = self; btnCancel.action = #selector(clickCancel)
        cv.addSubview(btnCancel)

        let btnStart = NSButton(frame: NSRect(x: W-140, y: 14, width: 120, height: 32))
        btnStart.title = "▶  Starten"; btnStart.bezelStyle = .rounded
        btnStart.keyEquivalent = "\r"
        btnStart.target = self; btnStart.action = #selector(clickStart)
        cv.addSubview(btnStart)

        NSApp.mainMenu = buildMenuBar()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tfUSB)
        validateUSBPath()
        validateMacPath()
    }

    // Erstellt einen NSPopUpButton mit Verlauf-Eintraegen
    func makeHistoryPopup(x: CGFloat, y: CGFloat, w: CGFloat = 32,
                          history: [String], fieldTag: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: x, y: y, width: w, height: 22),
                                  pullsDown: true)
        popup.bezelStyle = .rounded
        popup.font = NSFont.systemFont(ofSize: 12)
        popup.tag = fieldTag
        // Erster Eintrag = Titel des Pull-Down-Buttons
        popup.addItem(withTitle: "▾")
        if history.isEmpty {
            popup.addItem(withTitle: "(kein Verlauf)")
            popup.item(at: 1)?.isEnabled = false
        } else {
            for path in history {
                popup.addItem(withTitle: path)
            }
        }
        popup.target = self
        popup.action = #selector(historyPopupSelected(_:))
        return popup
    }

    @objc func historyPopupSelected(_ sender: NSPopUpButton) {
        // Index 0 = Titel "▾", ab Index 1 echte Pfade
        guard sender.indexOfSelectedItem > 0 else { return }
        let path = sender.titleOfSelectedItem ?? ""
        guard !path.isEmpty && path != "(kein Verlauf)" else { return }
        if sender.tag == 200 {
            tfUSB.stringValue = path
            validateUSBPath()
        } else {
            tfMAC.stringValue = path
            validateMacPath()
        }
        // Button-Titel wieder auf "▾" zuruecksetzen
        sender.selectItem(at: 0)
    }

    func makeCheckbox(_ title: String, x: CGFloat, y: CGFloat, w: CGFloat, on: Bool) -> NSButton {
        let cb = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        cb.state = on ? .on : .off
        cb.font = NSFont.systemFont(ofSize: 11)
        cb.frame = NSRect(x: x, y: y, width: w, height: 20)
        return cb
    }

    @objc func usbPathChanged() { validateUSBPath() }
    @objc func macPathChanged() { validateMacPath() }

    func validateUSBPath() {
        let path = tfUSB.stringValue.trimmingCharacters(in: .whitespaces)
        // USB Warn-Label via Tag finden
        guard let warn = panel.contentView?.viewWithTag(101) as? NSTextField else { return }
        if path.isEmpty {
            warn.stringValue = ""
        } else if FileManager.default.fileExists(atPath: path) {
            warn.stringValue   = "✅  Pfad gefunden"
            warn.textColor = .systemGreen
        } else {
            warn.stringValue   = "⚠️  USB-Pfad existiert nicht (Stick eingesteckt?)"
            warn.textColor = .systemRed
        }
    }

    func validateMacPath() {
        let path = tfMAC.stringValue.trimmingCharacters(in: .whitespaces)
        if path.isEmpty {
            macWarnLabel.stringValue = ""
        } else if FileManager.default.fileExists(atPath: path) {
            macWarnLabel.stringValue = "✅  Pfad gefunden"
            macWarnLabel.textColor   = .systemGreen
        } else {
            macWarnLabel.stringValue = "⚠️  Pfad existiert nicht auf diesem Mac"
            macWarnLabel.textColor   = .systemRed
        }
    }

    // showUSBHistory / showMACHistory entfallen — NSPopUpButton hat eigene Action

    // showUSBHistory / showMACHistory werden durch NSPopUpButton ersetzt
    // (historyItemSelected entfaellt — wird durch historyPopupSelected abgedeckt)

    func buildMenuBar() -> NSMenu {
        let mb = NSMenu(); let ai = NSMenuItem(); mb.addItem(ai)
        let am = NSMenu(); ai.submenu = am
        am.addItem(NSMenuItem(title: "Beenden",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let ei = NSMenuItem(); mb.addItem(ei)
        let em = NSMenu(title: "Bearbeiten"); ei.submenu = em
        for (t, s, k) in [
            ("Ausschneiden",    #selector(NSText.cut(_:)),       "x"),
            ("Kopieren",        #selector(NSText.copy(_:)),      "c"),
            ("Einsetzen",       #selector(NSText.paste(_:)),     "v"),
            ("Alles auswaehlen",#selector(NSText.selectAll(_:)), "a")] {
            em.addItem(NSMenuItem(title: t, action: s, keyEquivalent: k))
        }
        return mb
    }

    @objc func clickStart() {
        let usbPath = tfUSB.stringValue.trimmingCharacters(in: .whitespaces)
        let macPath = tfMAC.stringValue.trimmingCharacters(in: .whitespaces)
        // USB-Pfad validieren
        if !FileManager.default.fileExists(atPath: usbPath) {
            let alert = NSAlert()
            alert.messageText    = "USB-Pfad nicht gefunden"
            alert.informativeText = "Der USB-Pfad existiert nicht:\n\(usbPath)\n\nBitte USB-Stick prüfen und Pfad korrigieren."
            alert.alertStyle     = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        // Mac-Pfad validieren
        if !FileManager.default.fileExists(atPath: macPath) {
            let alert = NSAlert()
            alert.messageText    = "Mac-Pfad nicht gefunden"
            alert.informativeText = "Der Mac-Pfad existiert nicht:\n\(macPath)\n\nBitte korrigieren oder per Drag & Drop aus dem Finder einfügen."
            alert.alertStyle     = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        didStart = true; panel.close()
    }

    @objc func clickCancel() { didStart = false; panel.close() }
    func windowWillClose(_ n: Notification) { NSApp.stopModal() }
}

// ═══════════════════════════════════════════════════════════
// DOCK-BADGE
// ═══════════════════════════════════════════════════════════
func updateDockBadge(percent: Int) {
    if percent >= 100      { NSApp.dockTile.badgeLabel = "✓" }
    else if percent > 0    { NSApp.dockTile.badgeLabel = "\(percent)%" }
    else                   { NSApp.dockTile.badgeLabel = nil }
}

// ═══════════════════════════════════════════════════════════
// FORTSCHRITTSFENSTER (resizable, bleibt nach Fertig offen)
// ═══════════════════════════════════════════════════════════
class ProgressWindowController: NSObject, NSWindowDelegate {
    var window:        NSWindow!
    var spinner:       NSProgressIndicator!
    var progressBar:   NSProgressIndicator!
    var percentLabel:  NSTextField!
    var statusLabel:   NSTextField!
    var copiedLabel:   NSTextField!
    var replacedLabel: NSTextField!
    var skippedLabel:  NSTextField!
    var deletedLabel:  NSTextField!
    var errorsLabel:   NSTextField!
    var olderLabel:    NSTextField!
    var logView:       NSTextView!
    var scrollView:    NSScrollView!
    var notFoundView:  NSTextView!
    var notFoundScroll:NSScrollView!
    var tabControl:    NSSegmentedControl!
    var footerLabel:   NSTextField!

    var copiedCount   = 0; var replacedCount = 0; var skippedCount  = 0
    var deletedCount  = 0; var errorsCount   = 0; var olderCount    = 0
    var totalFiles    = 0; var processedFiles = 0
    var notFoundList  = [String]()
    var olderList     = [String]()

    // Log-Filter (von Start-Dialog übernommen)
    var logCopied   = true; var logReplaced = true
    var logSkipped  = true; var logNotFound = true; var logErrors = true

    func show(usbPath: String, macPath: String) {
        let W: CGFloat = 850
        let H: CGFloat = 560

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title   = "USB Sync Tool — Synchronisierung läuft…"
        window.minSize = NSSize(width: 650, height: 420)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView?.autoresizingMask = [.width, .height]
        window.delegate = self

        let cv = window.contentView!

        // ── Spinner + Titel ───────────────────────────────
        spinner = NSProgressIndicator(frame: NSRect(x: 20, y: H-52, width: 26, height: 26))
        spinner.style = .spinning; spinner.startAnimation(nil)
        spinner.autoresizingMask = [.maxYMargin]
        cv.addSubview(spinner)

        let titleLbl = NSTextField(labelWithString: "Synchronisierung läuft…")
        titleLbl.font = NSFont.boldSystemFont(ofSize: 15)
        titleLbl.frame = NSRect(x: 54, y: H-48, width: W-74, height: 22)
        titleLbl.autoresizingMask = [.width, .maxYMargin]
        cv.addSubview(titleLbl)

        for (text, yPos) in [("🔌 " + usbPath, H-70), ("💻 " + macPath, H-86)] {
            let l = NSTextField(labelWithString: text)
            l.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingMiddle
            l.frame = NSRect(x: 20, y: CGFloat(yPos), width: W-40, height: 15)
            l.autoresizingMask = [.width, .maxYMargin]
            cv.addSubview(l)
        }

        let sep1 = NSBox(frame: NSRect(x: 0, y: H-96, width: W, height: 1))
        sep1.boxType = .separator; sep1.autoresizingMask = [.width, .maxYMargin]
        cv.addSubview(sep1)

        // ── Fortschrittsbalken ────────────────────────────
        progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: H-124, width: W-80, height: 14))
        progressBar.style = .bar; progressBar.isIndeterminate = true
        progressBar.startAnimation(nil); progressBar.minValue = 0; progressBar.maxValue = 100
        progressBar.autoresizingMask = [.width, .maxYMargin]
        cv.addSubview(progressBar)

        percentLabel = NSTextField(labelWithString: "…")
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percentLabel.alignment = .right
        percentLabel.frame = NSRect(x: W-54, y: H-127, width: 48, height: 18)
        percentLabel.autoresizingMask = [.minXMargin, .maxYMargin]
        cv.addSubview(percentLabel)

        // ── Status ────────────────────────────────────────
        let statusTitle = NSTextField(labelWithString: "Status:")
        statusTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusTitle.frame = NSRect(x: 20, y: H-146, width: 54, height: 16)
        statusTitle.autoresizingMask = [.maxYMargin]
        cv.addSubview(statusTitle)

        statusLabel = NSTextField(labelWithString: "Wird gestartet …")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 78, y: H-146, width: W-98, height: 16)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        cv.addSubview(statusLabel)

        let sep2 = NSBox(frame: NSRect(x: 0, y: H-160, width: W, height: 1))
        sep2.boxType = .separator; sep2.autoresizingMask = [.width, .maxYMargin]
        cv.addSubview(sep2)

        // ── 5 Zähler ─────────────────────────────────────
        func makeCounter(label: String, x: CGFloat, color: NSColor = .labelColor) -> NSTextField {
            let lbl = NSTextField(labelWithString: label)
            lbl.font = NSFont.systemFont(ofSize: 10); lbl.textColor = .secondaryLabelColor
            lbl.alignment = .center
            lbl.frame = NSRect(x: x, y: H-202, width: 100, height: 14)
            lbl.autoresizingMask = [.maxYMargin]
            cv.addSubview(lbl)
            let val = NSTextField(labelWithString: "0")
            val.font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            val.textColor = color; val.alignment = .center
            val.frame = NSRect(x: x, y: H-228, width: 100, height: 28)
            val.autoresizingMask = [.maxYMargin]
            cv.addSubview(val)
            return val
        }
        // 6 Zaehler gleichmaessig verteilt (je 100pt breit)
        let cW: CGFloat = 100
        let cGap: CGFloat = 5
        let cX = (W - 6*cW - 5*cGap) / 2
        copiedLabel   = makeCounter(label: "📁 Kopiert",      x: cX)
        replacedLabel = makeCounter(label: "🔄 Ersetzt",      x: cX+(cW+cGap)*1, color: .systemOrange)
        skippedLabel  = makeCounter(label: "⏭️ Überspr.",     x: cX+(cW+cGap)*2)
        deletedLabel  = makeCounter(label: "🗑️ Gelöscht",    x: cX+(cW+cGap)*3)
        olderLabel    = makeCounter(label: "🕐 Älter",        x: cX+(cW+cGap)*4, color: .systemPurple)
        errorsLabel   = makeCounter(label: "❌ Fehler",        x: cX+(cW+cGap)*5, color: .systemRed)

        let sep3 = NSBox(frame: NSRect(x: 0, y: H-236, width: W, height: 1))
        sep3.boxType = .separator; sep3.autoresizingMask = [.width, .maxYMargin]
        cv.addSubview(sep3)

        // ── Tab-Umschalter ────────────────────────────────
        tabControl = NSSegmentedControl(
            labels: ["📋  Log", "❓  Nicht gefunden"],
            trackingMode: .selectOne, target: self,
            action: #selector(tabChanged))
        tabControl.selectedSegment = 0
        tabControl.frame = NSRect(x: W/2-130, y: H-264, width: 260, height: 24)
        tabControl.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        cv.addSubview(tabControl)

        // ── Log ScrollView ────────────────────────────────
        // svY = Abstand zur Fusszeile, svTop = Abstand zum Tab-Control
        let svY:   CGFloat = 46   // Platz fuer Fusszeile
        let svTop: CGFloat = H - 248   // direkt unter Tab-Control
        let svH:   CGFloat = svTop - svY
        scrollView = makeScrollView(frame: NSRect(x: 0, y: svY, width: W, height: svH))
        scrollView.autoresizingMask = [.width, .height]
        logView = (scrollView.documentView as! NSTextView)
        cv.addSubview(scrollView)

        // ── Nicht-gefunden ScrollView (versteckt) ─────────
        notFoundScroll = makeScrollView(frame: NSRect(x: 0, y: svY, width: W, height: svH))
        notFoundScroll.autoresizingMask = [.width, .height]
        notFoundScroll.isHidden = true
        notFoundView = (notFoundScroll.documentView as! NSTextView)
        cv.addSubview(notFoundScroll)

        // ── Fußzeile ──────────────────────────────────────
        let sep4 = NSBox(frame: NSRect(x: 0, y: 36, width: W, height: 1))
        sep4.boxType = .separator; sep4.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(sep4)
        footerLabel = NSTextField(labelWithString: "Bitte warten — Fenster nicht schließen")
        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor; footerLabel.alignment = .center
        footerLabel.frame = NSRect(x: 0, y: 10, width: W, height: 16)
        footerLabel.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(footerLabel)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeScrollView(frame: NSRect) -> NSScrollView {
        let sv = NSScrollView(frame: frame)
        sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.backgroundColor = NSColor(white: 0.97, alpha: 1)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        tv.isEditable = false; tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = .clear; tv.textContainerInset = NSSize(width: 8, height: 4)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        sv.documentView = tv; return sv
    }

    @objc func tabChanged() {
        scrollView.isHidden     = tabControl.selectedSegment != 0
        notFoundScroll.isHidden = tabControl.selectedSegment != 1
    }

    // Roter Schliessen-Button beendet die App
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return true
    }

    func updateProgress() {
        guard totalFiles > 0 else { return }
        let pct = min(100, Int(Double(processedFiles) / Double(totalFiles) * 100))
        progressBar.isIndeterminate = false
        progressBar.doubleValue     = Double(pct)
        percentLabel.stringValue    = "\(pct) %"
        updateDockBadge(percent: pct)
    }

    func processLine(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Fenster und alle UI-Elemente muessen existieren
            guard self.window != nil,
                  self.copiedLabel   != nil,
                  self.replacedLabel != nil,
                  self.skippedLabel  != nil,
                  self.deletedLabel  != nil,
                  self.errorsLabel   != nil,
                  self.olderLabel    != nil,
                  self.progressBar   != nil,
                  self.statusLabel   != nil,
                  self.logView       != nil else { return }

            // Gesamtzahl
            if line.contains("TOTAL:") {
                if let n = Int(line.components(separatedBy: "TOTAL:").last?
                               .trimmingCharacters(in: .whitespaces) ?? "") {
                    self.totalFiles = n
                    self.progressBar.isIndeterminate = false
                    self.progressBar.stopAnimation(nil)
                    self.progressBar.doubleValue = 0
                    self.percentLabel.stringValue = "0 %"
                }
                return
            }

            // Zähler + Filter
            if line.contains("ERSETZT:") {
                self.replacedCount += 1
                self.replacedLabel.stringValue = "\(self.replacedCount)"
                self.processedFiles += 1; self.updateProgress()
                if !self.logReplaced { return }
            } else if line.contains("KOPIERT:") {
                self.copiedCount += 1
                self.copiedLabel.stringValue = "\(self.copiedCount)"
                self.processedFiles += 1; self.updateProgress()
                if !self.logCopied { return }
            } else if line.contains("ÜBERSPRUNGEN") {
                self.skippedCount += 1
                self.skippedLabel.stringValue = "\(self.skippedCount)"
                self.processedFiles += 1; self.updateProgress()
                if !self.logSkipped { return }
            } else if line.contains("GELÖSCHT (USB)") || line.contains("ORDNER GELÖSCHT (USB)") {
                self.deletedCount += 1
                self.deletedLabel.stringValue = "\(self.deletedCount)"
                if !self.logCopied { return }
            } else if line.contains("FEHLER") {
                self.errorsCount += 1
                self.errorsLabel.stringValue = "\(self.errorsCount)"
                if !self.logErrors { return }
            } else if line.contains("NOTFOUND_LIST:") {
                // Abschlussliste ans Ende des Log-Views anhaengen
                if let r = line.range(of: "NOTFOUND_LIST:") {
                    let names = String(line[r.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: "|")
                        .filter { !$0.isEmpty }
                    // Zusammenfassung oben im Nicht-gefunden-Tab
                    let summary = NSAttributedString(
                        string: "\n── \(names.count) Eintraege ──\n",
                        attributes: [.font: NSFont.boldSystemFont(ofSize: 12),
                                     .foregroundColor: NSColor.systemRed])
                    self.notFoundView.textStorage?.insert(summary, at: 0)
                }
                return
            } else if line.contains("NOTFOUND_COPIED:") {
                // Nicht gefunden aber in mac_root kopiert
                if let r = line.range(of: "NOTFOUND_COPIED:") {
                    let name = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    self.notFoundList.append(name)
                    self.tabControl.setLabel("❓  Nicht gefunden (\(self.notFoundList.count))",
                                              forSegment: 1)
                    self.appendNotFound(name, copied: true)
                }
                if !self.logNotFound { return }
            } else if line.contains("NOTFOUND:") && !line.contains("NOTFOUND_") {
                // Nicht gefunden und uebersprungen
                if let r = line.range(of: "NOTFOUND:") {
                    let name = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    self.notFoundList.append(name)
                    self.tabControl.setLabel("❓  Nicht gefunden (\(self.notFoundList.count))",
                                              forSegment: 1)
                    self.appendNotFound(name, copied: false)
                }
                if !self.logNotFound { return }
            } else if line.contains("NICHT GEFUNDEN") {
                if !self.logNotFound { return }
            }

            // Statuszeile
            if line.contains("KOPIERT:") || line.contains("ERSETZT:") {
                if let r = line.range(of: ":  ") ?? line.range(of: ": ") {
                    self.statusLabel.stringValue =
                        URL(fileURLWithPath: String(line[r.upperBound...])).lastPathComponent
                }
            } else if line.contains("ORDNER ERSTELLT:") {
                if let r = line.range(of: "ORDNER ERSTELLT: ") {
                    self.statusLabel.stringValue = "📂 " + String(line[r.upperBound...])
                }
            }

            // OLDER: Aeltere Datei gezaehlt
            if line.contains("OLDER:") && !line.contains("OLDER_LIST") {
                if let r = line.range(of: "OLDER:") {
                    let name = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    self.olderCount += 1
                    self.olderLabel.stringValue = "\(self.olderCount)"
                    self.olderList.append(name)
                }
                return
            }

            // OLDER_LIST: Abschlussliste älterer Dateien
            if line.hasPrefix("OLDER_LIST\t") {
                if let r = line.range(of: "OLDER_LIST\t") {
                    let names = String(line[r.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: "|")
                        .filter { !$0.isEmpty }
                    let hd = NSAttributedString(string: "\n── \(names.count) ältere Dateien ──\n",
                        attributes: [.font: NSFont.boldSystemFont(ofSize: 12),
                                     .foregroundColor: NSColor.systemPurple])
                    self.notFoundView.textStorage?.append(hd)
                    for n in names {
                        self.notFoundView.textStorage?.append(NSAttributedString(
                            string: "🕐  \(n)\n",
                            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                         .foregroundColor: NSColor.systemPurple]))
                    }
                }
                return
            }

            self.appendLog(line)
        }
    }

    func appendLog(_ line: String) {
        let storage = logView.textStorage!
        storage.append(NSAttributedString(string: line + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]))
        logView.scrollToEndOfDocument(nil)
    }

    func appendNotFound(_ name: String, copied: Bool = false) {
        let storage = notFoundView.textStorage!
        let icon  = copied ? "📥" : "❓"
        let note  = copied ? "  (→ in mac_root kopiert)" : "  (übersprungen)"
        let color = copied ? NSColor.systemBlue : NSColor.systemOrange
        storage.append(NSAttributedString(
            string: "\(icon)  \(name)\(note)\n",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: color]))
    }

    func syncFinished(usbPath: String, optV: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            // Spinner durch grünen Haken ersetzen
            if let cv = self.window.contentView {
                let check = NSTextField(labelWithString: "✅")
                check.font = NSFont.systemFont(ofSize: 22)
                check.frame = self.spinner.frame
                check.alignment = .center
                cv.addSubview(check)
            }
            self.progressBar.doubleValue = 100
            self.percentLabel.stringValue = "100 %"
            self.window.title = "USB Sync Tool — Abgeschlossen ✅"
            // Titel auf "Synchronisierung beendet!" ändern
            if let cv = self.window.contentView {
                for sub in cv.subviews {
                    if let lbl = sub as? NSTextField,
                       lbl.stringValue == "Synchronisierung läuft…" {
                        lbl.stringValue = "Synchronisierung beendet!"
                        lbl.textColor = NSColor.systemGreen
                        break
                    }
                }
            }
            self.statusLabel.stringValue = "Fertig."
            updateDockBadge(percent: 100)
            self.footerLabel?.stringValue = "Sync abgeschlossen — Fenster kann geschlossen werden"
            self.footerLabel?.textColor = .secondaryLabelColor

            // Lesbaren Abschlussblock ans Log anhaengen
            // Ältere Dateien ans Log anhaengen
            if !self.olderList.isEmpty {
                let olderAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 12),
                    .foregroundColor: NSColor.systemPurple
                ]
                let olderItemAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]
                let olderSep = String(repeating: "─", count: 60) + "\n"
                self.logView.textStorage?.append(NSAttributedString(string: "\n", attributes: olderItemAttrs))
                self.logView.textStorage?.append(NSAttributedString(string: olderSep, attributes: olderAttrs))
                self.logView.textStorage?.append(NSAttributedString(
                    string: "Folgende Dateien auf dem USB-Stick sind\nälter oder genauso alt wie auf dem Mac — nicht kopiert:\n",
                    attributes: olderAttrs))
                for name in self.olderList {
                    self.logView.textStorage?.append(NSAttributedString(
                        string: "  🕐 \(name)\n", attributes: olderItemAttrs))
                }
                self.logView.textStorage?.append(NSAttributedString(string: olderSep, attributes: olderAttrs))
                self.logView.scrollToEndOfDocument(nil)
            }

            if !self.notFoundList.isEmpty {
                let isCopied = self.notFoundList.allSatisfy { name in
                    (self.logView.string.contains("dorthin kopiert") ||
                     self.logView.string.contains("NOTFOUND_COPIED"))
                }
                let heading = isCopied
                    ? "Folgende Dateien/Ordner wurden nicht im Mac-Ziel-Pfad\ngefunden — nicht kopiert:"
                    : "Folgende Dateien/Ordner wurden nicht im Mac-Ziel-Pfad gefunden:"

                let blockAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 12),
                    .foregroundColor: NSColor.systemOrange
                ]
                let itemAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]
                let separator = String(repeating: "═", count: 60) + "\n"
                let logStorage = self.logView.textStorage!
                logStorage.append(NSAttributedString(string: "\n", attributes: itemAttrs))
                logStorage.append(NSAttributedString(string: separator, attributes: blockAttrs))
                logStorage.append(NSAttributedString(string: heading + "\n", attributes: blockAttrs))
                for name in self.notFoundList {
                    logStorage.append(NSAttributedString(
                        string: "  • \(name)\n", attributes: itemAttrs))
                }
                logStorage.append(NSAttributedString(string: separator, attributes: blockAttrs))
                self.logView.scrollToEndOfDocument(nil)

                // Zusammenfassung oben im Nicht-gefunden-Tab
                let summary = NSAttributedString(
                    string: "\n── \(self.notFoundList.count) Eintraege ──\n",
                    attributes: blockAttrs)
                self.notFoundView.textStorage?.insert(summary, at: 0)
            }

            var info = "📁 Kopiert (neu):  \(self.copiedCount)\n" +
                       "🔄 Ersetzt:         \(self.replacedCount)\n" +
                       "⏭️  Übersprungen:   \(self.skippedCount)\n" +
                       "🗑️  Gelöscht:       \(self.deletedCount)\n" +
                       "🕐 Ältere Dateien: \(self.olderCount)\n" +
                       "❌ Fehler:          \(self.errorsCount)"
            if !self.notFoundList.isEmpty {
                info += "\n❓ Nicht gefunden:  \(self.notFoundList.count)\n"
                info += "   " + self.notFoundList.joined(separator: "\n   ")
            }
            if optV {
                let root = "/" + usbPath.split(separator: "/").prefix(2).joined(separator: "/")
                info += "\n\n📄 Log: \(root)"
            }

            let alert = NSAlert()
            alert.messageText = self.errorsCount > 0 || !self.notFoundList.isEmpty
                ? "Sync mit Hinweisen beendet"
                : "✅  Sync abgeschlossen!"
            alert.alertStyle     = (!self.notFoundList.isEmpty || self.errorsCount > 0)
                ? .warning : .informational
            alert.informativeText = info
            alert.addButton(withTitle: "OK")
            alert.runModal()
            updateDockBadge(percent: -1)
            // Fenster bleibt offen — kein NSApp.terminate()
        }
    }
}

// ═══════════════════════════════════════════════════════════
// SYNC AUSFÜHREN
// ═══════════════════════════════════════════════════════════
func startSync(usbPath: String, macPath: String,
               optE: Bool, optV: Bool, optL: Bool, optN: Bool,
               optNewer: Bool,
               progressWC: ProgressWindowController) {
    let execURL     = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
    let contentsURL = execURL.deletingLastPathComponent().deletingLastPathComponent()
    let engine      = contentsURL.appendingPathComponent("Resources/usb_sync_engine.py").path

    let pythonCandidates = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
    let python = pythonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
                 ?? "/usr/bin/python3"

    let task = Process()
    task.executableURL = URL(fileURLWithPath: python)
    task.arguments     = ["-u", engine, usbPath, macPath,
                          optE ? "1":"0", optV ? "1":"0", optL ? "1":"0",
                          optN ? "1":"0", optNewer ? "1":"0"]
    let outPipe = Pipe(); let errPipe = Pipe()
    task.standardOutput = outPipe; task.standardError = errPipe
    var buffer = ""

    outPipe.fileHandleForReading.readabilityHandler = { handle in
        guard let chunk = String(data: handle.availableData, encoding: .utf8),
              !chunk.isEmpty else { return }
        buffer += chunk
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<nl])
            buffer   = String(buffer[buffer.index(after: nl)...])
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                progressWC.processLine(line)
            }
        }
    }
    errPipe.fileHandleForReading.readabilityHandler = { handle in
        guard let s = String(data: handle.availableData, encoding: .utf8), !s.isEmpty else { return }
        for line in s.components(separatedBy: "\n") where !line.isEmpty {
            progressWC.processLine("FEHLER: " + line)
        }
    }
    task.terminationHandler = { _ in
        if !buffer.isEmpty { progressWC.processLine(buffer) }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        progressWC.syncFinished(usbPath: usbPath, optV: optV)
    }
    do    { try task.run() }
    catch { progressWC.processLine("FEHLER beim Starten: \(error.localizedDescription)")
            progressWC.syncFinished(usbPath: usbPath, optV: optV) }
}

// ═══════════════════════════════════════════════════════════
// APP-DELEGATE
// ═══════════════════════════════════════════════════════════
class AppDelegate: NSObject, NSApplicationDelegate {
    var progressWC: ProgressWindowController?
    var startDlg:   StartDialogController?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        run()
    }

    func run() {
        var prefs = loadPrefs()

        let dlg = StartDialogController()
        self.startDlg = dlg
        dlg.buildAndShow(prefs: prefs)
        NSApp.runModal(for: dlg.panel)

        guard dlg.didStart else { NSApp.terminate(nil); return }

        let usbPath = dlg.tfUSB.stringValue.trimmingCharacters(in: .whitespaces)
        let macPath = dlg.tfMAC.stringValue.trimmingCharacters(in: .whitespaces)
        let optE    = dlg.cbE.state == .on
        let optV    = dlg.cbV.state == .on
        let optL    = dlg.cbL.state == .on

        // Verlauf aktualisieren
        addToHistory(usbPath, key: "usbHistory", prefs: &prefs)
        addToHistory(macPath, key: "macHistory", prefs: &prefs)
        let optN     = dlg.cbCopyNotFound.state == .on
        let optNewer = dlg.cbNewer.state == .on
        prefs["usbPath"]        = usbPath
        prefs["macPath"]        = macPath
        prefs["optE"]           = optE
        prefs["optV"]           = optV
        prefs["optL"]           = optL
        prefs["copyNotFound"]   = optN
        prefs["optNewer"]       = optNewer
        prefs["logCopied"]      = dlg.cbLogCopied.state   == .on
        prefs["logReplaced"]    = dlg.cbLogReplaced.state == .on
        prefs["logSkipped"]     = dlg.cbLogSkipped.state  == .on
        prefs["logNotFound"]    = dlg.cbLogNotFound.state == .on
        prefs["logErrors"]      = dlg.cbLogErrors.state   == .on
        savePrefs(prefs)

        // Löschen-Warnung
        if optL {
            let warn = NSAlert()
            warn.messageText    = "⚠️  ACHTUNG — LÖSCHEN AKTIV"
            warn.informativeText = "Erfolgreich kopierte Dateien und Ordner werden\nvom USB-Stick UNWIDERRUFLICH GELÖSCHT.\n\nWirklich fortfahren?"
            warn.alertStyle = .warning
            warn.addButton(withTitle: "Ja, Löschen aktiviert")
            warn.addButton(withTitle: "Nein, abbrechen")
            guard warn.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        }

        let wc = ProgressWindowController()
        wc.logCopied   = prefs["logCopied"]   as? Bool ?? true
        wc.logReplaced = prefs["logReplaced"] as? Bool ?? true
        wc.logSkipped  = prefs["logSkipped"]  as? Bool ?? true
        wc.logNotFound = prefs["logNotFound"] as? Bool ?? true
        wc.logErrors   = prefs["logErrors"]   as? Bool ?? true
        wc.show(usbPath: usbPath, macPath: macPath)
        self.progressWC = wc
        updateDockBadge(percent: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            startSync(usbPath: usbPath, macPath: macPath,
                      optE: optE, optV: optV, optL: optL, optN: optN,
                      optNewer: optNewer,
                      progressWC: wc)
        }
    }
}

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWEOF

# Swift kompilieren
echo "Kompiliere Swift-UI ..."
swiftc /tmp/USBSync_main.swift \
    -framework Cocoa \
    -o "${DEST}/Contents/MacOS/USBSync" \
    -O 2>&1

if [ $? -ne 0 ]; then
    echo ""
    echo "FEHLER: Swift-Kompilierung fehlgeschlagen."
    echo "Xcode Command Line Tools installiert?"
    echo "  xcode-select --install"
    exit 1
fi
echo "Swift kompiliert."

# ============================================================
# 4) Berechtigungen, Quarantäne & Ad-hoc-Signatur
# ============================================================
chmod -R 755 "${DEST}"
xattr -cr "${DEST}" 2>/dev/null || true

# Ad-hoc-Signatur ("-"): auf Apple Silicon zwingend erforderlich, damit die
# App ueberhaupt startet; auf Intel reduziert sie die Gatekeeper-Reibung.
if codesign --force --deep --sign - "${DEST}" 2>/dev/null; then
    echo "Ad-hoc signiert."
else
    echo "Hinweis: codesign nicht verfuegbar - App bleibt unsigniert."
fi

# ============================================================
# 5) Sauberes ZIP zur Weitergabe (ohne __MACOSX / ._* Reste)
# ============================================================
ZIP_DEST="$(dirname "${DEST}")/${APP_NAME}.app.zip"
rm -f "${ZIP_DEST}"
if /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "${DEST}" "${ZIP_DEST}"; then
    echo "ZIP erstellt: ${ZIP_DEST}"
fi

echo ""
echo "USBSync.app erfolgreich erstellt!"
echo ""
echo "Erster Start:"
echo "  Rechtsklick auf USBSync.app -> 'Öffnen'"
echo "  (einmalige Gatekeeper-Bestätigung)"
echo ""
echo "Einstellungen gespeichert unter:"
echo "  defaults: de.usbsync.prefs"