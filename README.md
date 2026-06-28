# Immich Desktop (macOS File Provider)

Bindet einen selbst gehosteten **Immich**-Server als Laufwerk in macOS ein.
Immich erscheint in der **Finder-Seitenleiste** und in jedem **Datei-Auswahldialog**
(z. B. beim Datei-Upload im Browser). Alben werden als Ordner dargestellt; die
Originaldateien werden **erst beim Oeffnen** vom Server geladen (on-demand).

Read-only: die App liest nur, sie veraendert nichts auf dem Server.

## Aufbau

| Pfad | Zweck |
|------|-------|
| `ImmichDesktop/` | Container-App (SwiftUI): Server-URL + API-Key eingeben, Domain aktivieren |
| `FileProviderExt/` | File Provider Extension (`NSFileProviderReplicatedExtension`) |
| `Shared/` | Immich-API-Client, Modelle, geteilte Konfiguration (App Group) |
| `project.yml` | XcodeGen-Projektdefinition |

## Voraussetzungen

1. **Vollstaendiges Xcode** (App Store) – die Command Line Tools allein genuegen
   nicht, um die Extension zu bauen und zu signieren.
2. **XcodeGen**: `brew install xcodegen`
3. Ein **Immich API-Key**: in Immich unter *Account Settings → API Keys* anlegen
   (Rechte: mindestens `asset.read`, `asset.download`, `album.read`).

## Bauen & Starten

```sh
cd immich-desktop-app
xcodegen generate          # erzeugt ImmichDesktop.xcodeproj aus project.yml
open ImmichDesktop.xcodeproj
```

In Xcode:

1. Beide Targets (`ImmichDesktop`, `FileProviderExt`) auswaehlen →
   *Signing & Capabilities* → unter **Team** deine Apple-ID / dein Personal Team
   waehlen. (Beide Targets brauchen dasselbe Team und dieselbe App Group
   `group.org.kartax.ImmichDesktop`.)
2. Schema `ImmichDesktop` waehlen, **Run** (⌘R).
3. Im App-Fenster Server-URL (z. B. `http://192.168.1.10:2283`) und API-Key
   eingeben → *Verbindung testen* → *Speichern & aktivieren*.
4. Finder oeffnen → in der Seitenleiste unter *Speicherorte* erscheint **Immich**.

## Hinweise zur kostenlosen Apple-ID

- Mit einer **kostenlosen** Apple-ID signierte Apps laufen nur **7 Tage**; danach
  muss die App in Xcode erneut gestartet werden (neu signieren). Fuer Dauerbetrieb
  empfiehlt sich ein bezahlter Developer-Account (Signatur 1 Jahr gueltig).
- App Groups funktionieren mit Personal Teams lokal; falls Xcode beim Aktivieren
  der App-Group-Capability meckert, die Group in beiden Targets identisch setzen
  und das Projekt neu bauen.

## Struktur im Finder

```
Immich/
├─ Alle Fotos/
│  └─ 2024/
│     └─ 03 März/
│        └─ IMG_1234.jpg ...
└─ <Albumname>/
   └─ IMG_5678.jpg ...
```

"Alle Fotos" nutzt die Immich-Timeline (`/timeline/buckets`) fuer die Jahr/Monat-
Struktur; die Assets eines Monats werden per `POST /search/metadata` (Datums-Range,
paginiert) geladen.

## Bekannte Grenzen (v1)

- Keine Vorschau-Thumbnails fuer noch nicht geladene Dateien (generisches Icon);
  nach dem ersten Oeffnen erzeugt der Finder die Vorschau aus dem Inhalt.
- Keine Aenderungsverfolgung (Sync-Anchor): neue/geloeschte Assets erscheinen erst
  nach erneuter Enumeration des Ordners.
