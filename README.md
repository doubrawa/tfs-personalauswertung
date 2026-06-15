# TFS Personalauswertung

Erzeugt aus einem **lokalen TFS / Azure DevOps Server** (mit TFVC) einen optisch
aufbereiteten **HTML-Report** als Leistungsüberblick – ideal z. B. zur Vorbereitung
auf ein Personalgespräch. Reines PowerShell, keine Installation, keine externen
Abhängigkeiten; die Diagramme sind Inline-SVG (funktioniert offline, druckbar als PDF).

Zusätzlich gibt es einen **Vergleichsmodus für zwei Entwickler** mit fairer
Normierung auf Vollzeit (Teilzeit/Vollzeit vergleichbar).

> Hinweis: Die generierten HTML-Reports enthalten echte Projekt-/Personendaten und
> gehören **nicht** ins Repository (siehe `.gitignore`).

## Voraussetzungen

- Windows mit **PowerShell 5.1+**
- Zugang zu einem **TFS / Azure DevOps Server** (on-premise) mit **TFVC**
- Gepflegte Work-Item-Felder `OriginalEstimate` / `CompletedWork` (für die Aufwands-Kennzahlen)

## Schnellstart

```powershell
# Layout mit Beispieldaten ansehen (kein Server nötig):
.\TfsPersonalReport.ps1 -Demo -Open

# Vergleichslayout mit Beispieldaten:
.\TfsPersonalReport.ps1 -Demo -Compare -Open
```

## Einzel-Report

```powershell
# Mit angemeldetem Windows-Benutzer (integrierte Authentifizierung):
.\TfsPersonalReport.ps1 -CollectionUrl "http://tfs-server:8080/tfs/DefaultCollection" -Project "MeinProjekt" -Open

# Ohne -Project: über die gesamte Collection (alle Projekte)
.\TfsPersonalReport.ps1 -CollectionUrl "http://tfs-server:8080/tfs/DefaultCollection" -Open
```

Der Report enthält: KPI-Karten, „Geplant vs. tatsächlich" pro Monat, größte
Schätzabweichungen, Termintreue, erledigte Aufgaben pro Monat, Code-Aktivität (TFVC)
und eine Detailtabelle aller Aufgaben.

## Zwei Entwickler vergleichen

```powershell
$cred = Get-Credential   # falls Windows-Login nicht greift (Basic-Auth)
.\TfsPersonalReport.ps1 -CollectionUrl "http://tfs-server:8080/tfs/DefaultCollection" -Credential $cred -Open -Developers @(
  @{ Name='Entwickler A'; AssignedTo='@Me';           Tfvc='DOMAIN\usera'; Hours=25 },
  @{ Name='Entwickler B'; AssignedTo='Vorname Nachname'; Tfvc='DOMAIN\userb'; Hours=40 }
)
```

Jeder Eintrag:
- `Name` – Anzeige im Report
- `AssignedTo` – Wert für die Work-Item-Abfrage (Anzeigename oder `@Me`)
- `Tfvc` – TFVC-Konto für die Changeset-Suche (z. B. `DOMAIN\user`)
- `Hours` – Wochenarbeitszeit (für die faire Normierung)

**Faire Normierung:** Output-Kennzahlen (Aufgaben, Changesets, Dateien) werden auf
Vollzeit hochgerechnet (Standard 40 h, änderbar via `-FteHours`), damit Teilzeit und
Vollzeit fair vergleichbar sind. Der absolute Wert bleibt sichtbar. Quoten
(Schätzgenauigkeit, Termintreue) und Stundenwerte werden **nicht** hochgerechnet.
Zusätzlich enthält der Vergleichsreport pro Entwickler einen vollständigen Detailblock.

## Parameter (Auswahl)

| Parameter | Bedeutung | Standard |
|---|---|---|
| `-CollectionUrl` | Basis-URL der Collection | – (Pflicht, außer `-Demo`) |
| `-Project` | Team-Projekt (weglassen = ganze Collection) | – |
| `-Months` | Zeitraum rückwirkend in Monaten | `12` |
| `-Credential` | `PSCredential` für Basic-Auth (Benutzer:Passwort) | – |
| `-Pat` | Personal Access Token (Alternative zu Credential) | – |
| `-TfvcAuthor` | TFVC-Autor für Einzel-Report | aktueller Windows-Benutzer |
| `-Developers` | Liste von 2 Entwicklern → Vergleichsmodus | – |
| `-FteHours` | Vollzeit-Referenz für die Normierung | `40` |
| `-ApiVersion` | REST-API-Version | `5.0` |
| `-IncludeChangesetFiles` | zählt geänderte Dateien je Changeset (langsamer) | aus |
| `-SkipCertCheck` | ignoriert Zertifikatsfehler (selbstsigniertes HTTPS) | aus |
| `-Demo` / `-Compare` | Beispieldaten / Vergleichslayout | aus |
| `-Open` | Report nach Erstellung öffnen | aus |

## Authentifizierung

- **Integriert (Standard):** angemeldeter Windows-Benutzer (NTLM/Kerberos).
- **Personal Access Token:** `-Pat "<token>"` (TFS 2017+).
- **Basic (Benutzer:Passwort):** `-Credential (Get-Credential)` – nötig, wenn der
  Server nur `Basic` anbietet (z. B. extern erreichbare Server ohne NTLM).

## Troubleshooting

- **ExecutionPolicy:** `powershell -ExecutionPolicy Bypass -File .\TfsPersonalReport.ps1 -Demo -Open`
- **Alte Server / API-Fehler:** `-ApiVersion` senken (TFS 2015 → `2.0`, 2017 → `3.0`, 2018 → `4.1`, DevOps Server 2019+ → `5.0`).
- **HTTPS-Zertifikat:** `-SkipCertCheck`.
- **Deutsche Status:** „Geschlossen/Erledigt/Behoben/Abgeschlossen/Fertig" werden erkannt; weitere bei Bedarf in `$doneStates` ergänzen.
- **Changesets leer:** `-TfvcAuthor` exakt auf die TFVC-Kennung (`DOMAIN\konto`) setzen.

## Web-Oberfläche (Browser)

Zusätzlich zum PowerShell-Skript gibt es eine Weboberfläche: TFS-Adresse eingeben →
**„Entwickler laden"** → zwei Entwickler + Wochenstunden wählen → **„Vergleich starten"**.
Der Report (faire, auf Vollzeit normierte Kennzahlen + Monatsdiagramme) erscheint direkt
auf der Seite.

Aufbau (zwei Teile):
- **`docs/`** – statisches Frontend (HTML/CSS/JS), für **GitHub Pages** geeignet.
- **`server/`** – kleiner **Proxy-Backend** (Node, abhängigkeitsfrei).

**Warum ein Backend?** GitHub Pages liefert nur statische Dateien, und ein Browser darf
einen internen TFS-Server wegen **CORS** normalerweise nicht direkt per JavaScript abfragen.
Der Proxy setzt CORS-Header und spricht serverseitig per REST mit dem TFS. Zugangsdaten
werden nur durchgereicht (TFS Basic-Auth), **nie gespeichert**.

> 🔒 Den Proxy **selbst hosten** (lokal oder im Firmennetz) – nicht öffentlich anbieten,
> da er TFS-Zugangsdaten entgegennimmt.

### Lokal starten (Frontend + Backend in einem Prozess)

```bash
cd server
node server.js
# dann im Browser: http://localhost:8787
```

Tipp: Die **Demo-Modus**-Checkbox zeigt die Oberfläche mit Beispieldaten – ganz ohne TFS.

### GitHub Pages + separat gehostetes Backend

1. Pages aktivieren: Repo → *Settings → Pages* → Branch `main`, Ordner `/docs`.
2. Den Proxy (`server/server.js`) irgendwo erreichbar hosten (lokal, Firmenserver, VM/Container).
3. Auf der Pages-Seite im Feld **„Backend-URL"** die Adresse deines Proxys eintragen.

> Status: Die Web-UI zeigt die Vergleichs-Kennzahlen + drei Monatsdiagramme. Die
> ausführlichen Einzel-Detailblöcke (Schätzabweichungen, Detailtabellen) gibt es derzeit
> nur im PowerShell-Report – sie lassen sich später nachziehen.

## Lizenz

[MIT](LICENSE)
