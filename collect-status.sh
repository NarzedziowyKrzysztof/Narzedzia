#!/bin/bash

# ═══════════════════════════════════════════════════════════
# RHEL UPDATE ORCHESTRATOR
# ═══════════════════════════════════════════════════════════
# Skrypt:          collect-status.sh
# Wersja projektu: 11.14
# Ostatnia zmiana: 2026-03-21
# Autor:           Krzysztof Boroń
# Opis:            Zbieranie statusów i generowanie raportów (JSON/HTML/CSV)
# ═══════════════════════════════════════════════════════════
# Zbiera pliki status.json ze zdalnych serwerów i tworzy
# zagregowane raporty w formatach: JSON, HTML, CSV
#
# Użycie:
#   ./collect-status.sh [OPCJE] [SERWER1 SERWER2 ...]
#
# Przykłady:
#   ./collect-status.sh                          # wszystkie z servers.txt
#   ./collect-status.sh server1 server2          # tylko wybrane
#   ./collect-status.sh --format html            # raport HTML
#   ./collect-status.sh --format all             # wszystkie formaty
#   ./collect-status.sh --failures-only          # tylko błędy
# ═══════════════════════════════════════════════════════════

readonly PROJECT_VERSION="11.14"
readonly SCRIPT_NAME="collect-status.sh"
readonly LAST_CHANGE="2026-04-02"
readonly AUTHOR="Krzysztof Boroń"

set -o pipefail

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ════════════════════════════════════════════════════════════
# INSTALACJA NARZĘDZI (jeśli brak)
# ════════════════════════════════════════════════════════════

# Sprawdź czy jq jest zainstalowany (potrzebny do CSV/HTML z JSON)
if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}[INFO] Instaluję narzędzie jq (wymagane do raportów)...${NC}"
    if sudo dnf install -y jq &>/dev/null || sudo apt-get install -y jq &>/dev/null; then
        echo -e "${GREEN}✓ jq zainstalowany${NC}"
    else
        echo -e "${YELLOW}! Nie udało się zainstalować jq - użyję fallback (sed/grep)${NC}"
    fi
    echo ""
fi

# ════════════════════════════════════════════════════════════
# ZMIENNE GLOBALNE
# ════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/orchestrator.conf"
CONFIG_FILE="${DEFAULT_CONFIG}"

FORMAT="json"  # json, html, csv, all
FAILURES_ONLY=false
DEBUG_MODE=false  # --debug flag
REPORT_FROM_FILE=""  # --report-from-file JSON path
SERVERS=()

# Statystyki
TOTAL_SERVERS=0
SUCCESS_COUNT=0
FAIL_COUNT=0
UNREACHABLE_COUNT=0

# Dane serwerów (tablica asocjacyjna symulowana)
declare -a SERVER_DATA

# ════════════════════════════════════════════════════════════
# FUNKCJE POMOCNICZE
# ════════════════════════════════════════════════════════════

# Debug logging (tylko gdy --debug)
debug_log() {
    if [ "$DEBUG_MODE" == "true" ]; then
        echo "[DEBUG] $*" >&2
    fi
}

show_help() {
    cat << 'EOF'
════════════════════════════════════════════════════════════
  COLLECT-STATUS - Zbieranie statusów serwerów
════════════════════════════════════════════════════════════

UŻYCIE:
  ./collect-status.sh [OPCJE] [SERWER1 SERWER2 ...]
  ./collect-status.sh [OPCJE] --servers-file FILE

OPCJE:
  --config FILE           Użyj niestandardowej konfiguracji
                          (domyślnie: ./orchestrator.conf)
  
  --format FORMAT         Format raportu: json, html, csv, all
                          (domyślnie: json)
  
  --failures-only         Pokaż tylko serwery z błędami
  
  --servers-file FILE     Czytaj serwery z pliku
  
  --report-from-file JSON Wygeneruj HTML+CSV z istniejącego JSON
                          (tylko generowanie raportów, bez zbierania danych)
  
  --debug                 Tryb debugowania (szczegółowe logi)
  
  --help, -h              Pokaż tę pomoc

ARGUMENTY:
  SERWER1 SERWER2 ...     Lista serwerów do sprawdzenia

PRZYKŁADY:
  # Wybrane serwery, raport JSON (domyślny)
  ./collect-status.sh server1 server2

  # Z pliku, raport HTML
  ./collect-status.sh --format html --servers-file servers-prod.txt

  # Wszystkie formaty
  ./collect-status.sh --format all --servers-file prod.txt

  # Tylko błędy, CSV
  ./collect-status.sh --format csv --failures-only --servers-file prod.txt

WYJŚCIE:
  status/YYYY-MM-DD/status-report.{json,html,csv}

NOTATKI:
  - Raporty CSV i HTML są generowane z pliku JSON
  - jq jest wymagane (instalowane automatycznie jeśli brak)
  - Wykrywa manualne aktualizacje (poza skryptem)
  - Używa 'dnf history' do wykrywania ostatniej aktualizacji

════════════════════════════════════════════════════════════
EOF
}

# Pobiera status z jednego serwera (rozszerzony)
collect_from_server() {
    local server="$1"
    local index="$2"
    
    echo -ne "${CYAN}[${index}/${TOTAL_SERVERS}] ${server} ... ${NC}"
    
    # Pobierz konfigurację serwera
    local config_file="${CONTROL_BASE_DIR}/config/${server}.conf"
    local ssh_user="${DEFAULT_SSH_USER}"
    local ssh_port="${DEFAULT_SSH_PORT}"
    
    # Sprawdź czy istnieje plik konfiguracyjny (WYMAGANE!)
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}⚠ NO CONFIG${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        
        SERVER_DATA+=("$(cat <<EOF
{
  "hostname": "${server}",
  "status": "NO_CONFIG",
  "our_script": {"last_run": null, "result": "NO_CONFIG"},
  "system_state": {"last_dnf_update": null, "manual_update": false, "last_reboot": null, "uptime_days": 0},
  "alerts": ["Config file not found: ${config_file}"]
}
EOF
)")
        return 1
    fi
    
    # Wczytaj konfigurację
    source "$config_file" 2>/dev/null
    ssh_user="${SSH_USER:-$DEFAULT_SSH_USER}"
    ssh_port="${SSH_PORT:-$DEFAULT_SSH_PORT}"
    
    # Pobierz rozszerzone dane z serwera (status.json + system state)
    local server_data=$(ssh -o ConnectTimeout=5 \
                            -o StrictHostKeyChecking=no \
                            -o UserKnownHostsFile=/dev/null \
                            -o LogLevel=ERROR \
                            -p "${ssh_port}" \
                            "${ssh_user}@${server}" \
                            'bash -s' <<'REMOTE_SCRIPT'
# Status.json (nasz skrypt)
if [ -f /opt/remote_updates_DUIT-AS-DB/status.json ]; then
    cat /opt/remote_updates_DUIT-AS-DB/status.json
else
    echo '{"result":"NEVER_RUN"}'
fi

echo "---SEPARATOR---"

# Ostatni DNF update (z dnf history)
# Szukamy ostatniego całościowego update (nie update konkretnej paczki)
last_update=$(dnf history 2>/dev/null | grep -E "^\s*[0-9]+" | while IFS= read -r line; do
    # Wyciągnij komendę (kolumna 2 gdy separator to |)
    command=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
    
    # Sprawdź czy zaczyna się od "update" (może mieć flagi: update -y, update --enablerepo=*)
    # ALE wykluczamy update konkretnej paczki (np: update kernel, update httpd)
    if echo "$command" | grep -qE "^update(\s|$)" && ! echo "$command" | grep -qE "^update\s+[a-zA-Z0-9_-]+$"; then
        # To całościowy update - wyciągnij datę i czas (kolumna 3)
        echo "$line" | awk -F'|' '{print $3}' | xargs
        break
    fi
done | head -1)

if [ -n "$last_update" ]; then
    echo "$last_update"
    echo "---PKG_COUNT---"
    # Policz pakiety w tej transakcji
    # Wyciągnij ID transakcji i policz Altered packages
    trans_id=$(dnf history 2>/dev/null | grep -E "^\s*[0-9]+" | head -1 | awk '{print $1}')
    dnf history info "$trans_id" 2>/dev/null | grep -E "^(Install|Update|Upgrade|Erase)" | wc -l
else
    echo "NO_DNF_HISTORY"
    echo "---PKG_COUNT---"
    echo "0"
fi

echo "---SEPARATOR---"

# Ostatni restart (uptime - sekundy od bootu)
cat /proc/uptime | awk '{print int($1)}'
REMOTE_SCRIPT
)
    
    local ssh_exit=$?
    
    debug_log "=== RAW SERVER DATA ==="
    debug_log "SSH exit code: $ssh_exit"
    debug_log "Server data length: ${#server_data}"
    debug_log "Server data (ALL):"
    debug_log "$server_data"
    debug_log "=== END RAW DATA ==="
    
    if [ $ssh_exit -ne 0 ]; then
        echo -e "${RED}⚠ UNREACHABLE${NC}"
        UNREACHABLE_COUNT=$((UNREACHABLE_COUNT + 1))
        
        SERVER_DATA+=("$(cat <<EOF
{
  "hostname": "${server}",
  "status": "UNREACHABLE",
  "our_script": {"last_run": null, "result": "UNREACHABLE"},
  "system_state": {"last_dnf_update": null, "manual_update": false},
  "alerts": ["Cannot connect via SSH"]
}
EOF
)")
        return 1
    fi
    
    # Parsuj wyniki
    local status_json=$(echo "$server_data" | awk 'BEGIN{RS="---SEPARATOR---"} NR==1')
    local dnf_block=$(echo "$server_data" | awk 'BEGIN{RS="---SEPARATOR---"} NR==2')
    local uptime_info=$(echo "$server_data" | awk 'BEGIN{RS="---SEPARATOR---"} NR==3' | xargs)
    
    debug_log "=== PARSOWANIE BLOKÓW ==="
    debug_log "Status JSON length: ${#status_json}"
    debug_log "DNF block length: ${#dnf_block}"
    debug_log "DNF block (first 200 chars): ${dnf_block:0:200}"
    debug_log "Uptime info: $uptime_info"
    debug_log "Status JSON (first 500 chars): ${status_json:0:500}"
    
    # Parsuj status.json (kompatybilny sed zamiast grep -P)
    local script_result=$(echo "$status_json" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    local script_timestamp=$(echo "$status_json" | sed -n 's/.*"timestamp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    local script_packages=$(echo "$status_json" | sed -n 's/.*"total"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
    local script_reboot=$(echo "$status_json" | sed -n 's/.*"scheduled"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p')
    
    # Wyciągnij prawdziwy hostname z status.json (jeśli istnieje)
    local real_hostname=$(echo "$status_json" | sed -n 's/.*"hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -z "$real_hostname" ] && real_hostname="$server"  # fallback do argumentu
    
    debug_log "=== PARSOWANIE STATUS.JSON ==="
    debug_log "script_result: [$script_result]"
    debug_log "script_timestamp: [$script_timestamp]"
    debug_log "script_packages: [$script_packages]"
    debug_log "real_hostname: [$real_hostname]"
    
    # Parsuj DNF history
    local dnf_timestamp=""
    local dnf_pkg_count=0
    
    # Sprawdź pierwszą NIE-PUSTĄ linię bloku (grep -v "^$" usuwa puste linie)
    local dnf_first_line=$(echo "$dnf_block" | grep -v "^$" | head -1 | xargs)
    
    debug_log "=== PARSOWANIE DNF ==="
    debug_log "dnf_first_line: [$dnf_first_line]"
    debug_log "dnf_first_line length: ${#dnf_first_line}"
    debug_log "Check: dnf_first_line != NO_DNF_HISTORY: $( [ "$dnf_first_line" != "NO_DNF_HISTORY" ] && echo TRUE || echo FALSE )"
    debug_log "Check: -n dnf_first_line: $( [ -n "$dnf_first_line" ] && echo TRUE || echo FALSE )"
    
    if [ "$dnf_first_line" != "NO_DNF_HISTORY" ] && [ -n "$dnf_first_line" ]; then
        # Pierwsza linia zawiera datę z dnf history
        dnf_timestamp="$dnf_first_line"
        debug_log "dnf_timestamp SET TO: [$dnf_timestamp]"
        
        # Po ---PKG_COUNT--- jest liczba pakietów
        dnf_pkg_count=$(echo "$dnf_block" | awk '/---PKG_COUNT---/{getline; print; exit}')
        [ -z "$dnf_pkg_count" ] && dnf_pkg_count=0
        debug_log "dnf_pkg_count: $dnf_pkg_count"
    else
        debug_log "dnf_timestamp: NULL (condition failed)"
    fi
    
    # Parsuj uptime
    local last_reboot=""
    local uptime_days=0
    
    debug_log "=== PARSOWANIE UPTIME ==="
    debug_log "uptime_info: [$uptime_info]"
    debug_log "uptime_info length: ${#uptime_info}"
    
    if [[ "$uptime_info" =~ ^[0-9]{4}- ]]; then
        # Format daty (YYYY-MM-DD)
        last_reboot="$uptime_info"
        uptime_days=$(( ($(date +%s) - $(date -d "$uptime_info" +%s)) / 86400 ))
        debug_log "Format: DATE, last_reboot: $last_reboot, uptime_days: $uptime_days"
    elif [[ "$uptime_info" =~ ^[0-9]+$ ]]; then
        # Format sekund (z /proc/uptime)
        uptime_days=$(( uptime_info / 86400 ))
        last_reboot=$(date -d "@$(($(date +%s) - uptime_info))" '+%Y-%m-%d %H:%M:%S')
        debug_log "Format: SECONDS, last_reboot: $last_reboot, uptime_days: $uptime_days"
    else
        debug_log "Format: UNKNOWN (nie pasuje do żadnego regex)"
    fi
    
    # Określ czy był manual update
    local manual_update=false
    local days_since_script=0
    local alerts=()
    
    if [ "$script_result" == "NEVER_RUN" ]; then
        alerts+=("Server not managed by script")
        if [ -n "$dnf_timestamp" ]; then
            manual_update=true
        fi
    elif [ -n "$dnf_timestamp" ] && [ -n "$script_timestamp" ]; then
        # Porównaj daty
        local dnf_epoch=$(date -d "$dnf_timestamp" +%s 2>/dev/null || echo 0)
        local script_epoch=$(date -d "$script_timestamp" +%s 2>/dev/null || echo 0)
        
        if [ $dnf_epoch -gt $script_epoch ]; then
            manual_update=true
            days_since_script=$(( (dnf_epoch - script_epoch) / 86400 ))
            alerts+=("Manual update ${days_since_script} days after script")
        fi
    fi
    
    # Status dla wyświetlenia
    local display_status="SUCCESS"
    
    debug_log "=== CASE STATEMENT ==="
    debug_log "script_result for case: [$script_result]"
    
    case "$script_result" in
        FAIL|DRY_RUN_FAIL)
            display_status="FAIL"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            alerts+=("Script failed")
            debug_log "Case matched: FAIL"
            ;;
        SUCCESS|DRY_RUN_SUCCESS)
            display_status="SUCCESS"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            debug_log "Case matched: SUCCESS"
            ;;
        NEVER_RUN)
            display_status="NEVER_RUN"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            debug_log "Case matched: NEVER_RUN"
            ;;
        *)
            display_status="UNKNOWN"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            debug_log "Case matched: UNKNOWN (default)"
            ;;
    esac
    
    debug_log "Final display_status: [$display_status]"
    
    # Wyświetl status
    debug_log "About to display status (manual_update=$manual_update)"
    if [ "$manual_update" == "true" ]; then
        echo -e "${YELLOW}⚠ ${display_status} + MANUAL${NC}"
        debug_log "Displayed: MANUAL"
    elif [ "$display_status" == "SUCCESS" ]; then
        echo -e "${GREEN}✓ ${display_status}${NC}"
        debug_log "Displayed: SUCCESS"
    elif [ "$display_status" == "NEVER_RUN" ]; then
        echo -e "${YELLOW}⚠ ${display_status}${NC}"
        debug_log "Displayed: NEVER_RUN"
    else
        echo -e "${RED}✗ ${display_status}${NC}"
        debug_log "Displayed: else branch (display_status=$display_status)"
    fi
    
    # Zapisz dane (rozszerzony format)
    local alerts_json=$(printf '%s\n' "${alerts[@]}" | sed 's/^/"/' | sed 's/$/"/' | paste -sd,)
    [ -z "$alerts_json" ] && alerts_json='null'
    
    SERVER_DATA+=("$(cat <<EOF
{
  "hostname": "${real_hostname}",
  "status": "${display_status}",
  "our_script": {
    "last_run": $([ -n "$script_timestamp" ] && echo "\"$script_timestamp\"" || echo "null"),
    "result": "${script_result:-unknown}",
    "packages": ${script_packages:-0},
    "reboot_scheduled": ${script_reboot:-false}
  },
  "system_state": {
    "last_dnf_update": $([ -n "$dnf_timestamp" ] && echo "\"$dnf_timestamp\"" || echo "null"),
    "last_dnf_packages": ${dnf_pkg_count:-0},
    "manual_update": ${manual_update},
    "days_since_script": ${days_since_script},
    "last_reboot": $([ -n "$last_reboot" ] && echo "\"$last_reboot\"" || echo "null"),
    "uptime_days": ${uptime_days}
  },
  "alerts": [${alerts_json}]
}
EOF
)")
    
    return 0
}

# Generuje raport JSON
generate_json_report() {
    local output_file="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    cat > "$output_file" << EOF
{
  "generated_at": "${timestamp}",
  "servers_total": ${TOTAL_SERVERS},
  "servers_success": ${SUCCESS_COUNT},
  "servers_failed": ${FAIL_COUNT},
  "servers_unreachable": ${UNREACHABLE_COUNT},
  "servers": [
EOF
    
    local first=true
    for data in "${SERVER_DATA[@]}"; do
        # Filtr failures-only
        if [ "$FAILURES_ONLY" == "true" ]; then
            if echo "$data" | grep -q '"result":"SUCCESS"'; then
                continue
            fi
        fi
        
        if [ "$first" == "true" ]; then
            first=false
        else
            echo "," >> "$output_file"
        fi
        
        echo "    $data" >> "$output_file"
    done
    
    cat >> "$output_file" << EOF

  ]
}
EOF
}

# Generuje raport HTML
# Generuje raport HTML (z pliku JSON)
generate_html_report() {
    local json_file="$1"
    local output_file="$2"
    
    # Funkcja pomocnicza: oblicz klasę CSS dla last_dnf_update
    get_dnf_class() {
        local dnf_date="$1"
        
        # Brak danych -> fioletowy
        if [ -z "$dnf_date" ] || [ "$dnf_date" == "null" ] || [ "$dnf_date" == "N/A" ]; then
            echo "dnf-nodata"
            return
        fi
        
        # Spróbuj sparsować datę (YYYY-MM-DD HH:MM:SS lub YYYY-MM-DD HH:MM)
        local dnf_epoch=$(date -d "$dnf_date" +%s 2>/dev/null)
        
        # Jeśli parsing nie działa -> fioletowy
        if [ $? -ne 0 ] || [ -z "$dnf_epoch" ]; then
            echo "dnf-nodata"
            return
        fi
        
        # Oblicz różnicę w dniach
        local now_epoch=$(date +%s)
        local days_ago=$(( (now_epoch - dnf_epoch) / 86400 ))
        
        # Przypisz klasę CSS
        if [ $days_ago -lt 30 ]; then
            echo "dnf-fresh"
        elif [ $days_ago -lt 60 ]; then
            echo "dnf-warning"
        else
            echo "dnf-critical"
        fi
    }
    
    # Pobierz statystyki i timestamp z JSON
    local timestamp=$(jq -r '.generated_at // "N/A"' "$json_file")
    local total=$(jq -r '.servers_total // 0' "$json_file")
    local success=$(jq -r '.servers_success // 0' "$json_file")
    local fail=$(jq -r '.servers_failed // 0' "$json_file")
    local unreachable=$(jq -r '.servers_unreachable // 0' "$json_file")
    
    # HTML header z CSS
    cat > "$output_file" << 'EOF'
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RHEL Update Status Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f5f5f5; padding: 20px; }
        .container { max-width: 1600px; margin: 0 auto; background: white; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); padding: 30px; }
        h1 { color: #333; margin-bottom: 10px; font-size: 28px; }
        .meta { color: #666; margin-bottom: 20px; font-size: 14px; }
        .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 30px; }
        .summary-card { padding: 20px; border-radius: 6px; text-align: center; }
        .summary-card.success { background: #d4edda; border-left: 4px solid #28a745; }
        .summary-card.failure { background: #f8d7da; border-left: 4px solid #dc3545; }
        .summary-card.unreachable { background: #fff3cd; border-left: 4px solid #ffc107; }
        .summary-card.total { background: #e7f3ff; border-left: 4px solid #007bff; }
        .summary-card h3 { font-size: 32px; margin-bottom: 5px; }
        .summary-card p { color: #666; font-size: 14px; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f8f9fa; font-weight: 600; color: #495057; position: sticky; top: 0; }
        tr:hover { background: #f8f9fa; }
        tr.success { border-left: 3px solid #28a745; }
        tr.failure { border-left: 3px solid #dc3545; }
        tr.unreachable { border-left: 3px solid #ffc107; }
        .badge { display: inline-block; padding: 4px 8px; border-radius: 3px; font-size: 12px; font-weight: 600; }
        .badge.success { background: #d4edda; color: #155724; }
        .badge.failure { background: #f8d7da; color: #721c24; }
        .badge.unreachable { background: #fff3cd; color: #856404; }
        .alert { font-size: 12px; color: #856404; margin-top: 4px; }
        
        /* Kolorowanie last_dnf_update według wieku */
        .dnf-fresh { background: #d4edda; color: #155724; font-weight: 600; padding: 4px 8px; border-radius: 3px; }      /* < 30 dni - zielony */
        .dnf-warning { background: #fff3cd; color: #856404; font-weight: 600; padding: 4px 8px; border-radius: 3px; }   /* 30-59 dni - pomarańczowy */
        .dnf-critical { background: #f8d7da; color: #721c24; font-weight: 600; padding: 4px 8px; border-radius: 3px; }  /* ≥60 dni - czerwony */
        .dnf-nodata { background: #e8d5f2; color: #6f42c1; font-weight: 600; padding: 4px 8px; border-radius: 3px; }    /* Brak danych - fioletowy */
        
        /* Legenda */
        .legend { margin-top: 30px; padding: 20px; background: #f8f9fa; border-radius: 6px; border-left: 4px solid #007bff; }
        .legend h3 { margin-bottom: 15px; color: #495057; font-size: 16px; }
        .legend-item { display: inline-block; margin-right: 30px; margin-bottom: 10px; }
        .legend-item span { display: inline-block; padding: 6px 12px; border-radius: 4px; font-size: 13px; margin-right: 8px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🖥️ RHEL Update Status Report</h1>
EOF
    
    # Stats
    cat >> "$output_file" << EOF
        <div class="meta">Generated: ${timestamp}</div>
        <div class="summary">
            <div class="summary-card total"><h3>${total}</h3><p>Total Servers</p></div>
            <div class="summary-card success"><h3>${success}</h3><p>Success</p></div>
            <div class="summary-card failure"><h3>${fail}</h3><p>Failed</p></div>
            <div class="summary-card unreachable"><h3>${unreachable}</h3><p>Unreachable</p></div>
        </div>
        
        <div class="legend">
            <h3>📊 Legenda - Ostatnia aktualizacja DNF:</h3>
            <div class="legend-item">
                <span class="dnf-fresh">🟢 &lt; 30 dni temu</span>
                <small>System aktualny</small>
            </div>
            <div class="legend-item">
                <span class="dnf-warning">🟠 30-59 dni temu</span>
                <small>W granicach, ale bliski termin</small>
            </div>
            <div class="legend-item">
                <span class="dnf-critical">🔴 ≥ 60 dni temu</span>
                <small>Znacznie powyżej terminu</small>
            </div>
            <div class="legend-item">
                <span class="dnf-nodata">⚫ Brak danych</span>
                <small>System wymaga weryfikacji</small>
            </div>
        </div>
        
        <table>
            <thead>
                <tr>
                    <th>Server</th><th>Status</th><th>Script Run</th><th>DNF Update</th>
                    <th>Manual</th><th>Last Reboot</th><th>Uptime</th><th>Alerts</th>
                </tr>
            </thead>
            <tbody>
EOF
    
    # Generuj wiersze tabeli - bez jq parsowania dat (zawodne)
    if command -v jq &>/dev/null; then
        # Wyciągnij listę serwerów z JSON
        local server_count=$(jq '.servers | length' "$json_file")
        
        for ((i=0; i<server_count; i++)); do
            # Filtruj według FAILURES_ONLY
            local status=$(jq -r ".servers[$i].status // \"UNKNOWN\"" "$json_file")
            if [ "$FAILURES_ONLY" == "true" ] && [ "$status" == "SUCCESS" ]; then
                continue
            fi
            
            # Wyciągnij dane serwera
            local hostname=$(jq -r ".servers[$i].hostname // \"unknown\"" "$json_file")
            local script_run=$(jq -r ".servers[$i].our_script.last_run // \"NEVER\"" "$json_file")
            local dnf_update=$(jq -r ".servers[$i].system_state.last_dnf_update // \"N/A\"" "$json_file")
            local manual=$(jq -r "if .servers[$i].system_state.manual_update then \"YES\" else \"NO\" end" "$json_file")
            local last_reboot=$(jq -r ".servers[$i].system_state.last_reboot // \"N/A\"" "$json_file")
            local uptime=$(jq -r "(.servers[$i].system_state.uptime_days // 0 | tostring) + \"d\"" "$json_file")
            local alerts=$(jq -r "if .servers[$i].alerts then (.servers[$i].alerts | join(\"; \")) else \"—\" end" "$json_file")
            
            # Oblicz klasę CSS dla DNF (używa bash funkcji)
            local dnf_class=$(get_dnf_class "$dnf_update")
            
            # Klasa wiersza
            local row_class="success"
            if [ "$status" == "FAIL" ]; then
                row_class="failure"
            elif [ "$status" == "UNREACHABLE" ] || [ "$status" == "NEVER_RUN" ] || [ "$status" == "NO_CONFIG" ]; then
                row_class="unreachable"
            fi
            
            # Badge class
            local badge_class="success"
            if [ "$status" == "FAIL" ]; then
                badge_class="failure"
            elif [ "$status" == "UNREACHABLE" ] || [ "$status" == "NEVER_RUN" ] || [ "$status" == "NO_CONFIG" ]; then
                badge_class="unreachable"
            fi
            
            # Status text
            local status_text="✅ SUCCESS"
            case "$status" in
                FAIL) status_text="❌ FAIL" ;;
                UNREACHABLE) status_text="⚠️ UNREACHABLE" ;;
                NEVER_RUN) status_text="⚠️ NEVER RUN" ;;
                NO_CONFIG) status_text="⚠️ NO CONFIG" ;;
            esac
            
            # Generuj wiersz HTML
            cat >> "$output_file" << EOF
                <tr class="$row_class">
                    <td><strong>$hostname</strong></td>
                    <td><span class="badge $badge_class">$status_text</span></td>
                    <td>$script_run</td>
                    <td><span class="$dnf_class">$dnf_update</span></td>
                    <td>$manual</td>
                    <td>$last_reboot</td>
                    <td>$uptime</td>
                    <td><div class="alert">$alerts</div></td>
                </tr>
EOF
        done
    fi
    
    # HTML footer
    cat >> "$output_file" << 'EOF'
            </tbody>
        </table>
    </div>
</body>
</html>
EOF
}

# Generuje raport CSV (z pliku JSON)
generate_csv_report() {
    local json_file="$1"
    local output_file="$2"
    
    # Nagłówek CSV
    echo "Hostname,Script_Last_Run,Script_Result,Script_Packages,DNF_Last_Update,Manual_Update,Days_Since_Script,Last_Reboot,Uptime_Days,Alerts" > "$output_file"
    
    # Użyj jq jeśli dostępne, fallback do sed
    if command -v jq &>/dev/null; then
        # jq - parsowanie JSON do CSV
        jq --arg failures "$FAILURES_ONLY" -r '
.servers[] | 
select(
    if $failures == "true" then 
        .status != "SUCCESS" 
    else 
        true 
    end
) | 
[
    (.hostname // "unknown"),
    (.our_script.last_run // "NEVER"),
    (.our_script.result // "unknown"),
    (.our_script.packages // 0),
    (.system_state.last_dnf_update // "N/A"),
    (if .system_state.manual_update then "YES" else "NO" end),
    (.system_state.days_since_script // 0),
    (.system_state.last_reboot // "N/A"),
    (.system_state.uptime_days // 0),
    (if .alerts then (.alerts | join("; ")) else "" end)
] | @csv' "$json_file" >> "$output_file"
    else
        # Fallback: sed/grep (czyta z pliku JSON)
        local servers=$(grep -o '"hostname":"[^"]*"' "$json_file" | wc -l)
        local i=0
        
        while read -r line; do
            # Parsuj każdą linię JSON serwera
            if echo "$line" | grep -q '"hostname"'; then
                i=$((i + 1))
                
                # Filtr failures-only
                if [ "$FAILURES_ONLY" == "true" ]; then
                    local status=$(echo "$line" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
                    if [ "$status" == "SUCCESS" ]; then
                        continue
                    fi
                fi
                
                # Parsuj dane (podobnie jak wcześniej)
                local hostname=$(echo "$line" | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4)
                local script_run=$(echo "$line" | sed -n 's/.*"last_run":"\([^"]*\)".*/\1/p')
                [ -z "$script_run" ] && script_run="NEVER"
                local script_result=$(echo "$line" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p' | head -1)
                local script_packages=$(echo "$line" | sed -n 's/.*"packages":\([0-9]*\).*/\1/p' | head -1)
                local dnf_update=$(echo "$line" | sed -n 's/.*"last_dnf_update":"\([^"]*\)".*/\1/p')
                [ -z "$dnf_update" ] && dnf_update="N/A"
                local manual=$(echo "$line" | sed -n 's/.*"manual_update":\([a-z]*\).*/\1/p')
                [ "$manual" == "true" ] && manual="YES" || manual="NO"
                local days_since=$(echo "$line" | sed -n 's/.*"days_since_script":\([0-9]*\).*/\1/p')
                local last_reboot=$(echo "$line" | sed -n 's/.*"last_reboot":"\([^"]*\)".*/\1/p')
                [ -z "$last_reboot" ] && last_reboot="N/A"
                local uptime_days=$(echo "$line" | sed -n 's/.*"uptime_days":\([0-9]*\).*/\1/p')
                local alerts=$(echo "$line" | sed -n 's/.*"alerts":\[\([^]]*\)\].*/\1/p' | sed 's/"//g' | sed 's/,/; /g')
                
                echo "${hostname:-unknown},${script_run},${script_result:-unknown},${script_packages:-0},${dnf_update},${manual},${days_since:-0},${last_reboot},${uptime_days:-0},${alerts}" >> "$output_file"
            fi
        done < <(jq -c '.servers[]' "$json_file" 2>/dev/null || grep -A 50 '"hostname"' "$json_file")
    fi
}

# ════════════════════════════════════════════════════════════
# PARSOWANIE ARGUMENTÓW
# ════════════════════════════════════════════════════════════

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --servers-file)
            CUSTOM_SERVERS_FILE="$2"
            if [ ! -f "$CUSTOM_SERVERS_FILE" ]; then
                echo -e "${RED}ERROR: Servers file not found: $CUSTOM_SERVERS_FILE${NC}"
                exit 2
            fi
            shift 2
            ;;
        --format)
            FORMAT="$2"
            if [[ ! "$FORMAT" =~ ^(json|html|csv|all)$ ]]; then
                echo -e "${RED}ERROR: Invalid format: $FORMAT${NC}"
                echo "Valid formats: json, html, csv, all"
                exit 2
            fi
            shift 2
            ;;
        --failures-only)
            FAILURES_ONLY=true
            shift
            ;;
        --report-from-file)
            REPORT_FROM_FILE="$2"
            if [ ! -f "$REPORT_FROM_FILE" ]; then
                echo -e "${RED}ERROR: File not found: $REPORT_FROM_FILE${NC}"
                exit 2
            fi
            shift 2
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            echo -e "${RED}ERROR: Unknown option: $1${NC}"
            exit 2
            ;;
        *)
            SERVERS+=("$1")
            shift
            ;;
    esac
done

# ════════════════════════════════════════════════════════════
# WCZYTANIE KONFIGURACJI
# ════════════════════════════════════════════════════════════

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}ERROR: Config file not found: $CONFIG_FILE${NC}"
    exit 2
fi

source "$CONFIG_FILE"

# ════════════════════════════════════════════════════════════
# OKREŚLENIE LISTY SERWERÓW
# ════════════════════════════════════════════════════════════

# Pomiń walidację serwerów gdy używamy --report-from-file
if [ -z "$REPORT_FROM_FILE" ]; then
    if [ ${#SERVERS[@]} -eq 0 ]; then
        # Użyj --servers-file jeśli podany, inaczej domyślny servers.txt
        if [ -n "$CUSTOM_SERVERS_FILE" ]; then
            SERVERS_FILE="$CUSTOM_SERVERS_FILE"
        else
            SERVERS_FILE="${CONTROL_BASE_DIR}/servers.txt"
        fi
        
        if [ ! -f "$SERVERS_FILE" ]; then
            echo -e "${RED}ERROR: No servers specified and $SERVERS_FILE not found${NC}"
            exit 2
        fi
        
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            SERVERS+=("$line")
        done < "$SERVERS_FILE"
    fi
fi

TOTAL_SERVERS=${#SERVERS[@]}

# ════════════════════════════════════════════════════════════
# PRZYGOTOWANIE KATALOGÓW
# ════════════════════════════════════════════════════════════

# Pomiń OUTPUT_DIR i nagłówek gdy używamy --report-from-file
if [ -z "$REPORT_FROM_FILE" ]; then
    RUN_DATE=$(date '+%Y-%m-%d')
    OUTPUT_DIR="${CONTROL_BASE_DIR}/status/${RUN_DATE}"
    mkdir -p "$OUTPUT_DIR"
    
    # ════════════════════════════════════════════════════════════
    # NAGŁÓWEK
    # ════════════════════════════════════════════════════════════
    
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  COLLECT STATUS - Zbieranie statusów serwerów${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo "Serwerów do sprawdzenia: ${TOTAL_SERVERS}"
    echo "Format: ${FORMAT}"
    echo "Katalog wynikowy: ${OUTPUT_DIR}"
    echo "Raporty: status-report.*"
    echo ""
fi

# ════════════════════════════════════════════════════════════
# TRYB --report-from-file: Generuj raporty z istniejącego JSON
# ════════════════════════════════════════════════════════════

if [ -n "$REPORT_FROM_FILE" ]; then
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  GENEROWANIE RAPORTÓW Z JSON${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo "Plik źródłowy: ${REPORT_FROM_FILE}"
    echo ""
    
    # Katalog wyjściowy = katalog gdzie jest JSON
    OUTPUT_DIR=$(dirname "$REPORT_FROM_FILE")
    
    # Wyciągnij bazową nazwę pliku (bez rozszerzenia) aby zachować timestamp
    # np: status-report_22-21.json → status-report_22-21
    BASE_NAME=$(basename "$REPORT_FROM_FILE" .json)
    
    # Generuj HTML + CSV z tą samą nazwą (nadpisz jeśli istnieją)
    generate_html_report "$REPORT_FROM_FILE" "${OUTPUT_DIR}/${BASE_NAME}.html"
    generate_csv_report "$REPORT_FROM_FILE" "${OUTPUT_DIR}/${BASE_NAME}.csv"
    
    echo ""
    echo -e "${GREEN}✓ Raporty wygenerowane:${NC}"
    echo -e "  ${GREEN}✓${NC} HTML: ${OUTPUT_DIR}/${BASE_NAME}.html"
    echo -e "  ${GREEN}✓${NC} CSV: ${OUTPUT_DIR}/${BASE_NAME}.csv"
    echo ""
    
    exit 0
fi

# ════════════════════════════════════════════════════════════
# ZBIERANIE STATUSÓW
# ════════════════════════════════════════════════════════════

server_num=0
for server in "${SERVERS[@]}"; do
    server_num=$((server_num + 1))
    collect_from_server "$server" "$server_num"
done

echo ""

# ════════════════════════════════════════════════════════════
# GENEROWANIE RAPORTÓW
# ════════════════════════════════════════════════════════════

case "$FORMAT" in
    json)
        generate_json_report "${OUTPUT_DIR}/status-report.json"
        echo -e "${GREEN}✓ Raport JSON: ${OUTPUT_DIR}/status-report.json${NC}"
        ;;
    html)
        # Najpierw JSON, potem HTML z JSON
        generate_json_report "${OUTPUT_DIR}/status-report.json"
        generate_html_report "${OUTPUT_DIR}/status-report.json" "${OUTPUT_DIR}/status-report.html"
        echo -e "${GREEN}✓ Raport HTML: ${OUTPUT_DIR}/status-report.html${NC}"
        ;;
    csv)
        # Najpierw JSON, potem CSV z JSON
        generate_json_report "${OUTPUT_DIR}/status-report.json"
        generate_csv_report "${OUTPUT_DIR}/status-report.json" "${OUTPUT_DIR}/status-report.csv"
        echo -e "${GREEN}✓ Raport CSV: ${OUTPUT_DIR}/status-report.csv${NC}"
        ;;
    all)
        # Najpierw JSON, potem CSV i HTML z JSON
        generate_json_report "${OUTPUT_DIR}/status-report.json"
        generate_csv_report "${OUTPUT_DIR}/status-report.json" "${OUTPUT_DIR}/status-report.csv"
        generate_html_report "${OUTPUT_DIR}/status-report.json" "${OUTPUT_DIR}/status-report.html"
        echo -e "${GREEN}✓ Raporty utworzone:${NC}"
        echo "  - ${OUTPUT_DIR}/status-report.json"
        echo "  - ${OUTPUT_DIR}/status-report.html"
        echo "  - ${OUTPUT_DIR}/status-report.csv"
        ;;
esac

# ════════════════════════════════════════════════════════════
# PODSUMOWANIE
# ════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  PODSUMOWANIE${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "  Sukces:        ${GREEN}${SUCCESS_COUNT}${NC}"
echo -e "  Błąd:          ${RED}${FAIL_COUNT}${NC}"
echo -e "  Nieosiągalne:  ${YELLOW}${UNREACHABLE_COUNT}${NC}"
echo "  Łącznie:       ${TOTAL_SERVERS}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"

exit 0
