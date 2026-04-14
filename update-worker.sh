#!/bin/bash

# ═══════════════════════════════════════════════════════════
# RHEL UPDATE ORCHESTRATOR
# ═══════════════════════════════════════════════════════════
# Skrypt:          update-worker.sh
# Wersja projektu: 11.14
# Ostatnia zmiana: 2026-04-02
# Autor:           Krzysztof Boroń
# Opis:            Worker do aktualizacji pojedynczego serwera RHEL
# ═══════════════════════════════════════════════════════════
# Ten skrypt jest wykonywany NA SERWERZE ZDALNYM przez orchestrator.
# NIE URUCHAMIAJ go bezpośrednio - użyj orchestrator.sh
#
# Wymagania:
# - Katalog: /opt/remote_updates_DUIT-AS-DB/ (lub REMOTE_BASE_DIR)
# - Konfiguracja: config/current.conf (kopiowana przez orchestrator)
# - Uprawnienia: root (przez sudo)
# ═══════════════════════════════════════════════════════════

readonly PROJECT_VERSION="11.14"
readonly SCRIPT_NAME="update-worker.sh"
readonly LAST_CHANGE="2026-04-02"
readonly AUTHOR="Krzysztof Boroń"

set -o pipefail

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ════════════════════════════════════════════════════════════
# PARSOWANIE ARGUMENTÓW
# ════════════════════════════════════════════════════════════

DRY_RUN=false
REMOTE_BASE_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --base-dir)
            REMOTE_BASE_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            shift
            ;;
    esac
done

# Domyślna wartość jeśli nie przekazano
REMOTE_BASE_DIR="${REMOTE_BASE_DIR:-/opt/remote_updates_DUIT-AS-DB}"

# ════════════════════════════════════════════════════════════
# INICJALIZACJA KATALOGÓW I KONFIGURACJI
# ════════════════════════════════════════════════════════════

# Struktura
CONFIG_FILE="${REMOTE_BASE_DIR}/config/current.conf"
LOG_DIR="${REMOTE_BASE_DIR}/logs"
SCRIPT_DIR="${REMOTE_BASE_DIR}"

# Pliki tymczasowe
DNF_OUTPUT="${REMOTE_BASE_DIR}/dnf_output.tmp"
DNF_ERROR="${REMOTE_BASE_DIR}/dnf_error.tmp"

# Znacznik czasu
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M')

# Status (będzie aktualizowany)
WORKER_STATUS="SUCCESS"

# ════════════════════════════════════════════════════════════
# SPRAWDZENIE PREREKVIZYTÓW
# ════════════════════════════════════════════════════════════

# Sprawdź katalog bazowy
if [ ! -d "${REMOTE_BASE_DIR}" ]; then
    echo "FATAL: Remote base directory not found: ${REMOTE_BASE_DIR}"
    echo "Run init-server.sh first on this server!"
    exit 1
fi

# Sprawdź konfigurację
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "FATAL: Configuration file not found: ${CONFIG_FILE}"
    echo "Orchestrator should copy config before running worker!"
    exit 1
fi

# Wczytaj konfigurację serwera
source "${CONFIG_FILE}"

# Utwórz katalog logów jeśli nie istnieje
mkdir -p "${LOG_DIR}"

# Określ nazwę pliku logu (tymczasowo, zostanie przemianowany na końcu)
if [ "${DRY_RUN}" == "true" ]; then
    LOG_FILE="${LOG_DIR}/dry-run_TEMP_${TIMESTAMP}.log"
else
    LOG_FILE="${LOG_DIR}/TEMP_${TIMESTAMP}.log"
fi

# Funkcja do logowania
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - ${message}" | sed 's/\\033\[[0-9;]*m//g' >> "${LOG_FILE}"
    echo -e "${timestamp} - ${message}"
}

# Funkcja oznaczania niepowodzenia
mark_failure() {
    WORKER_STATUS="FAIL"
}

# ════════════════════════════════════════════════════════════
# INSTALACJA NARZĘDZI (jeśli brak)
# ════════════════════════════════════════════════════════════

# Sprawdź czy jq jest zainstalowany (potrzebny do status.json)
if ! command -v jq &>/dev/null; then
    echo "Instaluję narzędzie jq (wymagane do status.json)..."
    dnf install -y jq &>/dev/null
    if ! command -v jq &>/dev/null; then
        echo "UWAGA: Nie udało się zainstalować jq - status będzie generowany bez jq"
    fi
fi

# ════════════════════════════════════════════════════════════
# FUNKCJA AKTUALIZACJI STATUS.JSON
# ════════════════════════════════════════════════════════════

update_status_file() {
    local result="$1"           # SUCCESS/FAIL/SKIP/DRY_RUN_*
    local packages="${2:-0}"    # liczba pakietów
    local critical="${3:-0}"    # liczba krytycznych
    local reboot="${4:-false}"  # czy restart
    local reboot_reason="$5"    # powód restartu
    local error_msg="$6"        # komunikat błędu
    
    local status_file="${REMOTE_BASE_DIR}/status.json"
    local hostname_full=$(hostname -f 2>/dev/null || hostname)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local epoch=$(date '+%s')
    
    # Generuj JSON (pure bash - bez jq, dla kompatybilności)
    cat > "${status_file}" << EOF
{
  "hostname": "${hostname_full}",
  "fqdn": "${hostname_full}",
  "last_run": {
    "timestamp": "${timestamp}",
    "epoch": ${epoch}
  },
  "result": "${result}",
  "mode": "$([ "$DRY_RUN" == "true" ] && echo "dry-run" || echo "normal")",
  "packages": {
    "total": ${packages},
    "critical": ${critical}
  },
  "services_stopped": $([ ${critical} -gt 0 ] && echo "true" || echo "false"),
  "reboot": {
    "scheduled": ${reboot},
    "reason": $([ -n "${reboot_reason}" ] && echo "\"${reboot_reason}\"" || echo "null"),
    "delay_minutes": ${REBOOT_DELAY_MINUTES:-1}
  },
  "config": {
    "allowed_day": "${ALLOWED_DAY:-}",
    "auto_reboot": "${AUTO_REBOOT_AFTER_UPDATE:-never}",
    "enable_repos": "${ENABLE_REPOS:-}"
  },
  "error": $([ -n "${error_msg}" ] && echo "\"${error_msg}\"" || echo "null")
}
EOF
    
    # Ustaw uprawnienia
    chmod 644 "${status_file}"
}

# Sprawdź czy root
if [ "$EUID" -ne 0 ]; then
    log_message "${RED}BŁĄD: Skrypt musi być uruchomiony jako root${NC}"
    mark_failure
    exit_with_full_log
fi

log_message "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
log_message "${YELLOW}  RHEL UPDATE WORKER - $(hostname)${NC}"
log_message "${YELLOW}  Tryb: $([ "$DRY_RUN" == "true" ] && echo "DRY-RUN" || echo "NORMALNA AKTUALIZACJA")${NC}"
log_message "${YELLOW}  Config: ${CONFIG_FILE}${NC}"
log_message "${YELLOW}═══════════════════════════════════════════════════════════${NC}"


# ════════════════════════════════════════════════════════════
# FUNKCJE POMOCNICZE
# ════════════════════════════════════════════════════════════

# Buduje argument --exclude dla DNF
build_exclude_arg() {
    local excludes=""
    for pkg in "${SKIPPED_PACKAGES[@]}"; do
        if [ -z "$excludes" ]; then
            excludes="$pkg"
        else
            excludes="${excludes},${pkg}"
        fi
    done
    echo "$excludes"
}

# Buduje argument --enablerepo dla DNF
build_enablerepo_arg() {
    local repos="$1"
    local enablerepos=""
    
    # Pusta wartość = brak argumentu
    if [ -z "$repos" ]; then
        echo ""
        return
    fi
    
    # Wildcard "*" = wszystkie repo
    if [ "$repos" == "*" ]; then
        echo "--enablerepo=*"
        return
    fi
    
    # Lista oddzielona przecinkami
    IFS=',' read -ra REPO_ARRAY <<< "$repos"
    for repo in "${REPO_ARRAY[@]}"; do
        # Usuń spacje z początku i końca
        repo=$(echo "$repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$repo" ]; then
            enablerepos="${enablerepos} --enablerepo=${repo}"
        fi
    done
    
    echo "$enablerepos"
}

# Sprawdza czy pakiet jest krytyczny
is_critical_package() {
    local package_name="$1"
    for critical in "${CRITICAL_PACKAGES[@]}"; do
        if echo "$package_name" | grep -qE "$critical"; then
            return 0
        fi
    done
    return 1
}

# Parsuje pakiety z wyjścia dnf check-update
parse_dnf_packages() {
    local input_file="$1"
    awk 'NF==3 \
         && $1 ~ /\.(x86_64|noarch|i686|aarch64|ppc64le|s390x)$/ \
         && $2 ~ /^[0-9:]/ \
         {print $1}' "$input_file"
}

# Kończy z błędem i wypisuje pełny log (dla orchestratora)
exit_with_full_log() {
    local exit_code="${1:-1}"
    
    # Jeśli log został już przeniesiony do FINAL_LOG, użyj go
    local log_to_show="${FINAL_LOG:-$LOG_FILE}"
    
    if [ -f "$log_to_show" ]; then
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "  SZCZEGÓŁOWY LOG BŁĘDU (dla diagnostyki)"
        echo "════════════════════════════════════════════════════════════"
        cat "$log_to_show"
    fi
    
    exit "$exit_code"
}

# Loguje listę pomijanych pakietów
log_skipped_packages() {
    if [ ${#SKIPPED_PACKAGES[@]} -eq 0 ]; then
        log_message "${GREEN}✓ Brak pakietów pomijanych${NC}"
    else
        log_message "${YELLOW}Pakiety pomijane (${#SKIPPED_PACKAGES[@]}):${NC}"
        for pkg in "${SKIPPED_PACKAGES[@]}"; do
            log_message "${YELLOW}  - ${pkg}${NC}"
        done
    fi
}

# Analiza błędów DNF
analyze_dnf_error() {
    local exit_code=$1
    local error_output="$2"

    log_message "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log_message "${RED}ANALIZA BŁĘDU DNF (kod wyjścia: ${exit_code})${NC}"
    log_message "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    case ${exit_code} in
        0)   log_message "${GREEN}Status: Sukces${NC}"; return 0 ;;
        1)   log_message "${RED}Status: Błąd ogólny${NC}" ;;
        3)   log_message "${RED}Status: Błąd pobierania metadanych${NC}" ;;
        100) log_message "${RED}Status: Błąd zależności pakietów${NC}" ;;
        200) log_message "${RED}Status: Operacja przerwana${NC}" ;;
        *)   log_message "${RED}Status: Nieznany błąd (kod: ${exit_code})${NC}" ;;
    esac

    if grep -qi "cannot download repomd.xml\|failed to synchronize cache\|timeout.*reached\|network.*unreachable" "$error_output"; then
        log_message "${YELLOW}Kategoria: PROBLEM SIECIOWY${NC}"
        log_message "${YELLOW}Zalecane działania:${NC}"
        log_message "${YELLOW}  1. ping -c 3 8.8.8.8${NC}"
        log_message "${YELLOW}  2. ping -c 3 cdn.redhat.com${NC}"
        log_message "${YELLOW}  3. subscription-manager status${NC}"
        log_message "${YELLOW}  4. dnf clean all && dnf makecache${NC}"

    elif grep -qi "insufficient disk space\|no space left" "$error_output"; then
        log_message "${YELLOW}Kategoria: BRAK MIEJSCA${NC}"
        log_message "${YELLOW}Zalecane: df -h, dnf clean all, journalctl --vacuum-time=7d${NC}"

    elif grep -qi "conflicts with\|requires.*but\|nothing provides" "$error_output"; then
        log_message "${YELLOW}Kategoria: KONFLIKT ZALEŻNOŚCI${NC}"
        log_message "${YELLOW}Zalecane: dnf check, dnf update --skip-broken${NC}"

    elif grep -qi "waiting for process\|holding.*lock" "$error_output"; then
        log_message "${YELLOW}Kategoria: ZABLOKOWANY DNF${NC}"
        log_message "${YELLOW}Zalecane: ps aux | grep dnf, rm -f /var/run/dnf.pid${NC}"

    elif grep -qi "corrupt\|checksum.*not match\|gpg.*failed" "$error_output"; then
        log_message "${YELLOW}Kategoria: USZKODZONE PAKIETY${NC}"
        log_message "${YELLOW}Zalecane: dnf clean all, rpm --rebuilddb${NC}"

    elif grep -qi "permission denied\|cannot open database" "$error_output"; then
        log_message "${YELLOW}Kategoria: PROBLEM Z UPRAWNIENIAMI${NC}"
        log_message "${YELLOW}Zalecane: whoami, ls -la /var/lib/rpm${NC}"

    elif grep -qi "rpm exception occurred: package not installed" "$error_output"; then
        log_message "${YELLOW}Kategoria: OSTRZEŻENIE RPM (nieszkodliwe)${NC}"
        log_message "${YELLOW}Opis: Pakiet był już usunięty przed zakończeniem transakcji${NC}"
        log_message "${YELLOW}Zalecane: rpm -Va (weryfikacja bazy RPM), sprawdź czy transakcja była Complete!${NC}"
    fi

    log_message "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    return 1
}

# Zatrzymuje jedną instancję Oracle
stop_oracle_instance() {
    local sid="$1"
    local listener="$2"
    local oracle_home="$3"

    log_message "${YELLOW}  ┌─────────────────────────────────────────────────────┐${NC}"
    log_message "${YELLOW}  │ SID=${sid} LISTENER=${listener}${NC}"
    log_message "${YELLOW}  │ HOME=${oracle_home}${NC}"
    log_message "${YELLOW}  └─────────────────────────────────────────────────────┘${NC}"

    if [ ! -d "${oracle_home}" ]; then
        log_message "${RED}  ✗ BŁĄD: ORACLE_HOME nie istnieje: ${oracle_home}${NC}"
        return 1
    fi

    if [ ! -x "${oracle_home}/bin/sqlplus" ] || [ ! -x "${oracle_home}/bin/lsnrctl" ]; then
        log_message "${RED}  ✗ BŁĄD: Brak sqlplus lub lsnrctl w ${oracle_home}/bin/${NC}"
        return 1
    fi

    # Zatrzymaj listener (NAJPIERW - zamknij drzwi dla nowych połączeń)
    log_message "${YELLOW}  Zatrzymuję listener (${listener})...${NC}"
    su - "${ORACLE_USER}" -c "
        export ORACLE_HOME=${oracle_home}
        export PATH=\${ORACLE_HOME}/bin:\${PATH}
        ${oracle_home}/bin/lsnrctl stop ${listener}
    " >> "${LOG_FILE}" 2>&1

    if [ $? -eq 0 ]; then
        log_message "${GREEN}  ✓ lsnrctl stop zakończony [${listener}]${NC}"
    else
        log_message "${RED}  ✗ lsnrctl stop błąd [${listener}]${NC}"
    fi

    sleep 3

    if ! pgrep -f "tnslsnr ${listener}" > /dev/null 2>&1; then
        log_message "${GREEN}  ✓ Listener [${listener}] zatrzymany${NC}"
    else
        log_message "${RED}  ✗ Proces tnslsnr ${listener} nadal działa!${NC}"
        pgrep -a -f "tnslsnr ${listener}" >> "${LOG_FILE}" 2>&1
    fi

    # Zatrzymaj bazę (POTEM - gdy listener już nie przyjmuje połączeń)
    log_message "${YELLOW}  Zatrzymuję bazę (SID: ${sid})...${NC}"
    su - "${ORACLE_USER}" -c "
        export ORACLE_HOME=${oracle_home}
        export ORACLE_SID=${sid}
        export PATH=\${ORACLE_HOME}/bin:\${PATH}
        ${oracle_home}/bin/sqlplus -s / as sysdba << 'SQL'
SHUTDOWN IMMEDIATE;
EXIT;
SQL
    " >> "${LOG_FILE}" 2>&1

    if [ $? -eq 0 ]; then
        log_message "${GREEN}  ✓ SHUTDOWN IMMEDIATE zakończony [${sid}]${NC}"
    else
        log_message "${RED}  ✗ SHUTDOWN IMMEDIATE błąd [${sid}]${NC}"
    fi

    sleep 5

    if ! pgrep -f "ora_pmon_${sid}" > /dev/null 2>&1; then
        log_message "${GREEN}  ✓ Baza [${sid}] zatrzymana${NC}"
    else
        log_message "${RED}  ✗ Proces ora_pmon_${sid} nadal działa!${NC}"
        pgrep -a -f "ora_.*_${sid}" >> "${LOG_FILE}" 2>&1
    fi
}

# Zatrzymuje wszystkie instancje Oracle
stop_all_oracle_instances() {
    local instance_count=${#ORACLE_INSTANCES[@]}

    if [ ${instance_count} -eq 0 ]; then
        log_message "${YELLOW}Brak instancji Oracle - pomijam${NC}"
        return 0
    fi

    log_message "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log_message "${YELLOW}Zatrzymuję instancje Oracle (${instance_count})${NC}"
    log_message "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if ! id "${ORACLE_USER}" &>/dev/null; then
        log_message "${RED}BŁĄD: Użytkownik ${ORACLE_USER} nie istnieje${NC}"
        return 1
    fi

    local instance_num=0
    for entry in "${ORACLE_INSTANCES[@]}"; do
        instance_num=$((instance_num + 1))
        IFS=':' read -r sid listener oracle_home <<< "${entry}"

        if [ -z "${sid}" ] || [ -z "${listener}" ] || [ -z "${oracle_home}" ]; then
            log_message "${RED}BŁĄD: Niepoprawny wpis #${instance_num}: '${entry}'${NC}"
            continue
        fi

        log_message "${YELLOW}[Oracle ${instance_num}/${instance_count}] ${sid}${NC}"
        stop_oracle_instance "${sid}" "${listener}" "${oracle_home}"
    done

    log_message "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Zatrzymuje usługi i aplikacje
stop_services() {
    log_message "${YELLOW}Zatrzymuję usługi i aplikacje (custom apps → systemd → oracle)...${NC}"

    # 1. Custom apps (PIERWSZEŃSTWO)
    if [ ${#CUSTOM_APPS[@]} -gt 0 ]; then
        log_message "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log_message "${YELLOW}[1/3] Zatrzymuję aplikacje niestandardowe (${#CUSTOM_APPS[@]})${NC}"
        log_message "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        for app_entry in "${CUSTOM_APPS[@]}"; do
            # Rozdziel na 3 części: ścieżka:użytkownik:argumenty
            IFS=':' read -r app_path app_user app_args <<< "${app_entry}"

            if [ -z "${app_path}" ] || [ -z "${app_user}" ]; then
                log_message "${RED}Błąd: Niepoprawny wpis aplikacji: '${app_entry}'${NC}"
                log_message "${RED}Format: 'ścieżka:użytkownik:argumenty'${NC}"
                continue
            fi

            # Argumenty opcjonalne, domyślnie puste
            app_args="${app_args:-}"

            log_message "${YELLOW}Zatrzymuję ${app_path} ${app_args} (użytkownik: ${app_user})...${NC}"

            if [ ! -x "${app_path}" ]; then
                log_message "${YELLOW}${app_path} nie istnieje lub nie jest wykonywalny${NC}"
                continue
            fi

            if [ "${app_user}" == "root" ]; then
                ${app_path} ${app_args} >> "${LOG_FILE}" 2>&1
            else
                if ! id "${app_user}" &>/dev/null; then
                    log_message "${RED}Użytkownik ${app_user} nie istnieje${NC}"
                    continue
                fi
                # Użyj sudo -u zamiast su - (zachowuje kontekst root z sudo)
                sudo -u "${app_user}" ${app_path} ${app_args} >> "${LOG_FILE}" 2>&1
            fi

            if [ $? -eq 0 ]; then
                log_message "${GREEN}✓ ${app_path} zatrzymany${NC}"
            else
                log_message "${RED}✗ Błąd zatrzymania ${app_path}${NC}"
            fi
        done
    else
        log_message "${YELLOW}[1/3] Brak aplikacji niestandardowych - pomijam${NC}"
    fi

    # 2. Systemd services
    if [ ${#SYSTEMD_SERVICES[@]} -gt 0 ]; then
        log_message "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log_message "${YELLOW}[2/3] Zatrzymuję usługi systemd (${#SYSTEMD_SERVICES[@]})${NC}"
        log_message "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        for service in "${SYSTEMD_SERVICES[@]}"; do
            if systemctl list-unit-files | grep -q "^${service}.service"; then
                systemctl stop "${service}" >> "${LOG_FILE}" 2>&1
                if [ $? -eq 0 ]; then
                    log_message "${GREEN}✓ Usługa ${service} zatrzymana${NC}"
                else
                    log_message "${RED}✗ Błąd zatrzymania ${service}${NC}"
                fi
            else
                log_message "${YELLOW}Usługa ${service} nie istnieje${NC}"
            fi
        done
    else
        log_message "${YELLOW}[2/3] Brak usług systemd - pomijam${NC}"
    fi

    # 3. Oracle instances (OSTATNIE)
    log_message "${YELLOW}[3/3] Zatrzymuję instancje Oracle${NC}"
    stop_all_oracle_instances
}


# ════════════════════════════════════════════════════════════
# GŁÓWNA LOGIKA
# ════════════════════════════════════════════════════════════

# Zbuduj exclude arg
EXCLUDE_ARG=$(build_exclude_arg)

# Zbuduj enablerepo arg
ENABLEREPO_ARG=$(build_enablerepo_arg "${ENABLE_REPOS:-}")

# [1/5] Sprawdzenie miejsca
log_message "${YELLOW}[1/5] Sprawdzam miejsce na dysku...${NC}"

# Sprawdź root (/) - jedno sprawdzenie, bez drugiej szansy
ROOT_AVAILABLE=$(df / | tail -1 | awk '{print $4}')
ROOT_MIN_KB=$((ROOT_MIN_GB * 1024 * 1024))

if [ "${ROOT_AVAILABLE}" -lt "${ROOT_MIN_KB}" ]; then
    ROOT_AVAILABLE_MB=$((ROOT_AVAILABLE / 1024))
    log_message "${RED}BŁĄD: Zbyt mało miejsca na / (${ROOT_AVAILABLE_MB}MB, wymagane: ${ROOT_MIN_GB}GB)${NC}"
    mark_failure
    exit_with_full_log
fi

# Sprawdź /var - z drugą szansą (dnf clean)
VAR_AVAILABLE=$(df /var | tail -1 | awk '{print $4}')
VAR_MIN_KB=$((VAR_MIN_GB * 1024 * 1024))

if [ "${VAR_AVAILABLE}" -lt "${VAR_MIN_KB}" ]; then
    VAR_AVAILABLE_MB=$((VAR_AVAILABLE / 1024))
    log_message "${YELLOW}⚠ Za mało miejsca na /var (${VAR_AVAILABLE_MB}MB, wymagane: ${VAR_MIN_GB}GB)${NC}"
    log_message "${YELLOW}Czyszczę cache DNF...${NC}"
    
    # Próba czyszczenia cache
    if dnf clean all --enablerepo=* >> "${LOG_FILE}" 2>&1; then
        log_message "${GREEN}✓ Cache DNF wyczyszczony${NC}"
        
        # Sprawdź ponownie po czyszczeniu
        VAR_AVAILABLE=$(df /var | tail -1 | awk '{print $4}')
        
        if [ "${VAR_AVAILABLE}" -lt "${VAR_MIN_KB}" ]; then
            VAR_AVAILABLE_MB=$((VAR_AVAILABLE / 1024))
            log_message "${RED}BŁĄD: Nadal za mało miejsca na /var po czyszczeniu cache (${VAR_AVAILABLE_MB}MB, wymagane: ${VAR_MIN_GB}GB)${NC}"
            mark_failure
            exit_with_full_log
        else
            log_message "${GREEN}✓ Po czyszczeniu cache: wystarczająco miejsca na /var${NC}"
        fi
    else
        log_message "${RED}BŁĄD: Nie udało się wyczyścić cache DNF${NC}"
        mark_failure
        exit_with_full_log
    fi
fi

ROOT_AVAILABLE_GB=$(echo "scale=2; ${ROOT_AVAILABLE}/1024/1024" | bc)
VAR_AVAILABLE_GB=$(echo "scale=2; ${VAR_AVAILABLE}/1024/1024" | bc)
log_message "${GREEN}✓ Miejsce: / = ${ROOT_AVAILABLE_GB}GB, /var = ${VAR_AVAILABLE_GB}GB${NC}"

# [2/5] Sprawdzenie blokady DNF (z oczekiwaniem)
log_message "${YELLOW}[2/5] Sprawdzam blokadę DNF...${NC}"

DNF_LOCK_WAIT=0
DNF_LOCK_TIMEOUT=300  # max 5 minut oczekiwania

while true; do
    DNF_LOCKED=false

    # Sprawdź /var/run/dnf.pid
    if [ -f /var/run/dnf.pid ]; then
        DNF_PID=$(cat /var/run/dnf.pid 2>/dev/null)
        if ps -p "${DNF_PID}" > /dev/null 2>&1; then
            DNF_LOCKED=true
        else
            log_message "${YELLOW}Stary lock /var/run/dnf.pid (PID ${DNF_PID} nieaktywny), usuwam...${NC}"
            rm -f /var/run/dnf.pid
        fi
    fi

    # Sprawdź locki RPM/DNF w /var/cache i /run
    if [ "$DNF_LOCKED" == "false" ]; then
        for lockfile in /run/dnf.pid /var/cache/dnf/*.lock /run/rpm/lock; do
            if [ -f "$lockfile" ]; then
                LOCK_PID=$(cat "$lockfile" 2>/dev/null)
                if [ -n "$LOCK_PID" ] && ps -p "${LOCK_PID}" > /dev/null 2>&1; then
                    DNF_LOCKED=true
                    DNF_PID="$LOCK_PID"
                    break
                fi
            fi
        done
    fi

    if [ "$DNF_LOCKED" == "false" ]; then
        break
    fi

    # Blokada aktywna - czekaj lub przerwij po timeout
    if [ ${DNF_LOCK_WAIT} -ge ${DNF_LOCK_TIMEOUT} ]; then
        log_message "${RED}BŁĄD: DNF zablokowany przez ponad ${DNF_LOCK_TIMEOUT}s (PID: ${DNF_PID}) - przerywam${NC}"
        mark_failure
        exit_with_full_log
    fi

    if [ ${DNF_LOCK_WAIT} -eq 0 ]; then
        log_message "${YELLOW}DNF zajęty (PID: ${DNF_PID}), czekam (max ${DNF_LOCK_TIMEOUT}s)...${NC}"
    elif [ $((DNF_LOCK_WAIT % 30)) -eq 0 ]; then
        log_message "${YELLOW}Nadal czekam na DNF (PID: ${DNF_PID}), minęło: ${DNF_LOCK_WAIT}s...${NC}"
    fi

    sleep 5
    DNF_LOCK_WAIT=$((DNF_LOCK_WAIT + 5))
done

log_message "${GREEN}✓ DNF nie jest zablokowany${NC}"

# [3/5] Check-update
log_message "${YELLOW}[3/5] Sprawdzam dostępne aktualizacje...${NC}"
log_skipped_packages

> "${DNF_OUTPUT}"
> "${DNF_ERROR}"

# Wyświetl opcje DNF jeśli są
if [ -n "${EXCLUDE_ARG}" ] || [ -n "${ENABLEREPO_ARG}" ]; then
    log_message "${YELLOW}DNF opcje:${NC}"
    [ -n "${EXCLUDE_ARG}" ] && log_message "${YELLOW}  --exclude=${EXCLUDE_ARG}${NC}"
    [ -n "${ENABLEREPO_ARG}" ] && log_message "${YELLOW}  ${ENABLEREPO_ARG}${NC}"
fi

# Wywołaj dnf check-update z odpowiednimi parametrami
if [ -n "${EXCLUDE_ARG}" ] || [ -n "${ENABLEREPO_ARG}" ]; then
    dnf check-update ${ENABLEREPO_ARG} --exclude="${EXCLUDE_ARG}" > "${DNF_OUTPUT}" 2> "${DNF_ERROR}"
else
    dnf check-update > "${DNF_OUTPUT}" 2> "${DNF_ERROR}"
fi
CHECK_UPDATE_EXIT=$?

cat "${DNF_OUTPUT}" >> "${LOG_FILE}"
cat "${DNF_ERROR}" >> "${LOG_FILE}"

if [ ${CHECK_UPDATE_EXIT} -eq 0 ]; then
    log_message "${GREEN}✓ Brak pakietów do aktualizacji${NC}"
    log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    log_message "${GREEN}  AKTUALIZACJA NIE BYŁA WYMAGANA${NC}"
    log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    rm -f "${DNF_OUTPUT}" "${DNF_ERROR}"
    
    # Dry-run sukces - nie logujemy (ale aktualizujemy status)
    if [ "${DRY_RUN}" == "true" ]; then
        update_status_file "DRY_RUN_SUCCESS" "0" "0" "false"
        rm -f "${LOG_FILE}"
        exit 0
    fi
    
    # Przemianuj log (normalna aktualizacja - brak pakietów)
    update_status_file "SUCCESS" "0" "0" "false"
    FINAL_LOG="${LOG_DIR}/${TIMESTAMP}.log"
    mv "${LOG_FILE}" "${FINAL_LOG}"
    ln -sf "$(basename ${FINAL_LOG})" "${LOG_DIR}/latest.log"
    exit 0

elif [ ${CHECK_UPDATE_EXIT} -eq 100 ]; then
    log_message "${GREEN}✓ Znaleziono aktualizacje${NC}"

    # [4/5] Analiza pakietów
    log_message "${YELLOW}[4/5] Analizuję pakiety...${NC}"

    CRITICAL_FOUND=0
    NONCRITICAL_FOUND=0

    while IFS= read -r package_name; do
        if is_critical_package "$package_name"; then
            CRITICAL_FOUND=$((CRITICAL_FOUND + 1))
        else
            NONCRITICAL_FOUND=$((NONCRITICAL_FOUND + 1))
        fi
    done < <(parse_dnf_packages "${DNF_OUTPUT}")

    TOTAL_PACKAGES=$((CRITICAL_FOUND + NONCRITICAL_FOUND))
    log_message "${YELLOW}Pakietów łącznie: ${TOTAL_PACKAGES}${NC}"
    log_message "${GREEN}Niekrytyczne: ${NONCRITICAL_FOUND}${NC}"
    log_message "${YELLOW}Krytyczne: ${CRITICAL_FOUND}${NC}"

    # DRY-RUN: zakończ tutaj
    if [ "${DRY_RUN}" == "true" ]; then
        log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        log_message "${GREEN}  DRY-RUN ZAKOŃCZONY POMYŚLNIE${NC}"
        log_message "${GREEN}  Pakietów do aktualizacji: ${TOTAL_PACKAGES}${NC}"
        log_message "${GREEN}  Krytycznych: ${CRITICAL_FOUND}${NC}"
        
        # Informacja czy restart byłby wykonany
        would_reboot=false
        case "${AUTO_REBOOT_AFTER_UPDATE:-never}" in
            "always")
                [ ${TOTAL_PACKAGES} -gt 0 ] && would_reboot=true
                ;;
            "critical")
                [ ${CRITICAL_FOUND} -gt 0 ] && would_reboot=true
                ;;
        esac
        
        if [ "$would_reboot" == "true" ]; then
            log_message "${YELLOW}  ! Restart byłby wykonany (AUTO_REBOOT_AFTER_UPDATE=${AUTO_REBOOT_AFTER_UPDATE})${NC}"
        else
            log_message "${GREEN}  Restart nie byłby wykonany${NC}"
        fi
        
        log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        
        # Aktualizuj status.json (dry-run sukces)
        update_status_file "DRY_RUN_SUCCESS" "${TOTAL_PACKAGES}" "${CRITICAL_FOUND}" "false"
        
        rm -f "${DNF_OUTPUT}" "${DNF_ERROR}"
        # Dry-run sukces - nie logujemy
        rm -f "${LOG_FILE}"
        exit 0
    fi

else
    # Błąd check-update
    log_message "${RED}✗ Błąd check-update (kod: ${CHECK_UPDATE_EXIT})${NC}"
    analyze_dnf_error "${CHECK_UPDATE_EXIT}" "${DNF_ERROR}"
    mark_failure
    
    # Aktualizuj status.json (FAIL - check-update)
    update_status_file "FAIL" "0" "0" "false" "" "Błąd check-update (kod: ${CHECK_UPDATE_EXIT})"
    
    rm -f "${DNF_OUTPUT}" "${DNF_ERROR}"
    
    # Przemianuj log
    FINAL_LOG="${LOG_DIR}/FAIL_${TIMESTAMP}.log"
    mv "${LOG_FILE}" "${FINAL_LOG}"
    ln -sf "$(basename ${FINAL_LOG})" "${LOG_DIR}/latest.log"
    exit_with_full_log
fi

# [5/5] DNF update
log_message "${YELLOW}[5/5] Wykonuję dnf update...${NC}"

> "${DNF_OUTPUT}"
> "${DNF_ERROR}"

if [ -n "${EXCLUDE_ARG}" ] || [ -n "${ENABLEREPO_ARG}" ]; then
    dnf update -y ${ENABLEREPO_ARG} --exclude="${EXCLUDE_ARG}" > "${DNF_OUTPUT}" 2> "${DNF_ERROR}"
else
    dnf update -y > "${DNF_OUTPUT}" 2> "${DNF_ERROR}"
fi
DNF_EXIT_CODE=$?

cat "${DNF_OUTPUT}" >> "${LOG_FILE}"
cat "${DNF_ERROR}" >> "${LOG_FILE}"

# ────────────────────────────────────────────────────────
# DWUSTOPNIOWA WERYFIKACJA WYNIKU DNF
# ────────────────────────────────────────────────────────
# Krok 1: exit code
# Krok 2: analiza output - szukamy "Complete!" (sukces) lub
#         "Transaction check error" / "Error: Transaction failed" (faktyczny błąd)
# Cel: odróżnienie rzeczywistego błędu od ostrzeżeń RPM które
#      nie wpłynęły na wynik transakcji (np. "rpm exception: package not installed")

DNF_COMPLETE=false
DNF_TRANSACTION_ERROR=false

if grep -q "^Complete!$" "${DNF_OUTPUT}" 2>/dev/null; then
    DNF_COMPLETE=true
fi

if grep -qiE "^Transaction check error:|^Error: Transaction failed|^Error: Could not run transaction" "${DNF_OUTPUT}" 2>/dev/null; then
    DNF_TRANSACTION_ERROR=true
fi

# Ostrzeżenia RPM które NIE są błędami transakcji
if [ ${DNF_EXIT_CODE} -ne 0 ] && [ "${DNF_COMPLETE}" == "true" ]; then
    log_message "${YELLOW}⚠ DNF zakończył z kodem ${DNF_EXIT_CODE}, ale transakcja była kompletna (Complete!)${NC}"
    log_message "${YELLOW}  Sprawdzam szczegóły ostrzeżeń...${NC}"

    # Rozpoznaj znane nieszkodliwe ostrzeżenia
    if grep -qi "rpm exception occurred: package not installed" "${DNF_ERROR}" 2>/dev/null || \
       grep -qi "rpm exception occurred: package not installed" "${DNF_OUTPUT}" 2>/dev/null; then
        log_message "${YELLOW}  Ostrzeżenie: 'rpm exception: package not installed' - znany artefakt RPM, ignoruję${NC}"
    fi

    log_message "${GREEN}✓ Aktualizacja DNF zakończona pomyślnie! (z ostrzeżeniami RPM)${NC}"
    DNF_EXIT_CODE=0  # traktuj jako sukces

elif [ ${DNF_EXIT_CODE} -ne 0 ] && [ "${DNF_TRANSACTION_ERROR}" == "true" ]; then
    log_message "${RED}✗ Transakcja DNF przerwana (Transaction error)${NC}"
    # pozostaje FAIL - obsługa poniżej w bloku else

elif [ ${DNF_EXIT_CODE} -ne 0 ] && [ "${DNF_COMPLETE}" == "false" ]; then
    log_message "${RED}✗ Aktualizacja DNF nie powiodła się (brak 'Complete!' w output)${NC}"
    # pozostaje FAIL - obsługa poniżej w bloku else
fi

if [ ${DNF_EXIT_CODE} -eq 0 ]; then
    log_message "${GREEN}✓ Aktualizacja DNF zakończona pomyślnie!${NC}"

    # ────────────────────────────────────────────────────────
    # DECYZJA O RESTARCIE
    # ────────────────────────────────────────────────────────
    
    SHOULD_REBOOT=false
    REBOOT_REASON=""
    
    # Sprawdź warunki restartu
    case "${AUTO_REBOOT_AFTER_UPDATE:-never}" in
        "always")
            if [ ${TOTAL_PACKAGES} -gt 0 ]; then
                SHOULD_REBOOT=true
                REBOOT_REASON="Tryb AUTO_REBOOT_AFTER_UPDATE=always (zaktualizowano ${TOTAL_PACKAGES} pakietów)"
            fi
            ;;
        "critical")
            if [ ${CRITICAL_FOUND} -gt 0 ]; then
                SHOULD_REBOOT=true
                REBOOT_REASON="Aktualizacja pakietów krytycznych (${CRITICAL_FOUND} pakietów)"
            fi
            ;;
        "never")
            SHOULD_REBOOT=false
            ;;
        *)
            log_message "${YELLOW}Ostrzeżenie: Nieznana wartość AUTO_REBOOT_AFTER_UPDATE='${AUTO_REBOOT_AFTER_UPDATE}' - restart wyłączony${NC}"
            SHOULD_REBOOT=false
            ;;
    esac
    
    # ────────────────────────────────────────────────────────
    # ZATRZYMANIE USŁUG (zgodnie z STOP_SERVICES_MODE)
    # ────────────────────────────────────────────────────────
    
    # Domyślna wartość jeśli nie ustawiono w config
    STOP_SERVICES_MODE="${STOP_SERVICES_MODE:-auto}"
    
    SHOULD_STOP_SERVICES=false
    
    case "${STOP_SERVICES_MODE}" in
        "auto")
            # Zatrzymuj TYLKO gdy restart będzie wykonany
            if [ "$SHOULD_REBOOT" == "true" ] && [ ${CRITICAL_FOUND} -gt 0 ]; then
                SHOULD_STOP_SERVICES=true
                log_message "${YELLOW}STOP_SERVICES_MODE=auto: zatrzymuję usługi (restart zaplanowany)${NC}"
            else
                log_message "${GREEN}STOP_SERVICES_MODE=auto: usługi pozostają uruchomione (brak restartu)${NC}"
            fi
            ;;
        "always")
            # Zatrzymuj ZAWSZE przy critical packages
            if [ ${CRITICAL_FOUND} -gt 0 ]; then
                SHOULD_STOP_SERVICES=true
                log_message "${YELLOW}STOP_SERVICES_MODE=always: zatrzymuję usługi (critical packages)${NC}"
            else
                log_message "${GREEN}STOP_SERVICES_MODE=always: usługi pozostają uruchomione (brak critical packages)${NC}"
            fi
            ;;
        "never")
            # NIGDY nie zatrzymuj
            SHOULD_STOP_SERVICES=false
            log_message "${GREEN}STOP_SERVICES_MODE=never: usługi pozostają uruchomione (zero downtime)${NC}"
            ;;
        *)
            # Nieznana wartość - zachowaj się jak "auto"
            log_message "${YELLOW}Ostrzeżenie: Nieznana wartość STOP_SERVICES_MODE='${STOP_SERVICES_MODE}' - używam trybu 'auto'${NC}"
            if [ "$SHOULD_REBOOT" == "true" ] && [ ${CRITICAL_FOUND} -gt 0 ]; then
                SHOULD_STOP_SERVICES=true
            fi
            ;;
    esac
    
    if [ "$SHOULD_STOP_SERVICES" == "true" ]; then
        stop_services
        log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        log_message "${GREEN}  AKTUALIZACJA KRYTYCZNA ZAKOŃCZONA${NC}"
        log_message "${GREEN}  Usługi zatrzymane (STOP_SERVICES_MODE=${STOP_SERVICES_MODE})${NC}"
        log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    else
        log_message "${GREEN}✓ Usługi pozostały uruchomione${NC}"
        if [ ${CRITICAL_FOUND} -gt 0 ]; then
            log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
            log_message "${GREEN}  AKTUALIZACJA KRYTYCZNA ZAKOŃCZONA${NC}"
            log_message "${GREEN}  Usługi NIE zatrzymane (STOP_SERVICES_MODE=${STOP_SERVICES_MODE})${NC}"
            log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        else
            log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
            log_message "${GREEN}  AKTUALIZACJA NIEKRYTYCZNA ZAKOŃCZONA${NC}"
            log_message "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        fi
    fi
    
    # ────────────────────────────────────────────────────────
    # WYKONANIE RESTARTU (jeśli wymagany)
    # ────────────────────────────────────────────────────────
    
    if [ "$SHOULD_REBOOT" == "true" ]; then
        log_message "${YELLOW}════════════════════════════════════════════════════════════${NC}"
        log_message "${YELLOW}  RESTART SERWERA ZAPLANOWANY${NC}"
        log_message "${YELLOW}════════════════════════════════════════════════════════════${NC}"
        log_message "${YELLOW}Restart serwera za ${REBOOT_DELAY_MINUTES:-1} minut(y)...${NC}"
        log_message "${YELLOW}Powód: ${REBOOT_REASON}${NC}"
        log_message "${YELLOW}════════════════════════════════════════════════════════════${NC}"
        
        # Aktualizuj status.json
        update_status_file "SUCCESS" "${TOTAL_PACKAGES}" "${CRITICAL_FOUND}" "true" "${REBOOT_REASON}"
        
        # Przemianuj log (sukces z restartem)
        FINAL_LOG="${LOG_DIR}/${TIMESTAMP}.log"
        mv "${LOG_FILE}" "${FINAL_LOG}"
        ln -sf "$(basename ${FINAL_LOG})" "${LOG_DIR}/latest.log"
        
        # Zaplanuj restart
        shutdown -r +${REBOOT_DELAY_MINUTES:-1} "RHEL update: ${REBOOT_REASON} (${TIMESTAMP})" &
        
        rm -f "${DNF_OUTPUT}" "${DNF_ERROR}"
        exit 0
    fi
    
    # Brak restartu - normalny koniec
    
    # Aktualizuj status.json
    update_status_file "SUCCESS" "${TOTAL_PACKAGES}" "${CRITICAL_FOUND}" "false"
    
    rm -f "${DNF_OUTPUT}" "${DNF_ERROR}"
    
    FINAL_LOG="${LOG_DIR}/${TIMESTAMP}.log"
    mv "${LOG_FILE}" "${FINAL_LOG}"
    ln -sf "$(basename ${FINAL_LOG})" "${LOG_DIR}/latest.log"
    exit 0

else
    log_message "${RED}✗ Aktualizacja DNF nie powiodła się${NC}"
    analyze_dnf_error "${DNF_EXIT_CODE}" "${DNF_ERROR}"
    mark_failure
    
    log_message "${RED}Usługi nie zostały zatrzymane ze względu na błąd${NC}"
    
    # Aktualizuj status.json (FAIL)
    update_status_file "FAIL" "0" "0" "false" "" "Aktualizacja DNF nie powiodła się (kod: ${DNF_EXIT_CODE})"
    
    rm -f "${DNF_OUTPUT}" "${DNF_ERROR}"
    
    # Przemianuj log (fail)
    FINAL_LOG="${LOG_DIR}/FAIL_${TIMESTAMP}.log"
    mv "${LOG_FILE}" "${FINAL_LOG}"
    ln -sf "$(basename ${FINAL_LOG})" "${LOG_DIR}/latest.log"
    
    exit_with_full_log
fi

