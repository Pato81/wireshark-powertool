# wireshark-powertool

Ein menügeführtes Bash-Framework rund um `tshark`/Wireshark für strukturiertes
Mitschneiden, Analysieren und Dokumentieren von Netzwerkverkehr – für Lab-Umgebungen
und autorisierte Security-Tests.

> ⚠️ **Nur für die eigene Lab-Umgebung oder mit ausdrücklicher Erlaubnis.**
> Das Mitschneiden fremden Netzwerkverkehrs ohne Einwilligung ist in Deutschland
> u. a. nach § 202a StGB strafbar. Die Nutzung erfolgt auf eigene Verantwortung.

---

## Warum dieses Tool?

Packet Capturing und -analyse bestehen aus vielen kleinen `tshark`-Aufrufen, die
man sich schwer merkt. `wireshark-powertool` fasst die wiederkehrenden Aufgaben –
aufzeichnen, auswerten, exportieren – in einem Menü zusammen, mit automatischer
Projektablage und Capture-Historie. Der Fokus liegt auf **Analyse und Forensik**.

## Funktionen

**Live Capture**
- Vollständiger Mitschnitt oder gezielte BPF-Filter (Web, DNS, ARP, Klartext-Protokolle)
- Zeitlich begrenzte Aufzeichnung und **Ringpuffer** für Langzeit-Monitoring
- Bluetooth-Capture, direkter Start der Wireshark-GUI

**Analyse gespeicherter Captures**
- Protokoll-Hierarchie, Conversations/Endpoints, TCP/UDP-Stream-Following
- **TLS-/SNI-Analyse** (ClientHello-Hostnamen, Zertifikatsdetails bei TLS ≤ 1.2)
- HTTP-Objekt-Extraktion (Dateien aus dem Traffic ziehen)
- **ARP-Spoofing-Erkennung** – findet IPs, denen mehrere MAC-Adressen zugeordnet sind
- Klartext-Credential-Suche in unverschlüsselten Protokollen (read-only)
- CSV-Export zur Weiterverarbeitung in Reports

**Dateiverwaltung**
- Captures zusammenführen (`mergecap`), per Anzeigefilter speichern, `capinfos`, Historie

## Voraussetzungen

- `tshark` / `wireshark` (inkl. `mergecap`, `capinfos`)
- `aircrack-ng` (`airdecap-ng`, nur für die WPA-Entschlüsselung bekannter Captures)
- `libnotify-bin` (`notify-send`, optional)

Getestet unter Kali Linux.

## Nutzung

```bash
chmod +x wireshark-powertool.sh
./wireshark-powertool.sh
```

Das Skript fordert `sudo` einmalig an (nötig für Live-Capture), fragt Interface und
Projekt ab und führt dann durch Capture, Analyse und Dateiverwaltung.

## Technik-Highlights

- Durchgängiges **Dispatch-Tabellen-Menü** (`run_menu` + `"Label|funktion"`-Einträge)
- `set -uo pipefail`, zentrales Logging mit Rotation, `trap`-basiertes Cleanup
- Projekt-Integration (`engagements/<name>/loot/analyse`) und Capture-Historie
- Strikte Eingabe-/Interface-Validierung

---

## Hinweis zu diesem Repository

Teil meines Portfolios als angehender Junior Penetration Tester – zur Einsicht in
meinen Arbeits- und Programmierstil. Der Code steht **nicht** unter einer
Open-Source-Lizenz – siehe [LICENSE](LICENSE).

**Patrick May** · [LinkedIn](https://www.linkedin.com/in/patrick-may-664867367) · p.may.1981@web.de
