#!/bin/bash

# ═══════════════════════════════════════════════════════════
# RHEL UPDATE ORCHESTRATOR
# ═══════════════════════════════════════════════════════════
# Skrypt:          orchestrator.sh
# Wersja projektu: 11.14
# Ostatnia zmiana: 2026-03-21
# Autor:           Krzysztof Boroń
# Opis:            Orkiestrator do zdalnych aktualizacji wielu serwerów RHEL
# ═══════════════════════════════════════════════════════════
# Główny skrypt orkiestrujący zdalne aktualizacje serwerów RHEL.
# Wykonuje update-worker.sh na wielu serwerach zdalnie przez SSH.
#
# Użycie:
#   ./orchestrator.sh [OPCJE] [SERWER1 SERWER2 ...]
#
# Przykłady:
#   ./orchestrator.sh                              # wszystkie z servers.txt
#   ./orchestrator.sh server1 server2              # tylko wybrane
#   ./orchestrator.sh --parallel 3 server1 server2 # 3 równolegle
#   ./orchestrator.sh --dry-run server1            # test bez aktualizacji
#   ./orchestrator.sh --config /custom.conf --all  # niestandardowy config
# ═══════════════════════════════════════════════════════════

readonly PROJECT_VERSION="11.14"
readonly SCRIPT_NAME="orchestrator.sh"
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
# ZMIENNE GLOBALNE
# ════════════════════════════════════════════════════════════

# Katalog skryptu (CONTROL_BASE_DIR)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Domyślna konfiguracja
DEFAULT_CONFIG="${SCRIPT_DIR}/orchestrator.conf"
CONFIG_FILE="${DEFAULT_CONFIG}"

# Tryb wykonania
EXECUTION_MODE="sequential"  # sequential lub parallel
PARALLEL_COUNT=1
DRY_RUN=false
COLLECT_STATUS=false  # czy zbierać statusy po zakończeniu
FORCE_RUN=false  # --force-run=now - pomija sprawdzanie ALLOWED_DAY

# Lista serwerów do przetworzenia
SERVERS=()
SERVERS_FILE=""  # opcjonalny plik z listą serwerów

# Katalog logów dla tego uruchomienia
RUN_DATE=$(date '+%Y-%m-%d')
RUN_LOGS_DIR=""

# Statystyki
TOTAL_SERVERS=0
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Listy serwerów wg statusu
declare -a SUCCESS_SERVERS
declare -a FAIL_SERVERS

# PID-y procesów w tle (dla trybu parallel)
declare -A SERVER_PIDS

# Katalog lock files (dla trybu parallel - zapobieganie duplikatom)
LOCKS_DIR=""


# ════════════════════════════════════════════════════════════
# FUNKCJE POMOCNICZE
# ════════════════════════════════════════════════════════════

# Wyświetla pomoc
show_help() {
    cat << 'EOF'
════════════════════════════════════════════════════════════
  RHEL UPDATE ORCHESTRATOR
════════════════════════════════════════════════════════════

UŻYCIE:
  ./orchestrator.sh [OPCJE] SERWER1 [SERWER2 ...]
  ./orchestrator.sh [OPCJE] --servers-file FILE

OPCJE:
  --config FILE           Użyj niestandardowej konfiguracji
                          (domyślnie: ./orchestrator.conf)
  
  --mode MODE             Tryb wykonania: sequential lub parallel
                          (domyślnie: sequential)
  
  --parallel N            Skrót dla --mode parallel, wykonuj max N
                          serwerów równocześnie (domyślnie: 1)
  
  --dry-run               Tryb testowy - sprawdź dostępne aktualizacje
                          bez faktycznej instalacji
  
  --collect-status        Po zakończeniu zbierz statusy z serwerów
                          i wygeneruj raporty (JSON, HTML, CSV)
  
  --servers-file FILE     Czytaj listę serwerów z pliku
  
  --force-run=now         Wymuś uruchomienie pomijając sprawdzanie ALLOWED_DAY
                          UWAGA: Użyj tylko w sytuacjach awaryjnych!
                          Wymaga DOKŁADNIE: --force-run=now
                          (wielkość liter bez znaczenia: now/NOW/Now)
  
  --help, -h              Pokaż tę pomoc

ARGUMENTY:
  SERWER1 SERWER2 ...     Lista serwerów do aktualizacji
                          (nazwy muszą odpowiadać plikom config/*.conf)

PRZYKŁADY:
  # Jeden serwer
  ./orchestrator.sh server1.prod.local

  # Kilka serwerów
  ./orchestrator.sh server1 server2 server3

  # Z pliku (dla większej ilości serwerów)
  ./orchestrator.sh --servers-file servers-prod.txt
  ./orchestrator.sh --servers-file /custom/path/lista.txt

  # Równolegle, max 3 naraz
  ./orchestrator.sh --parallel 3 server1 server2 server3 server4

  # Dry-run (test bez instalacji)
  ./orchestrator.sh --dry-run server1

  # Aktualizacja z automatycznym zbieraniem statusów
  ./orchestrator.sh --collect-status server1 server2

  # Z pliku + równolegle + statusy
  ./orchestrator.sh --parallel 3 --collect-status --servers-file prod.txt

  # Niestandardowa konfiguracja
  ./orchestrator.sh --config /etc/custom.conf server1

  # AWARYJNE: Wymuszenie uruchomienia poza dozwolonym dniem
  ./orchestrator.sh --force-run=now server1

PLIKI:
  servers.txt.example     Przykładowa lista serwerów
  orchestrator.conf       Główna konfiguracja
  config/HOSTNAME.conf    Konfiguracja per-serwer
  servers.txt             Lista serwerów (opcjonalna)
  logs/YYYY-MM-DD/        Logi z uruchomienia

KODY WYJŚCIA:
  0   Wszystkie serwery zaktualizowane pomyślnie
  1   Przynajmniej jeden serwer zakończył się błędem
  2   Błąd konfiguracji lub argumentów

════════════════════════════════════════════════════════════
EOF
}

# Loguje wiadomość do konsoli i do pliku summary
log_orchestrator() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${timestamp} - ${message}"
    
    if [ -n "${RUN_LOGS_DIR}" ]; then
        echo "${timestamp} - ${message}" | sed 's/\x1b\[[0-9;]*m//g' >> "${RUN_LOGS_DIR}/summary.txt"
    fi
}

# Sprawdza czy plik konfiguracyjny serwera istnieje
check_server_config() {
    local server="$1"
    local config_path="${CONTROL_BASE_DIR}/config/${server}.conf"
    
    if [ ! -f "$config_path" ]; then
        return 1
    fi
    return 0
}

# Pobiera wartość z konfiguracji serwera
get_server_config_value() {
    local server="$1"
    local var_name="$2"
    local default_value="$3"
    local config_path="${CONTROL_BASE_DIR}/config/${server}.conf"
    
    if [ ! -f "$config_path" ]; then
        echo "$default_value"
        return
    fi
    
    # Source config i pobierz wartość
    local value=$(source "$config_path" 2>/dev/null && eval echo "\${$var_name:-$default_value}")
    echo "$value"
}

# Wykonuje update-worker.sh na zdalnym serwerze
execute_remote_update() {
    local server="$1"
    local log_file="$2"
    
    log_orchestrator "${CYAN}[${server}] Rozpoczynam aktualizację...${NC}"
    
    # Pobierz konfigurację serwera
    local config_file="${CONTROL_BASE_DIR}/config/${server}.conf"
    local ssh_user=$(get_server_config_value "$server" "SSH_USER" "$DEFAULT_SSH_USER")
    local ssh_port=$(get_server_config_value "$server" "SSH_PORT" "$DEFAULT_SSH_PORT")
    local timeout_min=$(get_server_config_value "$server" "TIMEOUT_MINUTES" "$DEFAULT_TIMEOUT")
    local allowed_day=$(get_server_config_value "$server" "ALLOWED_DAY" "")
    
    # Sprawdź dzień tygodnia (jeśli zdefiniowany i nie FORCE_RUN)
    if [ -n "$allowed_day" ] && [ "$FORCE_RUN" != "true" ]; then
        local current_day=$(date '+%A')
        if [ "$(echo "${current_day}" | tr '[:upper:]' '[:lower:]')" != "$(echo "${allowed_day}" | tr '[:upper:]' '[:lower:]')" ]; then
            log_orchestrator "${YELLOW}[${server}] Pomijam - dzisiaj ${current_day}, dozwolony: ${allowed_day}${NC}"
            echo "SKIP: Wrong day (today: ${current_day}, allowed: ${allowed_day})" > "$log_file"
            return 2  # Skip
        fi
    elif [ -n "$allowed_day" ] && [ "$FORCE_RUN" == "true" ]; then
        local current_day=$(date '+%A')
        log_orchestrator "${YELLOW}⚠ FORCE RUN: Pomijam sprawdzanie ALLOWED_DAY dla ${server}${NC}"
        log_orchestrator "  Skonfigurowano: ${allowed_day}"
        log_orchestrator "  Dzisiaj:        ${current_day}"
        log_orchestrator "  Status:         OVERRIDDEN (--force-run=now)"
    fi
    
    # Sprawdź czy katalog zdalny istnieje
    log_orchestrator "${CYAN}[${server}] Sprawdzam katalog ${REMOTE_BASE_DIR}...${NC}"
    
    local dir_check=$(ssh -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} \
                          -o StrictHostKeyChecking=no \
                          -o UserKnownHostsFile=/dev/null \
                          -o LogLevel=ERROR \
                          -p "${ssh_port}" \
                          "${ssh_user}@${server}" \
                          "[ -d '${REMOTE_BASE_DIR}' ] && echo yes || echo no" 2>&1)
    
    if [ "$dir_check" != "yes" ]; then
        log_orchestrator "${RED}[${server}] BŁĄD: Katalog ${REMOTE_BASE_DIR} nie istnieje${NC}"
        log_orchestrator "${RED}[${server}] Uruchom: ./init-server.sh ${server}${NC}"
        echo "ERROR: Remote directory not found: ${REMOTE_BASE_DIR}" > "$log_file"
        echo "Run: ./init-server.sh ${server}" >> "$log_file"
        return 1  # Fail
    fi
    
    # Skopiuj konfigurację serwera
    log_orchestrator "${CYAN}[${server}] Kopiuję konfigurację...${NC}"
    
    scp -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -P "${ssh_port}" \
        "$config_file" \
        "${ssh_user}@${server}:${REMOTE_BASE_DIR}/config/current.conf" >> "$log_file" 2>&1
    
    if [ $? -ne 0 ]; then
        log_orchestrator "${RED}[${server}] BŁĄD: Nie można skopiować konfiguracji${NC}"
        echo "ERROR: Failed to copy config" >> "$log_file"
        return 1  # Fail
    fi
    
    # Skopiuj update-worker.sh
    log_orchestrator "${CYAN}[${server}] Kopiuję update-worker.sh...${NC}"
    
    scp -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -P "${ssh_port}" \
        "${CONTROL_BASE_DIR}/update-worker.sh" \
        "${ssh_user}@${server}:${REMOTE_BASE_DIR}/scripts/update-worker.sh" >> "$log_file" 2>&1
    
    if [ $? -ne 0 ]; then
        log_orchestrator "${RED}[${server}] BŁĄD: Nie można skopiować update-worker.sh${NC}"
        echo "ERROR: Failed to copy update-worker.sh" >> "$log_file"
        return 1  # Fail
    fi
    
    # Ustaw uprawnienia wykonywalne
    ssh -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -p "${ssh_port}" \
        "${ssh_user}@${server}" \
        "chmod +x ${REMOTE_BASE_DIR}/scripts/update-worker.sh" >> "$log_file" 2>&1
    
    # Zbuduj komendę worker z argumentami CLI
    local worker_cmd="sudo ${REMOTE_BASE_DIR}/scripts/update-worker.sh --base-dir ${REMOTE_BASE_DIR}"
    if [ "$DRY_RUN" == "true" ]; then
        worker_cmd="${worker_cmd} --dry-run"
    fi
    
    # Wykonaj worker zdalnie
    log_orchestrator "${CYAN}[${server}] Uruchamiam update-worker.sh (timeout: ${timeout_min}min)...${NC}"
    
    local timeout_sec=$((timeout_min * 60))
    
    # Inteligentny tryb: realtime dla sequential, cicho dla parallel
    # Sequential: używa tee (wyświetla + zapisuje)
    # Parallel: tylko >> (zapisuje, bez wyświetlania - unika chaosu)
    
    local ssh_cmd_base="ssh -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -p ${ssh_port} \
        ${ssh_user}@${server}"
    
    # Timeout z timeout command (jeśli dostępne) lub bez
    if command -v timeout &>/dev/null && [ ${timeout_min} -gt 0 ]; then
        if [ "$EXECUTION_MODE" == "sequential" ]; then
            # Sequential: realtime streaming
            ${ssh_cmd_base} "timeout ${timeout_sec} ${worker_cmd}" 2>&1 | tee -a "$log_file"
        else
            # Parallel: tylko do pliku
            ${ssh_cmd_base} "timeout ${timeout_sec} ${worker_cmd}" >> "$log_file" 2>&1
        fi
    else
        if [ "$EXECUTION_MODE" == "sequential" ]; then
            # Sequential: realtime streaming
            ${ssh_cmd_base} "${worker_cmd}" 2>&1 | tee -a "$log_file"
        else
            # Parallel: tylko do pliku
            ${ssh_cmd_base} "${worker_cmd}" >> "$log_file" 2>&1
        fi
    fi
    
    local exit_code=$?
    
    # Sprawdź kod wyjścia
    if [ $exit_code -eq 124 ]; then
        # Timeout
        log_orchestrator "${RED}[${server}] TIMEOUT po ${timeout_min} minutach${NC}"
        echo "ERROR: Timeout after ${timeout_min} minutes" >> "$log_file"
        return 1  # Fail
    elif [ $exit_code -eq 0 ]; then
        log_orchestrator "${GREEN}[${server}] ✓ Zakończono pomyślnie${NC}"
        return 0  # Success
    else
        log_orchestrator "${RED}[${server}] ✗ Błąd (kod wyjścia: ${exit_code})${NC}"
        echo "ERROR: Worker exited with code ${exit_code}" >> "$log_file"
        return 1  # Fail
    fi
}

# Przetwarza jeden serwer (wrapper dla sequential i parallel)
process_server() {
    local server="$1"
    local server_num="$2"
    
    # Określ nazwę pliku logu (tymczasowo)
    local temp_log="${RUN_LOGS_DIR}/${server}_TEMP.log"
    
    log_orchestrator "${BLUE}════════════════════════════════════════════════════════════${NC}"
    log_orchestrator "${BLUE}[${server_num}/${TOTAL_SERVERS}] ${server}${NC}"
    log_orchestrator "${BLUE}════════════════════════════════════════════════════════════${NC}"
    
    # Sprawdź config
    if ! check_server_config "$server"; then
        log_orchestrator "${RED}[${server}] BŁĄD: Brak pliku konfiguracyjnego${NC}"
        log_orchestrator "${RED}  Oczekiwany: ${CONTROL_BASE_DIR}/config/${server}.conf${NC}"
        echo "ERROR: Config file not found" > "$temp_log"
        
        # Przemianuj log
        local final_log="${RUN_LOGS_DIR}/FAIL_${server}.log"
        mv "$temp_log" "$final_log" 2>/dev/null
        
        FAIL_SERVERS+=("$server")
        return 1
    fi
    
    # Wykonaj aktualizację
    execute_remote_update "$server" "$temp_log"
    local result=$?
    
    # Określ końcową nazwę logu na podstawie wyniku
    local final_log=""
    
    case $result in
        0)
            # Success
            if [ "$DRY_RUN" == "true" ]; then
                # Dry-run sukces - nie logujemy
                rm -f "$temp_log"
            else
                final_log="${RUN_LOGS_DIR}/${server}.log"
                mv "$temp_log" "$final_log" 2>/dev/null
            fi
            SUCCESS_SERVERS+=("$server")
            ;;
        1)
            # Fail
            if [ "$DRY_RUN" == "true" ]; then
                final_log="${RUN_LOGS_DIR}/dry-run_FAIL_${server}.log"
            else
                final_log="${RUN_LOGS_DIR}/FAIL_${server}.log"
            fi
            mv "$temp_log" "$final_log" 2>/dev/null
            
            # Wyciągnij szczegółowy log do osobnego pliku (jeśli worker wysłał cat)
            if grep -q "SZCZEGÓŁOWY LOG BŁĘDU" "$final_log" 2>/dev/null; then
                local full_log="${RUN_LOGS_DIR}/FAIL_${server}_FULL.log"
                awk '/════════════════════════════════════════════════════════════/{flag=1} flag' \
                    "$final_log" > "$full_log"
                
                log_orchestrator "${YELLOW}[${server}] Szczegółowy log: FAIL_${server}_FULL.log${NC}"
            fi
            
            FAIL_SERVERS+=("$server")
            ;;
        2)
            # Skip
            rm -f "$temp_log"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            ;;
    esac
    
    return $result
}


# ════════════════════════════════════════════════════════════
# PARSOWANIE ARGUMENTÓW
# ════════════════════════════════════════════════════════════

# Jeśli brak argumentów, pokaż help
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
        --mode)
            EXECUTION_MODE="$2"
            if [[ ! "$EXECUTION_MODE" =~ ^(sequential|parallel)$ ]]; then
                echo -e "${RED}ERROR: Invalid mode: $EXECUTION_MODE${NC}"
                echo "Valid modes: sequential, parallel"
                exit 2
            fi
            shift 2
            ;;
        --parallel)
            EXECUTION_MODE="parallel"
            PARALLEL_COUNT="$2"
            if ! [[ "$PARALLEL_COUNT" =~ ^[0-9]+$ ]] || [ "$PARALLEL_COUNT" -lt 1 ]; then
                echo -e "${RED}ERROR: Invalid parallel count: $PARALLEL_COUNT${NC}"
                exit 2
            fi
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --collect-status)
            COLLECT_STATUS=true
            shift
            ;;
        --servers-file)
            SERVERS_FILE="$2"
            shift 2
            ;;
        --force-run=*)
            FORCE_VALUE="${1#*=}"
            # Case-insensitive porównanie
            FORCE_VALUE_LOWER=$(echo "$FORCE_VALUE" | tr '[:upper:]' '[:lower:]')
            if [ "$FORCE_VALUE_LOWER" != "now" ]; then
                echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
                echo -e "${RED}ERROR: --force-run wymaga DOKŁADNIE wartości 'now'${NC}"
                echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo "Podano: --force-run=$FORCE_VALUE"
                echo "Wymagane: --force-run=now"
                echo ""
                echo "To zabezpieczenie zapewnia, że administrator jest świadomy"
                echo "wyłamania się ze standardowego harmonogramu aktualizacji."
                echo ""
                echo "Wielkość liter nie ma znaczenia: now, NOW, Now - wszystkie OK"
                echo ""
                exit 2
            fi
            FORCE_RUN=true
            shift
            ;;
        --force-run)
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo -e "${RED}ERROR: --force-run wymaga wartości 'now'${NC}"
            echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "Poprawne użycie: --force-run=now"
            echo ""
            echo "To zabezpieczenie zapewnia, że administrator jest świadomy"
            echo "wyłamania się ze standardowego harmonogramu aktualizacji."
            echo ""
            exit 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            echo -e "${RED}ERROR: Unknown option: $1${NC}"
            echo "Run: $0 --help"
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

# Weryfikacja
if [ -z "$CONTROL_BASE_DIR" ] || [ -z "$REMOTE_BASE_DIR" ]; then
    echo -e "${RED}ERROR: CONTROL_BASE_DIR or REMOTE_BASE_DIR not defined${NC}"
    exit 2
fi

# ════════════════════════════════════════════════════════════
# OKREŚLENIE LISTY SERWERÓW
# ════════════════════════════════════════════════════════════

# Sprawdź czy podano --servers-file
if [ -n "$SERVERS_FILE" ]; then
    # Wczytaj serwery z pliku
    if [ ! -f "$SERVERS_FILE" ]; then
        echo -e "${RED}ERROR: Servers file not found: $SERVERS_FILE${NC}"
        exit 2
    fi
    
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        SERVERS+=("$line")
    done < "$SERVERS_FILE"
    
    if [ ${#SERVERS[@]} -eq 0 ]; then
        echo -e "${RED}ERROR: No servers found in file: $SERVERS_FILE${NC}"
        echo "File is empty or contains only comments"
        exit 2
    fi
fi

# Sprawdź czy mamy jakiekolwiek serwery (z pliku lub argumentów)
if [ ${#SERVERS[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No servers specified${NC}"
    echo ""
    echo "Usage:"
    echo "  $0 server1 [server2 ...]"
    echo "  $0 --servers-file FILE"
    echo ""
    echo "Run '$0 --help' for more information"
    exit 2
fi

TOTAL_SERVERS=${#SERVERS[@]}

# ════════════════════════════════════════════════════════════
# PRZYGOTOWANIE KATALOGÓW LOGÓW
# ════════════════════════════════════════════════════════════

RUN_LOGS_DIR="${CONTROL_BASE_DIR}/${LOGS_DIR}/${RUN_DATE}"
mkdir -p "$RUN_LOGS_DIR"

# ════════════════════════════════════════════════════════════
# POTWIERDZENIE FORCE_RUN (jeśli użyto)
# ════════════════════════════════════════════════════════════

if [ "$FORCE_RUN" == "true" ]; then
    current_day=$(date '+%A')
    current_datetime=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Policz ile serwerów będzie wymuszonych
    force_count=0
    ok_count=0
    nocfg_count=0
    noday_count=0
    
    # Przygotuj tabelę serwerów (z kolorami bezpośrednio)
    declare -a server_rows
    server_num=0
    
    for server in "${SERVERS[@]}"; do
        server_num=$((server_num + 1))
        config_file="${CONTROL_BASE_DIR}/config/${server}.conf"
        
        # Reset zmiennych przed source
        ALLOWED_DAY=""
        
        if [ -f "$config_file" ]; then
            source "$config_file" 2>/dev/null
            allowed_day="${ALLOWED_DAY:-}"
            
            if [ -n "$allowed_day" ]; then
                if [ "$(echo "${current_day}" | tr '[:upper:]' '[:lower:]')" != "$(echo "${allowed_day}" | tr '[:upper:]' '[:lower:]')" ]; then
                    # WYMUSZONY - czerwony
                    status="${RED}⚠️  WYMUSZONY${NC}"
                    force_count=$((force_count + 1))
                else
                    # ZGODNY - zielony
                    status="${GREEN}✓  ZGODNY${NC}"
                    ok_count=$((ok_count + 1))
                fi
            else
                # Brak ALLOWED_DAY w config
                allowed_day="BRAK DNIA"
                status="${YELLOW}-  BRAK DNIA${NC}"
                noday_count=$((noday_count + 1))
            fi
        else
            # Brak pliku config
            allowed_day="BRAK CONFIG"
            status="${YELLOW}-  BRAK CFG${NC}"
            nocfg_count=$((nocfg_count + 1))
        fi
        
        # Dodaj wiersz do tablicy (już z kolorami)
        server_rows+=("$(printf " %-2s %-23s %-18s %s" "$server_num" "$server" "$allowed_day" "$status")")
    done
    
    # ═══════════════════════════════════════════════════════════
    # WYŚWIETL OSTRZEŻENIE
    # ═══════════════════════════════════════════════════════════
    
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}           ⚠️  FORCE RUN ENABLED  ⚠️${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}WYMUSZASZ AKTUALIZACJĘ POZA HARMONOGRAMEM!${NC}"
    echo ""
    echo "Dzisiaj: ${current_day}, ${current_datetime}"
    echo "Tryb:    ${EXECUTION_MODE}"
    
    # Źródło serwerów
    if [ -n "$SERVERS_FILE" ]; then
        echo "Źródło:  --servers-file ${SERVERS_FILE}"
    else
        echo "Źródło:  argumenty linii poleceń"
    fi
    
    echo "Serwery: ${TOTAL_SERVERS}"
    echo ""
    echo "LISTA SERWERÓW:"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf " %-2s %-23s %-18s %s\n" "#" "Serwer" "ALLOWED_DAY" "Status"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Wyświetl wiersze (już mają kolory, bez sed!)
    for row in "${server_rows[@]}"; do
        echo -e "$row"
    done
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "PODSUMOWANIE:"
    
    if [ $force_count -gt 0 ]; then
        echo "  • Normalnie: ${force_count} serwery byłyby pominięte (wrong day)"
    fi
    
    echo "  • Z FORCE:   Wszystkie ${TOTAL_SERVERS} zostaną zaktualizowane"
    echo "  • Logging:   Operacja zapisana w logach"
    echo ""
    
    if [ $force_count -gt 0 ]; then
        echo -e "${YELLOW}⚠️  ${force_count} z ${TOTAL_SERVERS} serwerów będzie zaktualizowanych POZA harmonogramem!${NC}"
        echo ""
    fi
    
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # ═══════════════════════════════════════════════════════════
    # MRUGAJĄCE POTWIERDZENIE (tylko jeśli TTY)
    # ═══════════════════════════════════════════════════════════
    
    if [ -t 0 ]; then
        # ANSI codes
        BLINK='\033[5m'        # Mruganie
        BOLD_RED='\033[1;31m'  # Pogrubiony czerwony
        RESET='\033[0m'
        
        echo ""
        echo -e "${BLINK}>>>${RESET} ${BOLD_RED}CZY JESTEŚ ŚWIADOMY KONSEKWENCJI WYKONANIA TEJ AKCJI?${RESET} ${BLINK}<<<${RESET}"
        echo ""
        echo -n "Aby kontynuować, wpisz 'TAK' (wielkie litery): "
        read confirm
        
        if [ "$confirm" != "TAK" ]; then
            echo ""
            echo "Operacja anulowana przez użytkownika."
            echo ""
            exit 0
        fi
        
        echo ""
        echo -e "${GREEN}✓ Potwierdzono. Kontynuuję z FORCE_RUN...${NC}"
        echo ""
    else
        # Brak TTY (cron)
        echo "⚠️ WARNING: FORCE_RUN enabled in non-interactive mode (no TTY)" >&2
        echo "⚠️ ALLOWED_DAY checks will be bypassed for ${TOTAL_SERVERS} servers" >&2
        if [ $force_count -gt 0 ]; then
            echo "⚠️ ${force_count} servers will be updated OUTSIDE their maintenance window" >&2
        fi
    fi
fi

# ════════════════════════════════════════════════════════════
# NAGŁÓWEK
# ════════════════════════════════════════════════════════════

log_orchestrator "${YELLOW}════════════════════════════════════════════════════════════${NC}"
log_orchestrator "${YELLOW}  RHEL UPDATE ORCHESTRATOR${NC}"
log_orchestrator "${YELLOW}════════════════════════════════════════════════════════════${NC}"
log_orchestrator "Data:           $(date '+%Y-%m-%d %H:%M:%S')"
log_orchestrator "Tryb:           ${EXECUTION_MODE}"
if [ "$EXECUTION_MODE" == "parallel" ]; then
    log_orchestrator "Równolegle:     ${PARALLEL_COUNT}"
fi
log_orchestrator "Dry-run:        ${DRY_RUN}"
log_orchestrator "Serwerów:       ${TOTAL_SERVERS}"
log_orchestrator "Logi:           ${RUN_LOGS_DIR}"
log_orchestrator "${YELLOW}════════════════════════════════════════════════════════════${NC}"
log_orchestrator ""

# ════════════════════════════════════════════════════════════
# WYKONANIE - TRYB SEKWENCYJNY
# ════════════════════════════════════════════════════════════

if [ "$EXECUTION_MODE" == "sequential" ]; then
    server_num=0
    for server in "${SERVERS[@]}"; do
        server_num=$((server_num + 1))
        
        process_server "$server" "$server_num"
        result=$?
        
        case $result in
            0) SUCCESS_COUNT=$((SUCCESS_COUNT + 1)) ;;
            1) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
            2) ;; # Skip already counted
        esac
        
        log_orchestrator ""
    done

# ════════════════════════════════════════════════════════════
# WYKONANIE - TRYB RÓWNOLEGŁY
# ════════════════════════════════════════════════════════════

elif [ "$EXECUTION_MODE" == "parallel" ]; then
    # Katalog lock files dla trybu parallel
    LOCKS_DIR="${RUN_LOGS_DIR}/.locks"
    mkdir -p "$LOCKS_DIR"
    
    server_num=0

    for server in "${SERVERS[@]}"; do
        server_num=$((server_num + 1))

        # Sprawdź czy ten serwer nie jest już przetwarzany (lock file)
        local_lock="${LOCKS_DIR}/${server}.lock"
        if [ -f "$local_lock" ]; then
            log_orchestrator "${YELLOW}[${server}] UWAGA: Serwer już przetwarzany (lock: ${local_lock}) - pomijam duplikat${NC}"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi

        # Utwórz lock file
        echo $$ > "$local_lock"

        # Czekaj aż będzie wolny slot
        while [ $(jobs -r | wc -l) -ge $PARALLEL_COUNT ]; do
            sleep 1
        done

        # Uruchom w tle
        # Trap na EXIT gwarantuje usunięcie locka nawet przy SIGKILL/błędzie
        # Wynik zapisywany do pliku - subshell nie może modyfikować tablic rodzica
        (
            trap "rm -f '${local_lock}'" EXIT
            process_server "$server" "$server_num"
            result=$?
            # Zapisz wynik do pliku dla procesu głównego
            echo "$result" > "${LOCKS_DIR}/${server}.result"
            exit $result
        ) &

        SERVER_PIDS[$server]=$!
    done

    # Czekaj na wszystkie procesy
    log_orchestrator "${CYAN}Czekam na zakończenie wszystkich serwerów...${NC}"
    log_orchestrator ""

    for server in "${SERVERS[@]}"; do
        pid=${SERVER_PIDS[$server]}
        if [ -z "$pid" ]; then
            continue  # serwer był pominięty jako duplikat
        fi
        wait $pid
        result=$?

        # Odczytaj wynik z pliku (pewniejsze niż exit code przy równoległości)
        result_file="${LOCKS_DIR}/${server}.result"
        if [ -f "$result_file" ]; then
            result=$(cat "$result_file")
            rm -f "$result_file"
        fi

        case $result in
            0)
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                SUCCESS_SERVERS+=("$server")
                ;;
            1)
                FAIL_COUNT=$((FAIL_COUNT + 1))
                FAIL_SERVERS+=("$server")
                ;;
            2)
                ;; # Skip already counted
        esac
    done
fi

# ════════════════════════════════════════════════════════════
# TWORZENIE FAIL.TXT
# ════════════════════════════════════════════════════════════

FAIL_FILE="${RUN_LOGS_DIR}/FAIL.txt"

if [ ${#FAIL_SERVERS[@]} -gt 0 ]; then
    > "$FAIL_FILE"
    for server in "${FAIL_SERVERS[@]}"; do
        # Sprawdź czy to dry-run fail
        if [ -f "${RUN_LOGS_DIR}/dry-run_FAIL_${server}.log" ]; then
            echo "dry-run:${server}" >> "$FAIL_FILE"
        else
            echo "${server}" >> "$FAIL_FILE"
        fi
    done
fi

# ════════════════════════════════════════════════════════════
# PODSUMOWANIE
# ════════════════════════════════════════════════════════════

log_orchestrator "${YELLOW}════════════════════════════════════════════════════════════${NC}"
log_orchestrator "${YELLOW}  PODSUMOWANIE${NC}"
log_orchestrator "${YELLOW}════════════════════════════════════════════════════════════${NC}"
log_orchestrator "Łącznie:        ${TOTAL_SERVERS}"
log_orchestrator "Sukces:         ${GREEN}${SUCCESS_COUNT}${NC}"
log_orchestrator "Błąd:           ${RED}${FAIL_COUNT}${NC}"
log_orchestrator "Pominięto:      ${YELLOW}${SKIP_COUNT}${NC}"
log_orchestrator ""

if [ ${#SUCCESS_SERVERS[@]} -gt 0 ]; then
    log_orchestrator "${GREEN}Serwery zaktualizowane pomyślnie:${NC}"
    for server in "${SUCCESS_SERVERS[@]}"; do
        log_orchestrator "${GREEN}  ✓ ${server}${NC}"
    done
    log_orchestrator ""
fi

if [ ${#FAIL_SERVERS[@]} -gt 0 ]; then
    log_orchestrator "${RED}Serwery z błędami:${NC}"
    for server in "${FAIL_SERVERS[@]}"; do
        log_orchestrator "${RED}  ✗ ${server}${NC}"
    done
    log_orchestrator ""
    log_orchestrator "${RED}Lista serwerów z błędami zapisana w:${NC}"
    log_orchestrator "${RED}  ${FAIL_FILE}${NC}"
    log_orchestrator ""
fi

log_orchestrator "Szczegółowe logi w: ${RUN_LOGS_DIR}"
log_orchestrator "${YELLOW}════════════════════════════════════════════════════════════${NC}"

# ════════════════════════════════════════════════════════════
# ZBIERANIE STATUSÓW (jeśli włączone)
# ════════════════════════════════════════════════════════════

if [ "$COLLECT_STATUS" == "true" ]; then
    log_orchestrator ""
    log_orchestrator "${CYAN}Zbieranie statusów z serwerów...${NC}"
    
    # Przygotuj listę serwerów które były aktualizowane
    servers_list=""
    for server in "${SERVERS[@]}"; do
        if [ -z "$servers_list" ]; then
            servers_list="$server"
        else
            servers_list="${servers_list} ${server}"
        fi
    done
    
    # Wywołaj collect-status.sh
    if [ -x "${CONTROL_BASE_DIR}/collect-status.sh" ]; then
        "${CONTROL_BASE_DIR}/collect-status.sh" --format all ${servers_list}
    else
        log_orchestrator "${RED}BŁĄD: collect-status.sh nie znaleziony lub nie wykonywalny${NC}"
    fi
    
    log_orchestrator ""
fi

# ════════════════════════════════════════════════════════════
# KOD WYJŚCIA
# ════════════════════════════════════════════════════════════

if [ $FAIL_COUNT -eq 0 ]; then
    exit 0
else
    exit 1
fi

