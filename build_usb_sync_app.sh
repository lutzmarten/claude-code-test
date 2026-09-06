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
// DESIGN-SYSTEM
// ═══════════════════════════════════════════════════════════
// Layer-gestuetzte Karte / Kachel, die ihre Farben bei jedem
// Appearance-Wechsel (Hell/Dunkel) selbst neu aufloest.
final class RoundView: NSView {
    var fill:   NSColor  = .clear     { didSet { needsDisplay = true } }
    var stroke: NSColor?              { didSet { needsDisplay = true } }
    var radius: CGFloat  = 10         { didSet { needsDisplay = true } }
    var clip:   Bool     = false      { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius  = radius
        layer?.cornerCurve   = .continuous
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth   = (stroke == nil) ? 0 : 1
        layer?.borderColor   = stroke?.cgColor
        layer?.masksToBounds = clip
    }

    convenience init(fill: NSColor, stroke: NSColor? = nil,
                     radius: CGFloat = 10, clip: Bool = false) {
        self.init(frame: .zero)
        self.fill = fill; self.stroke = stroke
        self.radius = radius; self.clip = clip
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
}

enum UI {
    static let cardFill:   NSColor = NSColor.controlBackgroundColor.withAlphaComponent(0.60)
    static let cardStroke: NSColor = .separatorColor

    static func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }
    static func title(_ s: String, size: CGFloat = 21) -> NSTextField {
        label(s, size: size, weight: .bold)
    }
    static func caption(_ s: String) -> NSTextField {
        label(s, size: 12, weight: .regular, color: .secondaryLabelColor)
    }
    static func section(_ s: String) -> NSTextField {
        let l = label(s.uppercased(), size: 11, weight: .semibold, color: .secondaryLabelColor)
        return l
    }
    static func fieldLabel(_ s: String) -> NSTextField {
        label(s, size: 12, weight: .semibold, color: .labelColor)
    }
    static func symbolImage(_ name: String, size: CGFloat = 13,
                            weight: NSFont.Weight = .regular) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }
    static func icon(_ name: String, size: CGFloat = 13, tint: NSColor = .secondaryLabelColor,
                     box: CGFloat = 16) -> NSImageView {
        let iv = NSImageView()
        iv.image = symbolImage(name, size: size)
        iv.contentTintColor = tint
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.setContentHuggingPriority(.required, for: .horizontal)
        iv.widthAnchor.constraint(equalToConstant: box).isActive = true
        iv.heightAnchor.constraint(equalToConstant: box).isActive = true
        return iv
    }
    static func glyphTile(_ name: String, dim: CGFloat = 40) -> NSView {
        let tile = RoundView(fill: .controlAccentColor, radius: 10)
        let iv = NSImageView()
        iv.image = symbolImage(name, size: 19, weight: .semibold)
        iv.contentTintColor = .white
        iv.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(iv)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: dim),
            tile.heightAnchor.constraint(equalToConstant: dim),
            iv.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }
    static func vstack(_ views: [NSView], spacing: CGFloat = 8,
                       align: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.spacing = spacing; s.alignment = align
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    static func hstack(_ views: [NSView], spacing: CGFloat = 8,
                       align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal; s.spacing = spacing; s.alignment = align
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    static func hHairline() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return b
    }
    static func vHairline() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return b
    }
    static func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        return v
    }
    static func card(_ inner: NSView, pad: CGFloat = 15) -> RoundView {
        let c = RoundView(fill: cardFill, stroke: cardStroke, radius: 10)
        inner.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: c.topAnchor, constant: pad),
            inner.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -pad),
            inner.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: pad),
            inner.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -pad),
        ])
        return c
    }
    static func visualBackground() -> NSVisualEffectView {
        let bg = NSVisualEffectView()
        bg.material = .windowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        return bg
    }
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
           let url = urls.first {
            stringValue = url.path
            sendAction(action, to: target)
            return true
        }
        if let str = s.draggingPasteboard.string(forType: .string) {
            stringValue = str.trimmingCharacters(in: .whitespaces)
            sendAction(action, to: target)
            return true
        }
        return false
    }
}

// ═══════════════════════════════════════════════════════════
// START-DIALOG
// ═══════════════════════════════════════════════════════════
class StartDialogController: NSObject, NSWindowDelegate {
    var panel:          NSPanel!
    var tfUSB:          DropTextField!
    var tfMAC:          DropTextField!
    var cbE, cbV, cbL, cbCopyNotFound, cbNewer: NSButton!
    var cbLogCopied, cbLogReplaced, cbLogSkipped, cbLogNotFound, cbLogErrors: NSButton!
    var usbWarnLabel:   NSTextField!
    var macWarnLabel:   NSTextField!
    var usbWarnIcon:    NSImageView!
    var macWarnIcon:    NSImageView!
    var didStart = false

    func buildAndShow(prefs: [String: Any]) {
        let usbHistory = prefs["usbHistory"] as? [String] ?? []
        let macHistory = prefs["macHistory"] as? [String] ?? []
        let defUSB = prefs["usbPath"] as? String ?? "/Volumes/Backup/Daten"
        let defMAC = prefs["macPath"] as? String ?? NSHomeDirectory() + "/Daten"

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 646),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.title = "USB Sync Tool"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 520, height: 588)
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = false

        let bg = UI.visualBackground()
        panel.contentView = bg

        // ── Hero ─────────────────────────────────────────────
        let heroText = UI.vstack([
            UI.title("USB Sync Tool"),
            UI.caption("Ordner vom USB-Stick auf den Mac abgleichen")
        ], spacing: 2)
        let hero = UI.hstack([UI.glyphTile("arrow.triangle.2.circlepath"), heroText], spacing: 12)

        // ── Pfade-Karte ──────────────────────────────────────
        tfUSB = makePathField(defUSB); tfUSB.action = #selector(usbPathChanged)
        tfMAC = makePathField(defMAC); tfMAC.action = #selector(macPathChanged)
        let usbHist = makeHistoryPopup(history: usbHistory, fieldTag: 200)
        let macHist = makeHistoryPopup(history: macHistory, fieldTag: 201)

        usbWarnLabel = UI.caption(""); usbWarnLabel.tag = 101
        macWarnLabel = UI.caption("")
        usbWarnIcon  = UI.icon("circle", tint: .clear, box: 14)
        macWarnIcon  = UI.icon("circle", tint: .clear, box: 14)

        let usbFieldRow = UI.hstack([tfUSB, usbHist], spacing: 8)
        let macFieldRow = UI.hstack([tfMAC, macHist], spacing: 8)
        let usbStatus   = UI.hstack([usbWarnIcon, usbWarnLabel], spacing: 5)
        let macStatus   = UI.hstack([macWarnIcon, macWarnLabel], spacing: 5)

        let pathInner = UI.vstack([
            UI.section("Pfade"),
            UI.fieldLabel("USB-Quelle"),  usbFieldRow, usbStatus,
            UI.hHairline(),
            UI.fieldLabel("Mac-Ziel"),    macFieldRow, macStatus,
        ], spacing: 7)
        pathInner.setCustomSpacing(12, after: usbStatus)
        pathInner.setCustomSpacing(12, after: pathInner.arrangedSubviews[4]) // after hairline
        let pathCard = UI.card(pathInner)

        // ── Optionen-Karte (2 Spalten) ───────────────────────
        cbE            = makeCheckbox("Vorhandene ersetzen  (-e)",        on: prefs["optE"]         as? Bool ?? false)
        cbV            = makeCheckbox("Log-Datei auf USB  (-v)",          on: prefs["optV"]         as? Bool ?? false)
        cbL            = makeCheckbox("Nach Kopie von USB löschen  (-l)", on: prefs["optL"]         as? Bool ?? false)
        cbCopyNotFound = makeCheckbox("Nicht gefundene anlegen  (-n)",    on: prefs["copyNotFound"] as? Bool ?? false)
        cbNewer        = makeCheckbox("Nur neuere Dateien  (-t)",         on: prefs["optNewer"]     as? Bool ?? false)

        cbLogCopied   = makeCheckbox("Kopiert",        on: prefs["logCopied"]   as? Bool ?? true)
        cbLogReplaced = makeCheckbox("Ersetzt",        on: prefs["logReplaced"] as? Bool ?? true)
        cbLogSkipped  = makeCheckbox("Übersprungen",   on: prefs["logSkipped"]  as? Bool ?? true)
        cbLogNotFound = makeCheckbox("Nicht gefunden", on: prefs["logNotFound"] as? Bool ?? true)
        cbLogErrors   = makeCheckbox("Fehler",         on: prefs["logErrors"]   as? Bool ?? true)

        let syncCol = UI.vstack([UI.section("Sync-Optionen"),
                                 cbE, cbV, cbL, cbCopyNotFound, cbNewer], spacing: 9)
        let logCol  = UI.vstack([UI.section("Protokoll-Filter"),
                                 cbLogCopied, cbLogReplaced, cbLogSkipped, cbLogNotFound, cbLogErrors], spacing: 9)
        let vsep = UI.vHairline()
        let cols = UI.hstack([syncCol, vsep, logCol], spacing: 20, align: .top)
        cols.distribution = .fill
        syncCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
        logCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            syncCol.widthAnchor.constraint(equalTo: logCol.widthAnchor),
            vsep.heightAnchor.constraint(equalTo: syncCol.heightAnchor),
        ])
        let optCard = UI.card(cols)

        // ── Fußzeile ─────────────────────────────────────────
        let btnCancel = NSButton(title: "Abbrechen", target: self, action: #selector(clickCancel))
        btnCancel.bezelStyle = .rounded
        btnCancel.controlSize = .large
        btnCancel.keyEquivalent = "\u{1B}"
        btnCancel.translatesAutoresizingMaskIntoConstraints = false

        let btnStart = NSButton(title: "Synchronisieren", target: self, action: #selector(clickStart))
        btnStart.bezelStyle = .rounded
        btnStart.controlSize = .large
        btnStart.keyEquivalent = "\r"
        btnStart.bezelColor = .controlAccentColor
        btnStart.translatesAutoresizingMaskIntoConstraints = false

        let footer = UI.hstack([UI.spacer(), btnCancel, btnStart], spacing: 10)
        footer.distribution = .fill

        // ── Root-Layout ──────────────────────────────────────
        let root = UI.vstack([hero, pathCard, optCard, footer], spacing: 18, align: .centerX)
        bg.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: bg.topAnchor, constant: 42),
            root.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: bg.bottomAnchor, constant: -18),
        ])
        for v in [hero, pathCard, optCard, footer] as [NSView] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        pathInner.widthAnchor.constraint(equalTo: pathCard.widthAnchor, constant: -30).isActive = true
        cols.widthAnchor.constraint(equalTo: optCard.widthAnchor, constant: -30).isActive = true
        for row in [usbFieldRow, macFieldRow] {
            row.widthAnchor.constraint(equalTo: pathInner.widthAnchor).isActive = true
        }
        tfUSB.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tfMAC.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSApp.mainMenu = buildMenuBar()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tfUSB)
        validateUSBPath()
        validateMacPath()
    }

    private func makePathField(_ value: String) -> DropTextField {
        let tf = DropTextField(frame: .zero)
        tf.stringValue = value
        tf.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tf.placeholderString = "Pfad eingeben oder Ordner hierher ziehen"
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.target = self
        tf.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return tf
    }

    // NSPopUpButton (Pull-Down) mit Verlauf-Eintraegen, als Icon-Knopf
    func makeHistoryPopup(history: [String], fieldTag: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.bezelStyle = .texturedRounded
        popup.imagePosition = .imageOnly
        popup.image = UI.symbolImage("clock.arrow.circlepath", size: 13)
        popup.tag = fieldTag
        popup.addItem(withTitle: "")            // verstecktes Titel-Item (Index 0)
        if history.isEmpty {
            popup.addItem(withTitle: "(kein Verlauf)")
            popup.item(at: 1)?.isEnabled = false
        } else {
            for path in history { popup.addItem(withTitle: path) }
        }
        popup.target = self
        popup.action = #selector(historyPopupSelected(_:))
        NSLayoutConstraint.activate([
            popup.widthAnchor.constraint(equalToConstant: 38),
            popup.heightAnchor.constraint(equalToConstant: 24),
        ])
        return popup
    }

    @objc func historyPopupSelected(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0 else { return }
        let path = sender.titleOfSelectedItem ?? ""
        guard !path.isEmpty && path != "(kein Verlauf)" else { return }
        if sender.tag == 200 { tfUSB.stringValue = path; validateUSBPath() }
        else                 { tfMAC.stringValue = path; validateMacPath() }
        sender.selectItem(at: 0)
    }

    func makeCheckbox(_ title: String, on: Bool) -> NSButton {
        let cb = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        cb.state = on ? .on : .off
        cb.font = .systemFont(ofSize: 12)
        cb.translatesAutoresizingMaskIntoConstraints = false
        return cb
    }

    @objc func usbPathChanged() { validateUSBPath() }
    @objc func macPathChanged() { validateMacPath() }

    private func applyStatus(_ raw: String, icon: NSImageView, label: NSTextField, kind: String) {
        let path = raw.trimmingCharacters(in: .whitespaces)
        if path.isEmpty {
            label.stringValue = ""
            icon.image = nil
            return
        }
        if FileManager.default.fileExists(atPath: path) {
            label.stringValue = "Pfad gefunden"
            label.textColor   = .secondaryLabelColor
            icon.contentTintColor = .systemGreen
            icon.image = UI.symbolImage("checkmark.circle.fill", size: 12)
        } else {
            label.stringValue = (kind == "USB")
                ? "Nicht gefunden – Stick eingesteckt?"
                : "Pfad existiert nicht auf diesem Mac"
            label.textColor   = .systemRed
            icon.contentTintColor = .systemRed
            icon.image = UI.symbolImage("exclamationmark.triangle.fill", size: 12)
        }
    }
    func validateUSBPath() { applyStatus(tfUSB.stringValue, icon: usbWarnIcon, label: usbWarnLabel, kind: "USB") }
    func validateMacPath() { applyStatus(tfMAC.stringValue, icon: macWarnIcon, label: macWarnLabel, kind: "Mac") }

    func buildMenuBar() -> NSMenu {
        let mb = NSMenu(); let ai = NSMenuItem(); mb.addItem(ai)
        let am = NSMenu(); ai.submenu = am
        am.addItem(NSMenuItem(title: "Beenden",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let ei = NSMenuItem(); mb.addItem(ei)
        let em = NSMenu(title: "Bearbeiten"); ei.submenu = em
        for (t, s, k) in [
            ("Ausschneiden",     #selector(NSText.cut(_:)),       "x"),
            ("Kopieren",         #selector(NSText.copy(_:)),      "c"),
            ("Einsetzen",        #selector(NSText.paste(_:)),     "v"),
            ("Alles auswählen",  #selector(NSText.selectAll(_:)), "a")] {
            em.addItem(NSMenuItem(title: t, action: s, keyEquivalent: k))
        }
        return mb
    }

    @objc func clickStart() {
        let usbPath = tfUSB.stringValue.trimmingCharacters(in: .whitespaces)
        let macPath = tfMAC.stringValue.trimmingCharacters(in: .whitespaces)
        if !FileManager.default.fileExists(atPath: usbPath) {
            let alert = NSAlert()
            alert.messageText     = "USB-Pfad nicht gefunden"
            alert.informativeText = "Der USB-Pfad existiert nicht:\n\(usbPath)\n\nBitte USB-Stick prüfen und Pfad korrigieren."
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        if !FileManager.default.fileExists(atPath: macPath) {
            let alert = NSAlert()
            alert.messageText     = "Mac-Pfad nicht gefunden"
            alert.informativeText = "Der Mac-Pfad existiert nicht:\n\(macPath)\n\nBitte korrigieren oder per Drag & Drop aus dem Finder einfügen."
            alert.alertStyle      = .warning
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
// FORTSCHRITTSFENSTER
// ═══════════════════════════════════════════════════════════
class ProgressWindowController: NSObject, NSWindowDelegate {
    var window:        NSWindow!
    var spinner:       NSProgressIndicator!
    var statusSymbol:  NSImageView!
    var titleLabel:    NSTextField!
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
    var logCard:       RoundView!
    var notFoundCard:  RoundView!
    var tabControl:    NSSegmentedControl!
    var footerLabel:   NSTextField!

    var copiedCount   = 0; var replacedCount = 0; var skippedCount  = 0
    var deletedCount  = 0; var errorsCount   = 0; var olderCount    = 0
    var totalFiles    = 0; var processedFiles = 0
    var notFoundList  = [String]()
    var olderList     = [String]()

    var logCopied   = true; var logReplaced = true
    var logSkipped  = true; var logNotFound = true; var logErrors = true

    func show(usbPath: String, macPath: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "USB Sync Tool – Synchronisierung läuft …"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let bg = UI.visualBackground()
        window.contentView = bg

        // ── Kopfzeile: Spinner/Haken + Titel + Pfad-Chips ────
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        statusSymbol = NSImageView()
        statusSymbol.image = UI.symbolImage("checkmark.circle.fill", size: 18, weight: .semibold)
        statusSymbol.contentTintColor = .systemGreen
        statusSymbol.translatesAutoresizingMaskIntoConstraints = false
        statusSymbol.isHidden = true

        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(spinner); iconSlot.addSubview(statusSymbol)
        NSLayoutConstraint.activate([
            iconSlot.widthAnchor.constraint(equalToConstant: 22),
            iconSlot.heightAnchor.constraint(equalToConstant: 22),
            spinner.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 18),
            spinner.heightAnchor.constraint(equalToConstant: 18),
            statusSymbol.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            statusSymbol.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            statusSymbol.widthAnchor.constraint(equalToConstant: 20),
            statusSymbol.heightAnchor.constraint(equalToConstant: 20),
        ])

        titleLabel = UI.label("Synchronisierung läuft …", size: 16, weight: .semibold)

        let usbChip = pathChip("externaldrive", usbPath)
        let macChip = pathChip("laptopcomputer", macPath)
        let chips = UI.vstack([usbChip, macChip], spacing: 2)
        let headText = UI.vstack([titleLabel, chips], spacing: 5)
        let header = UI.hstack([iconSlot, headText], spacing: 10, align: .centerY)

        // ── Fortschrittsbalken ───────────────────────────────
        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.minValue = 0; progressBar.maxValue = 100
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.startAnimation(nil)
        progressBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        percentLabel = UI.label("—", size: 12, weight: .medium)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        percentLabel.alignment = .right
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        percentLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let progRow = UI.hstack([progressBar, percentLabel], spacing: 10)

        statusLabel = UI.label("Wird vorbereitet …", size: 11, color: .secondaryLabelColor)
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail

        let progBlock = UI.vstack([progRow, statusLabel], spacing: 6)

        // ── Statistik-Kacheln ────────────────────────────────
        let (copiedC,   copiedV)   = statCard("doc.on.doc",                 "Kopiert",      .controlAccentColor)
        let (replacedC, replacedV) = statCard("arrow.triangle.2.circlepath","Ersetzt",      .systemOrange)
        let (skippedC,  skippedV)  = statCard("arrow.forward",              "Übersprungen", .systemGray)
        let (deletedC,  deletedV)  = statCard("trash",                      "Gelöscht",     .labelColor)
        let (olderC,    olderV)    = statCard("clock",                      "Älter",        .systemPurple)
        let (errorsC,   errorsV)   = statCard("exclamationmark.triangle",   "Fehler",       .systemRed)
        copiedLabel = copiedV; replacedLabel = replacedV; skippedLabel = skippedV
        deletedLabel = deletedV; olderLabel = olderV; errorsLabel = errorsV

        let stats = UI.hstack([copiedC, replacedC, skippedC, deletedC, olderC, errorsC], spacing: 10, align: .centerY)
        stats.distribution = .fillEqually

        // ── Umschalter ───────────────────────────────────────
        tabControl = NSSegmentedControl(
            labels: ["Protokoll", "Nicht gefunden"],
            trackingMode: .selectOne, target: self, action: #selector(tabChanged))
        tabControl.selectedSegment = 0
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        // ── Protokoll / Nicht-gefunden ───────────────────────
        scrollView     = makeScrollView(); logView      = scrollView.documentView as? NSTextView
        notFoundScroll = makeScrollView(); notFoundView = notFoundScroll.documentView as? NSTextView
        logCard      = wrapScroll(scrollView)
        notFoundCard = wrapScroll(notFoundScroll)
        notFoundCard.isHidden = true

        let logSlot = NSView()
        logSlot.translatesAutoresizingMaskIntoConstraints = false
        for c in [logCard!, notFoundCard!] {
            logSlot.addSubview(c)
            NSLayoutConstraint.activate([
                c.topAnchor.constraint(equalTo: logSlot.topAnchor),
                c.bottomAnchor.constraint(equalTo: logSlot.bottomAnchor),
                c.leadingAnchor.constraint(equalTo: logSlot.leadingAnchor),
                c.trailingAnchor.constraint(equalTo: logSlot.trailingAnchor),
            ])
        }
        logSlot.setContentHuggingPriority(.defaultLow, for: .vertical)
        logSlot.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        logSlot.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        footerLabel = UI.caption("Bitte warten – Fenster nicht schließen")
        footerLabel.alignment = .center
        let footHair = UI.hHairline()

        // ── Root-Layout ──────────────────────────────────────
        let root = UI.vstack([header, progBlock, stats, tabControl, logSlot, footHair, footerLabel],
                             spacing: 14, align: .centerX)
        bg.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: bg.topAnchor, constant: 42),
            root.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -22),
            root.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -16),
        ])
        for v in [header, progBlock, stats, logSlot, footHair, footerLabel] as [NSView] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        progRow.widthAnchor.constraint(equalTo: progBlock.widthAnchor).isActive = true
        headText.setContentHuggingPriority(.defaultLow, for: .horizontal)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pathChip(_ symbol: String, _ text: String) -> NSStackView {
        let iv = UI.icon(symbol, size: 11, tint: .secondaryLabelColor, box: 13)
        let l = UI.label(text, size: 11, color: .secondaryLabelColor)
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.lineBreakMode = .byTruncatingMiddle
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return UI.hstack([iv, l], spacing: 5)
    }

    private func statCard(_ symbol: String, _ caption: String, _ color: NSColor) -> (RoundView, NSTextField) {
        let val = UI.label("0", size: 26, weight: .semibold, color: color)
        val.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        let sym = UI.icon(symbol, size: 11, tint: .secondaryLabelColor, box: 13)
        let cap = UI.label(caption, size: 11, color: .secondaryLabelColor)
        let capRow = UI.hstack([sym, cap], spacing: 4)
        let inner = UI.vstack([val, capRow], spacing: 3)
        let card = RoundView(fill: UI.cardFill, stroke: UI.cardStroke, radius: 9)
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 13),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -10),
            card.heightAnchor.constraint(equalToConstant: 66),
        ])
        return (card, val)
    }

    func makeScrollView() -> NSScrollView {
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.drawsBackground = true
        sv.backgroundColor = .textBackgroundColor
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        sv.documentView = tv
        return sv
    }

    private func wrapScroll(_ sv: NSScrollView) -> RoundView {
        let c = RoundView(fill: .textBackgroundColor, stroke: UI.cardStroke, radius: 10, clip: true)
        c.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: c.topAnchor, constant: 1),
            sv.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -1),
            sv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 1),
            sv.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -1),
        ])
        return c
    }

    @objc func tabChanged() {
        logCard.isHidden      = tabControl.selectedSegment != 0
        notFoundCard.isHidden = tabControl.selectedSegment != 1
    }

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
                if let r = line.range(of: "NOTFOUND_LIST:") {
                    let names = String(line[r.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: "|")
                        .filter { !$0.isEmpty }
                    let summary = NSAttributedString(
                        string: "\n── \(names.count) Einträge ──\n",
                        attributes: [.font: NSFont.boldSystemFont(ofSize: 12),
                                     .foregroundColor: NSColor.systemRed])
                    self.notFoundView.textStorage?.insert(summary, at: 0)
                }
                return
            } else if line.contains("NOTFOUND_COPIED:") {
                if let r = line.range(of: "NOTFOUND_COPIED:") {
                    let name = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    self.notFoundList.append(name)
                    self.tabControl.setLabel("Nicht gefunden (\(self.notFoundList.count))", forSegment: 1)
                    self.appendNotFound(name, copied: true)
                }
                if !self.logNotFound { return }
            } else if line.contains("NOTFOUND:") && !line.contains("NOTFOUND_") {
                if let r = line.range(of: "NOTFOUND:") {
                    let name = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    self.notFoundList.append(name)
                    self.tabControl.setLabel("Nicht gefunden (\(self.notFoundList.count))", forSegment: 1)
                    self.appendNotFound(name, copied: false)
                }
                if !self.logNotFound { return }
            } else if line.contains("NICHT GEFUNDEN") {
                if !self.logNotFound { return }
            }

            if line.contains("KOPIERT:") || line.contains("ERSETZT:") {
                if let r = line.range(of: ":  ") ?? line.range(of: ": ") {
                    self.statusLabel.stringValue =
                        URL(fileURLWithPath: String(line[r.upperBound...])).lastPathComponent
                }
            } else if line.contains("ORDNER ERSTELLT:") {
                if let r = line.range(of: "ORDNER ERSTELLT: ") {
                    self.statusLabel.stringValue = "Ordner: " + String(line[r.upperBound...])
                }
            }

            if line.contains("OLDER:") && !line.contains("OLDER_LIST") {
                if let r = line.range(of: "OLDER:") {
                    let name = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    self.olderCount += 1
                    self.olderLabel.stringValue = "\(self.olderCount)"
                    self.olderList.append(name)
                }
                return
            }

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
                            string: "•  \(n)\n",
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
        let note  = copied ? "  (→ in Mac-Ziel angelegt)" : "  (übersprungen)"
        let color = copied ? NSColor.systemBlue : NSColor.systemOrange
        storage.append(NSAttributedString(
            string: "•  \(name)\(note)\n",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: color]))
    }

    func syncFinished(usbPath: String, optV: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.statusSymbol.isHidden = false

            self.progressBar.doubleValue = 100
            self.percentLabel.stringValue = "100 %"
            self.window.title = "USB Sync Tool – abgeschlossen"
            self.titleLabel.stringValue = "Synchronisierung abgeschlossen"
            self.titleLabel.textColor = .systemGreen
            self.statusLabel.stringValue = "Fertig."
            updateDockBadge(percent: 100)
            self.footerLabel?.stringValue = "Sync abgeschlossen – Fenster kann geschlossen werden"
            self.footerLabel?.textColor = .secondaryLabelColor

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
                        string: "  •  \(name)\n", attributes: olderItemAttrs))
                }
                self.logView.textStorage?.append(NSAttributedString(string: olderSep, attributes: olderAttrs))
                self.logView.scrollToEndOfDocument(nil)
            }

            if !self.notFoundList.isEmpty {
                let isCopied = self.notFoundList.allSatisfy { _ in
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
                        string: "  •  \(name)\n", attributes: itemAttrs))
                }
                logStorage.append(NSAttributedString(string: separator, attributes: blockAttrs))
                self.logView.scrollToEndOfDocument(nil)

                let summary = NSAttributedString(
                    string: "\n── \(self.notFoundList.count) Einträge ──\n",
                    attributes: blockAttrs)
                self.notFoundView.textStorage?.insert(summary, at: 0)
            }

            var info = "Kopiert (neu):    \(self.copiedCount)\n" +
                       "Ersetzt:          \(self.replacedCount)\n" +
                       "Übersprungen:     \(self.skippedCount)\n" +
                       "Gelöscht:         \(self.deletedCount)\n" +
                       "Ältere Dateien:   \(self.olderCount)\n" +
                       "Fehler:           \(self.errorsCount)"
            if !self.notFoundList.isEmpty {
                info += "\nNicht gefunden:   \(self.notFoundList.count)\n"
                info += "   " + self.notFoundList.joined(separator: "\n   ")
            }
            if optV {
                let root = "/" + usbPath.split(separator: "/").prefix(2).joined(separator: "/")
                info += "\n\nLog: \(root)"
            }

            let alert = NSAlert()
            alert.messageText = (self.errorsCount > 0 || !self.notFoundList.isEmpty)
                ? "Sync mit Hinweisen beendet"
                : "Sync abgeschlossen"
            alert.alertStyle = (!self.notFoundList.isEmpty || self.errorsCount > 0)
                ? .warning : .informational
            alert.informativeText = info
            alert.addButton(withTitle: "OK")
            alert.runModal()
            updateDockBadge(percent: -1)
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

        if optL {
            let warn = NSAlert()
            warn.messageText     = "Achtung – Löschen aktiv"
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
# Quarantäne / Extended Attributes rekursiv entfernen. Nicht "xattr -r"
# verwenden — das Python-basierte xattr mancher macOS-Versionen kennt die
# Option nicht; find ist portabel.
find "${DEST}" -exec xattr -c {} \; 2>/dev/null || true

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