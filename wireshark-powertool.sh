#!/bin/bash
# =====================================================
# WIRESHARK POWER TOOL       
# Live-Capture, Analyse, Klartext-Credential-Suche,
# Datei-Extraktion, Merge, Projekt-Integration
# (c) Patrick May 2026 - All rights reserved (portfolio use)
# NUR für eigene Lab-Umgebung / autorisierte Tests!
# =====================================================

set -uo pipefail

# =====================================================
# STATE
# =====================================================
readonly LOGFILE="$HOME/wireshark_pato.log"
readonly LOG_MAX_BYTES=5242880  # 5 MB
readonly CONFIGFILE="$HOME/.wireshark_pato.conf"
readonly ENGAGEMENTS_DIR="$HOME/engagements"
readonly HISTORY_FILE="$HOME/.wireshark_pato_history.log"

IFACE=""
LOOT_DIR=""
ANALYSIS_DIR=""

# =====================================================
# FARBEN
# =====================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# =====================================================
# BASIS-HELFER
# =====================================================

rotate_log_if_needed() {
    if [ -f "$LOGFILE" ]; then
        local size
        size=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
        [ "$size" -gt "$LOG_MAX_BYTES" ] && mv -f "$LOGFILE" "${LOGFILE}.old"
    fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

msg() {
    echo -e "$1"
    log "$(echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g')"
}

die() {
    msg "${RED}[FATAL] $1${NC}"
    exit 1
}

warn_fail() {
    msg "${RED}[FEHLER] $1${NC}"
    return 1
}

pause() {
    read -rp "Drücke ENTER zum Fortfahren..."
}

check_tool() {
    command -v "$1" &>/dev/null
}

require_tools() {
    local missing=()
    for tool in "$@"; do
        check_tool "$tool" || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn_fail "Fehlende Programme: ${missing[*]}"
        msg "${YELLOW}Installiere mit: sudo apt install ${missing[*]} -y${NC}"
        return 1
    fi
    return 0
}

require_root_actions() {
    if [ "$EUID" -eq 0 ]; then
        die "Bitte NICHT als root starten. Das Skript nutzt sudo gezielt nur wo nötig."
    fi
}

notify() {
    check_tool notify-send && notify-send "Wireshark Power Tool" "$1" 2>/dev/null
}

# =====================================================
# INTERFACE-AUSWAHL
# =====================================================
# Nutzt tshark -D (braucht Root-Rechte für vollständige Liste inkl. Monitor-
# Mode-Interfaces). Merkt sich die letzte Wahl in CONFIGFILE.
select_interface() {
    if [ -f "$CONFIGFILE" ]; then
        local saved
        saved=$(cat "$CONFIGFILE")
        if ip link show "$saved" &>/dev/null; then
            read -rp "Zuletzt genutztes Interface '$saved' wieder verwenden? (J/n): " reuse
            if [[ ! "$reuse" =~ ^[Nn]$ ]]; then
                IFACE="$saved"
                msg "${GREEN}[+] Interface: $IFACE${NC}"
                return 0
            fi
        fi
    fi

    require_tools tshark || return 1
    msg "${CYAN}[*] Verfügbare Capture-Interfaces:${NC}"
    sudo tshark -D 2>/dev/null

    read -rp "Welches Interface? (Name, z.B. wlan1, eth0): " choice
    if [ -z "$choice" ] || ! ip link show "$choice" &>/dev/null; then
        warn_fail "Ungültiges oder unbekanntes Interface: $choice"
        return 1
    fi
    IFACE="$choice"
    echo "$IFACE" > "$CONFIGFILE"
    msg "${GREEN}[+] Interface gesetzt: $IFACE (gespeichert)${NC}"
}

action_reselect_interface() {
    rm -f "$CONFIGFILE"
    select_interface
}

# =====================================================
# PROJEKT-INTEGRATION
# =====================================================
select_project() {
    mkdir -p "$ENGAGEMENTS_DIR"
    echo -e "${CYAN}Vorhandene Projekte:${NC}"
    local projects=("$ENGAGEMENTS_DIR"/*/)
    local names=() i=1
    for p in "${projects[@]}"; do
        [ -d "$p" ] || continue
        names+=("$(basename "$p")")
        echo "  $i) ${names[-1]}"
        ((i++))
    done
    echo "  n) Neues Projekt anlegen"
    read -rp "Projekt wählen (Nummer oder 'n'): " sel

    if [ "$sel" = "n" ]; then
        read -rp "Name des neuen Projekts: " newname
        newname=$(echo "$newname" | tr ' ' '_')
        mkdir -p "$ENGAGEMENTS_DIR/$newname"/{recon,exploit,loot,report}
        LOOT_DIR="$ENGAGEMENTS_DIR/$newname/loot"
    else
        local idx=$((sel - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#names[@]} ]; then
            LOOT_DIR="$ENGAGEMENTS_DIR/${names[$idx]}/loot"
            mkdir -p "$LOOT_DIR"
        else
            msg "${YELLOW}Ungültige Auswahl, nutze Standard-Ordner.${NC}"
            LOOT_DIR="$ENGAGEMENTS_DIR/default/loot"
            mkdir -p "$LOOT_DIR"
        fi
    fi
    ANALYSIS_DIR="$LOOT_DIR/analyse"
    mkdir -p "$ANALYSIS_DIR"
    msg "${GREEN}[+] Loot-Verzeichnis: $LOOT_DIR${NC}"
}

action_switch_project() {
    select_project
}

# =====================================================
# DATEI-AUSWAHL (wiederverwendbar für alle Analyse-Aktionen)
# =====================================================
# Sucht Capture-Dateien im GESAMTEN engagements-Baum (nicht nur aktuelles
# Projekt), damit z.B. auch Handshake-Dateien aus dem WLAN-Skript gefunden
# werden. Setzt bei Erfolg SELECTED_CAPTURE.
choose_capture_file() {
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$ENGAGEMENTS_DIR" \( -name "*.pcap" -o -name "*.pcapng" -o -name "*.cap" \) 2>/dev/null | sort
    )
    if [ ${#files[@]} -eq 0 ]; then
        warn_fail "Keine Capture-Dateien (.pcap/.pcapng/.cap) in $ENGAGEMENTS_DIR gefunden."
        return 1
    fi
    echo -e "${CYAN}Verfügbare Capture-Dateien:${NC}"
    local i=1
    for f in "${files[@]}"; do
        echo "  $i) $f"
        ((i++))
    done
    read -rp "Welche Datei? (Nummer): " sel
    local idx=$((sel - 1))
    { [ "$idx" -ge 0 ] && [ "$idx" -lt ${#files[@]} ]; } || { warn_fail "Ungültige Auswahl."; return 1; }
    SELECTED_CAPTURE="${files[$idx]}"
    return 0
}

# =====================================================
# AKTIONEN: LIVE CAPTURE
# =====================================================

# Gemeinsame Capture-Routine: nimmt Capture-Filter (BPF) + Dateipräfix,
# speichert IMMER echte Datei im Loot-Ordner, trägt sie in die Historie ein.
run_capture() {
    local label="$1" bpf_filter="$2"
    [ -n "$IFACE" ] || { warn_fail "Kein Interface gewählt."; return 1; }

    local timestamp


    timestamp=$(date +%Y%m%d_%H%M%S)


    local outfile="$LOOT_DIR/${label}_${timestamp}.pcapng"
    msg "${YELLOW}[*] Capture läuft auf $IFACE${bpf_filter:+ (Filter: $bpf_filter)}...${NC}"
    msg "${CYAN}Beende mit Strg+C.${NC}"
    sleep 1

    if [ -n "$bpf_filter" ]; then
        sudo tshark -i "$IFACE" -f "$bpf_filter" -w "$outfile"
    else
        sudo tshark -i "$IFACE" -w "$outfile"
    fi

    if [ -s "$outfile" ]; then
        sudo chown "$USER:$USER" "$outfile" 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') | $label | $IFACE | $outfile" >> "$HISTORY_FILE"
        msg "${GREEN}✅ Capture gespeichert: $outfile${NC}"
        notify "Capture '$label' beendet"
        read -rp "Jetzt in Wireshark-GUI öffnen? (j/N): " open_gui
        [[ "$open_gui" =~ ^[Jj]$ ]] && { require_tools wireshark && wireshark "$outfile" & }
    else
        warn_fail "Keine Daten aufgezeichnet oder Capture abgebrochen."
    fi
}

action_capture_all() {
    require_tools tshark || return 1
    [ -n "$IFACE" ] || select_interface || return 1
    run_capture "all" ""
}

action_capture_web() {
    require_tools tshark || return 1
    [ -n "$IFACE" ] || select_interface || return 1
    run_capture "web" "port 80 or port 443"
}

action_capture_dns() {
    require_tools tshark || return 1
    [ -n "$IFACE" ] || select_interface || return 1
    run_capture "dns" "port 53"
}

action_capture_arp() {
    require_tools tshark || return 1
    [ -n "$IFACE" ] || select_interface || return 1
    run_capture "arp" "arp"
}

action_capture_unencrypted() {
    require_tools tshark || return 1
    [ -n "$IFACE" ] || select_interface || return 1
    msg "${CYAN}Erfasst klassische Klartext-Protokolle: FTP, Telnet, HTTP, POP3, IMAP.${NC}"
    run_capture "unencrypted" "port 21 or port 23 or port 80 or port 110 or port 143"
}

action_capture_custom_filter() {
    require_tools tshark || return 1
    [ -n "$IFACE" ] || select_interface || return 1
    read -rp "BPF Capture-Filter (z.B. 'host 192.168.1.1 and tcp'): " filt
    run_capture "custom" "$filt"
}

action_capture_timed() {
    require_tools tshark || return 1
    [ -n "$IFACE" ] || select_interface || return 1
    read -rp "Dauer in Sekunden: " secs
    [[ "$secs" =~ ^[0-9]+$ ]] || { warn_fail "Ungültige Zahl."; return 1; }

    local timestamp


    timestamp=$(date +%Y%m%d_%H%M%S)


    local outfile="$LOOT_DIR/timed_${timestamp}.pcapng"
    msg "${YELLOW}[*] Zeitlich begrenzte Aufzeichnung ($secs Sekunden) auf $IFACE...${NC}"
    sudo tshark -i "$IFACE" -a duration:"$secs" -w "$outfile"

    if [ -s "$outfile" ]; then
        sudo chown "$USER:$USER" "$outfile" 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') | timed(${secs}s) | $IFACE | $outfile" >> "$HISTORY_FILE"
        msg "${GREEN}✅ Capture gespeichert: $outfile${NC}"
        notify "Zeitlich begrenzte Capture beendet ($secs s)"
    else
        warn_fail "Keine Daten aufgezeichnet."
    fi
}

action_launch_gui_live() {
    require_tools wireshark || return 1
    [ -n "$IFACE" ] || select_interface || return 1
    msg "${YELLOW}[*] Starte Wireshark-GUI live auf $IFACE...${NC}"
    sudo wireshark -i "$IFACE" -k &>/dev/null &
    msg "${GREEN}✅ Wireshark-GUI gestartet.${NC}"
}

# Bluetooth-Capture über das BlueZ-Kernel-Interface (bluetooth-monitor) oder
# ein Ubertooth-Extcap-Interface, falls angeschlossen. Unabhängig vom
# regulären WLAN-Interface (IFACE), da Bluetooth eine eigene Schnittstelle nutzt.
action_capture_bluetooth() {
    require_tools tshark || return 1
    msg "${CYAN}[*] Verfügbare Bluetooth-fähige Capture-Interfaces:${NC}"
    sudo tshark -D 2>/dev/null | grep -iE "bluetooth|ubertooth"
    local bt_iface
    read -rp "Interface-Name (z.B. bluetooth-monitor): " bt_iface
    if [ -z "$bt_iface" ]; then
        warn_fail "Kein Interface angegeben."
        return 1
    fi
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local outfile="$LOOT_DIR/bluetooth_${timestamp}.pcapng"
    msg "${YELLOW}[*] Bluetooth-Capture läuft auf $bt_iface...${NC}"
    msg "${CYAN}Beende mit Strg+C.${NC}"
    sleep 1
    sudo tshark -i "$bt_iface" -w "$outfile"

    if [ -s "$outfile" ]; then
        sudo chown "$USER:$USER" "$outfile" 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') | bluetooth | $bt_iface | $outfile" >> "$HISTORY_FILE"
        msg "${GREEN}✅ Bluetooth-Capture gespeichert: $outfile${NC}"
        notify "Bluetooth-Capture beendet"
    else
        warn_fail "Keine Daten aufgezeichnet."
    fi
}

# Ringpuffer-Aufzeichnung: rotiert automatisch nach Dateigröße, behält nur
# eine begrenzte Anzahl Dateien - geeignet für stunden-/tagelanges passives
# Monitoring, ohne eine einzelne unhandliche Riesendatei zu erzeugen.
action_capture_ringbuffer() {
    require_tools tshark || return 1
    [ -n "$IFACE" ] || select_interface || return 1
    read -rp "Maximale Dateigröße pro Segment in MB [Standard: 50]: " size_mb
    [[ "$size_mb" =~ ^[0-9]+$ ]] || size_mb=50
    read -rp "Wie viele Segmente behalten (Ringpuffer) [Standard: 10]: " keep_files
    [[ "$keep_files" =~ ^[0-9]+$ ]] || keep_files=10

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local prefix="$LOOT_DIR/ring_${timestamp}"
    msg "${YELLOW}[*] Ringpuffer-Aufzeichnung läuft auf $IFACE (${size_mb} MB je Segment, ${keep_files} Segmente)...${NC}"
    msg "${CYAN}Beende mit Strg+C.${NC}"
    sleep 1
    sudo tshark -i "$IFACE" -b filesize:"$((size_mb * 1024))" -b files:"$keep_files" -w "${prefix}.pcapng"

    local count
    count=$(find "$LOOT_DIR" -name "$(basename "$prefix")*" 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        find "$LOOT_DIR" -name "$(basename "$prefix")*" -exec sudo chown "$USER:$USER" {} + 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') | ringbuffer | $IFACE | ${prefix}.pcapng (${count} Segmente)" >> "$HISTORY_FILE"
        msg "${GREEN}✅ Ringpuffer-Aufzeichnung beendet: $count Segment(e) unter ${prefix}*${NC}"
    else
        warn_fail "Keine Daten aufgezeichnet."
    fi
}

# =====================================================
# AKTIONEN: ANALYSE GESPEICHERTER CAPTURES
# =====================================================

action_open_in_gui() {
    require_tools wireshark || return 1
    choose_capture_file || return 1
    wireshark "$SELECTED_CAPTURE" &>/dev/null &
    msg "${GREEN}✅ Geöffnet in Wireshark-GUI: $SELECTED_CAPTURE${NC}"
}

action_protocol_stats() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    echo -e "${BLUE}=== Protokoll-Hierarchie ===${NC}"
    tshark -r "$SELECTED_CAPTURE" -q -z io,phs 2>/dev/null
}

action_conversations() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    echo -e "${BLUE}=== TCP-Conversations ===${NC}"
    tshark -r "$SELECTED_CAPTURE" -q -z conv,tcp 2>/dev/null
    echo ""
    echo -e "${BLUE}=== IP-Endpoints ===${NC}"
    tshark -r "$SELECTED_CAPTURE" -q -z endpoints,ip 2>/dev/null
}

action_follow_stream() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    read -rp "Protokoll (tcp/udp): " proto
    [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { warn_fail "Nur tcp oder udp."; return 1; }
    read -rp "Stream-Index (0, 1, 2, ...): " idx
    [[ "$idx" =~ ^[0-9]+$ ]] || { warn_fail "Ungültiger Index."; return 1; }
    echo -e "${BLUE}=== Stream $idx ($proto) ===${NC}"
    tshark -r "$SELECTED_CAPTURE" -q -z follow,"$proto",ascii,"$idx" 2>/dev/null
}

# Sucht gezielt nach Klartext-Zugangsdaten in bekannten unverschlüsselten
# Protokollen (HTTP Basic Auth, FTP, Telnet-artige POST-Formulare).
# Rein lesende Analyse einer bereits vorhandenen Capture-Datei.
action_find_cleartext_creds() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    local timestamp

    timestamp=$(date +%Y%m%d_%H%M%S)

    local report="$ANALYSIS_DIR/creds_${timestamp}.txt"

    msg "${YELLOW}[*] Durchsuche $SELECTED_CAPTURE nach Klartext-Zugangsdaten...${NC}"
    {
        echo "Klartext-Zugangsdaten-Suche für: $SELECTED_CAPTURE"
        echo "Erstellt: $(date)"
        echo "========================================"

        echo ""
        echo "### HTTP Basic Authentication ###"
        tshark -r "$SELECTED_CAPTURE" -Y "http.authorization" -T fields \
            -e ip.src -e ip.dst -e http.authorization 2>/dev/null

        echo ""
        echo "### FTP USER/PASS ###"
        tshark -r "$SELECTED_CAPTURE" -Y "ftp.request.command == \"USER\" or ftp.request.command == \"PASS\"" \
            -T fields -e ip.src -e ip.dst -e ftp.request.command -e ftp.request.arg 2>/dev/null

        echo ""
        echo "### HTTP POST mit möglichen Zugangsdaten-Feldern ###"
        tshark -r "$SELECTED_CAPTURE" \
            -Y 'http.request.method == "POST" and (urlencoded-form contains "pass" or urlencoded-form contains "pwd" or urlencoded-form contains "user")' \
            -T fields -e ip.src -e ip.dst -e urlencoded-form.value 2>/dev/null

        echo ""
        echo "### SNMP Community Strings ###"
        tshark -r "$SELECTED_CAPTURE" -Y "snmp.community" -T fields \
            -e ip.src -e snmp.community 2>/dev/null

    } | tee "$report"

    msg "${GREEN}✅ Bericht gespeichert: $report${NC}"
}

action_export_http_objects() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    local timestamp

    timestamp=$(date +%Y%m%d_%H%M%S)

    local outdir="$ANALYSIS_DIR/http_objects_${timestamp}"
    mkdir -p "$outdir"
    msg "${YELLOW}[*] Extrahiere HTTP-Objekte (Dateien) aus $SELECTED_CAPTURE...${NC}"
    tshark -r "$SELECTED_CAPTURE" --export-objects "http,$outdir" 2>/dev/null

    local count
    count=$(find "$outdir" -type f 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        msg "${GREEN}✅ $count Datei(en) extrahiert nach: $outdir${NC}"
    else
        msg "${YELLOW}[!] Keine HTTP-Objekte in dieser Capture gefunden.${NC}"
        rmdir "$outdir" 2>/dev/null
    fi
}

# Listet SSIDs (aus Beacon-/Probe-Frames) und beteiligte MAC-Adressen aus
# einer 802.11-Monitor-Mode-Capture - Brücke zu den WLAN-Skript-Captures.
action_wlan_ssids() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    echo -e "${BLUE}=== Erkannte SSIDs (Beacon/Probe Response) ===${NC}"
    tshark -r "$SELECTED_CAPTURE" -Y "wlan.fc.type_subtype==0x08 or wlan.fc.type_subtype==0x05" \
        -T fields -e wlan.ssid 2>/dev/null | sort -u | grep -v '^$'
    echo ""
    echo -e "${BLUE}=== Beteiligte MAC-Adressen (Sender/Empfänger) ===${NC}"
    tshark -r "$SELECTED_CAPTURE" -Y "wlan" -T fields -e wlan.sa -e wlan.da 2>/dev/null \
        | tr '\t' '\n' | sort -u | grep -v '^$'
}

# Entschlüsselt eine WPA/WPA2-Capture mit bekanntem Passwort (setzt einen
# vollständigen 4-Way-Handshake in der Datei voraus, z.B. aus dem WLAN-Skript).
action_wlan_decrypt() {
    require_tools airdecap-ng || return 1
    choose_capture_file || return 1
    read -rp "SSID des Netzwerks: " ssid
    read -rsp "WPA/WPA2-Passphrase: " passphrase
    echo ""
    [ -n "$ssid" ] && [ -n "$passphrase" ] || { warn_fail "SSID und Passphrase erforderlich."; return 1; }

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local outfile="$LOOT_DIR/decrypted_${timestamp}.pcap"
    airdecap-ng -e "$ssid" -p "$passphrase" -o "$outfile" "$SELECTED_CAPTURE" 2>&1 | tail -10

    if [ -s "$outfile" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | wlan-decrypt | - | $outfile" >> "$HISTORY_FILE"
        msg "${GREEN}✅ Entschlüsselte Capture gespeichert: $outfile${NC}"
    else
        warn_fail "Entschlüsselung fehlgeschlagen (falsches Passwort oder kein vollständiger Handshake in der Datei)."
    fi
}

# TLS-Analyse: SNI-Hostnamen sind bei JEDER TLS-Version sichtbar (ClientHello
# ist nie verschlüsselt). Zertifikatsdetails (Aussteller, Gültigkeit) sind nur
# bei TLS 1.2 oder älter im Klartext sichtbar - TLS 1.3 verschlüsselt die
# Certificate-Message, dort bleibt dieser Teil erwartungsgemäß leer.
action_tls_info() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local report="$ANALYSIS_DIR/tls_${timestamp}.txt"

    {
        echo "TLS-Analyse für: $SELECTED_CAPTURE"
        echo "Erstellt: $(date)"
        echo "========================================"
        echo ""
        echo "### Angefragte Hostnamen (SNI aus ClientHello - immer sichtbar) ###"
        tshark -r "$SELECTED_CAPTURE" -Y "tls.handshake.type==1" \
            -T fields -e ip.dst -e tls.handshake.extensions_server_name 2>/dev/null | sort -u

        echo ""
        echo "### Zertifikatsdetails (nur bei TLS 1.2 oder älter im Klartext sichtbar) ###"
        tshark -r "$SELECTED_CAPTURE" -Y "tls.handshake.type==11" \
            -T fields -e ip.dst -e x509sat.printableString -e x509af.utcTime 2>/dev/null | sort -u

    } | tee "$report"

    msg "${GREEN}✅ Bericht gespeichert: $report${NC}"
    msg "${CYAN}Hinweis: Leere Zertifikatsdetails sind normal bei TLS-1.3-Verbindungen (Zertifikat ist verschlüsselt).${NC}"
}

# Export als CSV für Weiterverarbeitung in Tabellen/Reports.
action_csv_export() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local outfile="$ANALYSIS_DIR/export_${timestamp}.csv"
    tshark -r "$SELECTED_CAPTURE" -T fields -E header=y -E separator=, -E quote=d \
        -e frame.number -e frame.time -e ip.src -e ip.dst -e _ws.col.Protocol -e frame.len -e _ws.col.Info \
        > "$outfile" 2>/dev/null

    if [ -s "$outfile" ]; then
        msg "${GREEN}✅ CSV-Export gespeichert: $outfile${NC}"
    else
        warn_fail "CSV-Export fehlgeschlagen."
    fi
}

# Eigene, verifizierte Erkennung von ARP-Spoofing: sucht IP-Adressen, denen im
# Capture-Verlauf mehr als eine MAC-Adresse zugeordnet wurde. Zuverlässiger als
# der eingebaute tshark-Expertenfilter, der in Tests nicht konsistent anschlug.
action_arp_spoof_check() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    msg "${YELLOW}[*] Prüfe auf mehrfach zugeordnete IP-Adressen (ARP-Spoofing-Indikator)...${NC}"

    local mappings
    mappings=$(tshark -r "$SELECTED_CAPTURE" -Y "arp.opcode==2" \
        -T fields -e arp.src.proto_ipv4 -e arp.src.hw_mac 2>/dev/null | sort -u)

    if [ -z "$mappings" ]; then
        msg "${YELLOW}Keine ARP-Reply-Pakete in dieser Capture gefunden.${NC}"
        return 0
    fi

    local suspicious
    suspicious=$(echo "$mappings" | awk '{print $1}' | sort | uniq -c | awk '$1 > 1 {print $2}')

    if [ -z "$suspicious" ]; then
        msg "${GREEN}✅ Keine mehrfach zugeordneten IP-Adressen gefunden - kein Hinweis auf ARP-Spoofing.${NC}"
    else
        msg "${RED}⚠ Verdächtige IP-Adressen mit mehreren MAC-Zuordnungen:${NC}"
        while IFS= read -r ip; do
            echo -e "${YELLOW}  $ip${NC} wird beansprucht von:"
            echo "$mappings" | awk -v target="$ip" '$1==target {print "    -", $2}'
        done <<< "$suspicious"
    fi
}

# =====================================================
# AKTIONEN: DATEIVERWALTUNG
# =====================================================

action_merge_captures() {
    require_tools mergecap || return 1
    echo -e "${CYAN}Wähle mehrere Dateien zum Zusammenführen (kommagetrennte Nummern):${NC}"
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$ENGAGEMENTS_DIR" \( -name "*.pcap" -o -name "*.pcapng" -o -name "*.cap" \) 2>/dev/null | sort
    )
    if [ ${#files[@]} -lt 2 ]; then
        warn_fail "Mindestens zwei Capture-Dateien nötig."
        return 1
    fi
    local i=1
    for f in "${files[@]}"; do
        echo "  $i) $f"
        ((i++))
    done
    read -rp "Nummern (z.B. 1,3,4): " selection
    IFS=',' read -ra indices <<< "$selection"
    local chosen=()
    for idx in "${indices[@]}"; do
        idx=$((idx - 1))
        { [ "$idx" -ge 0 ] && [ "$idx" -lt ${#files[@]} ]; } && chosen+=("${files[$idx]}")
    done
    if [ ${#chosen[@]} -lt 2 ]; then
        warn_fail "Mindestens zwei gültige Dateien auswählen."
        return 1
    fi

    local timestamp


    timestamp=$(date +%Y%m%d_%H%M%S)


    local outfile="$LOOT_DIR/merged_${timestamp}.pcapng"
    mergecap -w "$outfile" "${chosen[@]}"
    if [ -s "$outfile" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | merged | - | $outfile" >> "$HISTORY_FILE"
        msg "${GREEN}✅ Zusammengeführt: $outfile${NC}"
    else
        warn_fail "Merge fehlgeschlagen."
    fi
}

action_filter_and_save() {
    require_tools tshark || return 1
    choose_capture_file || return 1
    read -rp "Anzeigefilter (z.B. 'ip.addr==192.168.1.1 and tcp.port==443'): " display_filter
    [ -n "$display_filter" ] || { warn_fail "Kein Filter angegeben."; return 1; }

    local timestamp


    timestamp=$(date +%Y%m%d_%H%M%S)


    local outfile="$LOOT_DIR/filtered_${timestamp}.pcapng"
    tshark -r "$SELECTED_CAPTURE" -Y "$display_filter" -w "$outfile" 2>/dev/null

    if [ -s "$outfile" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | filtered | - | $outfile" >> "$HISTORY_FILE"
        msg "${GREEN}✅ Gefilterte Capture gespeichert: $outfile${NC}"
    else
        warn_fail "Kein Ergebnis oder ungültiger Filter."
    fi
}

action_capture_info() {
    require_tools capinfos || return 1
    choose_capture_file || return 1
    echo -e "${BLUE}=== Capture-Informationen ===${NC}"
    capinfos "$SELECTED_CAPTURE" 2>/dev/null
}

action_show_history() {
    echo -e "${BLUE}=== Capture-Historie ===${NC}"
    if [ -f "$HISTORY_FILE" ]; then
        tail -n 20 "$HISTORY_FILE" | column -t -s '|'
    else
        echo -e "${RED}Noch keine Captures in der Historie.${NC}"
    fi
}

# =====================================================
# EINSTELLUNGEN
# =====================================================

action_show_log() {
    tail -n 30 "$LOGFILE" 2>/dev/null || echo "Noch keine Log-Einträge."
}

# =====================================================
# HEADER
# =====================================================
show_header() {
    echo -e "${CYAN}Interface   : ${YELLOW}${IFACE:-nicht gesetzt}${NC}"
    echo -e "${CYAN}Projekt     : ${YELLOW}${LOOT_DIR:-nicht gesetzt}${NC}"
    echo ""
}

# =====================================================
# GENERISCHES MENÜ-SYSTEM
# =====================================================
run_menu() {
    local title="$1"; shift
    local -a entries=("$@")

    while true; do
        clear
        show_header
        echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
        echo -e "                   ${GREEN}${title}${NC}"
        echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"

        local i=1
        for entry in "${entries[@]}"; do
            echo " $i) ${entry%%|*}"
            ((i++))
        done
        echo " 0) Zurück"
        echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"

        read -rp "Wähle eine Option: " choice
        [ "$choice" = "0" ] && return 0

        local idx=$((choice - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#entries[@]} ]; then
            "${entries[$idx]#*|}"
        else
            msg "${RED}Ungültige Option!${NC}"
        fi
        echo ""
        pause
    done
}

menu_live_capture() {
    run_menu "Live Capture" \
        "Alles mitschneiden (kein Filter)|action_capture_all" \
        "Nur Web-Traffic (Port 80/443)|action_capture_web" \
        "Nur DNS (Port 53)|action_capture_dns" \
        "Nur ARP-Traffic|action_capture_arp" \
        "Klassische Klartext-Protokolle (FTP/Telnet/HTTP/POP3/IMAP)|action_capture_unencrypted" \
        "Eigener Capture-Filter (BPF)|action_capture_custom_filter" \
        "Zeitlich begrenzte Aufzeichnung|action_capture_timed" \
        "Langzeit-Aufzeichnung mit Ringpuffer|action_capture_ringbuffer" \
        "Bluetooth-Capture|action_capture_bluetooth" \
        "Wireshark-GUI live starten|action_launch_gui_live"
}

menu_analysis() {
    run_menu "Analyse gespeicherter Captures" \
        "In Wireshark-GUI öffnen|action_open_in_gui" \
        "Protokoll-Statistik anzeigen|action_protocol_stats" \
        "Conversations / Endpoints anzeigen|action_conversations" \
        "Stream folgen (TCP/UDP)|action_follow_stream" \
        "Klartext-Zugangsdaten suchen|action_find_cleartext_creds" \
        "Dateien aus HTTP-Traffic extrahieren|action_export_http_objects" \
        "WLAN: SSIDs und MAC-Adressen anzeigen|action_wlan_ssids" \
        "WLAN: Capture mit Passwort entschlüsseln|action_wlan_decrypt" \
        "TLS-Verbindungen und Zertifikate analysieren|action_tls_info" \
        "ARP-Spoofing-Prüfung|action_arp_spoof_check" \
        "Als CSV exportieren|action_csv_export"
}

menu_file_management() {
    run_menu "Dateiverwaltung" \
        "Mehrere Captures zusammenführen|action_merge_captures" \
        "Capture filtern & speichern|action_filter_and_save" \
        "Capture-Informationen anzeigen|action_capture_info" \
        "Capture-Historie anzeigen|action_show_history"
}

menu_settings() {
    run_menu "Einstellungen" \
        "Interface neu wählen|action_reselect_interface" \
        "Projekt wechseln|action_switch_project" \
        "Log-Datei anzeigen|action_show_log"
}

# =====================================================
# CLEANUP
# =====================================================
cleanup() {
    echo ""
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    msg "${GREEN}✅ Auf Wiedersehen!${NC}"
}
trap cleanup EXIT INT TERM

# =====================================================
# START
# =====================================================
clear
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  WIRESHARK POWER TOOL                        ║"
echo "║   Live Capture • Analyse • Credential-Suche • Export           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
msg "${YELLOW}Hinweis: Nur in eigener Lab-Umgebung / mit ausdrücklicher Erlaubnis verwenden.${NC}"
echo ""

require_root_actions
rotate_log_if_needed

msg "${CYAN}[*] Fordere sudo-Rechte einmalig an...${NC}"
sudo -v || die "sudo-Authentifizierung fehlgeschlagen."
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &>/dev/null &
SUDO_KEEPALIVE_PID=$!

select_interface
select_project

# ---------- Hauptmenü ----------
while true; do
    clear
    show_header
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "                   ${GREEN}Hauptmenü${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo " 1) Live Capture"
    echo " 2) Analyse gespeicherter Captures"
    echo " 3) Dateiverwaltung (Merge, Filter, Info, Historie)"
    echo " 4) Einstellungen (Interface, Projekt, Log)"
    echo " 5) Beenden"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"

    read -rp "Wähle eine Option (1-5): " choice

    case $choice in
        1) menu_live_capture ;;
        2) menu_analysis ;;
        3) menu_file_management ;;
        4) menu_settings ;;
        5) msg "${GREEN}Auf Wiedersehen!${NC}"; exit 0 ;;
        *) msg "${RED}Ungültige Option!${NC}"; sleep 1 ;;
    esac
done
