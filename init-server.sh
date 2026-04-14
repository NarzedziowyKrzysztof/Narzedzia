#!/bin/bash

# ═══════════════════════════════════════════════════════════
# RHEL UPDATE ORCHESTRATOR
# ═══════════════════════════════════════════════════════════
# Skrypt:          init-server.sh
# Wersja projektu: 11.14
# Ostatnia zmiana: 2026-03-21
# Autor:           Krzysztof Boroń
# Opis:            Inicjalizacja i przygotowanie serwerów zdalnych
# ═══════════════════════════════════════════════════════════
# Ten skrypt przygotowuje serwery zdalne do pracy z orchestratorem.
# Tworzy strukturę katalogów, konfiguruje sudo, weryfikuje dostęp.
#
# Użycie:
#   ./init-server.sh [--config FILE] server1 server2 ...
#   ./init-server.sh [--config FILE] --all
#
# Wymaga:
#   - SSH z kluczami (bez hasła)
#   - Dostęp sudo na serwerach zdalnych
# ═══════════════════════════════════════════════════════════

readonly PROJECT_VERSION="11.14"
readonly SCRIPT_NAME="init-server.sh"
readonly LAST_CHANGE="2026-04-02"
readonly AUTHOR="Krzysztof Boroń"

set -o pipefail

# Kolory
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ════════════════════════════════════════════════════════════
# KONFIGURACJA
# ════════════════════════════════════════════════════════════

# Domyślna lokalizacja głównego pliku config
DEFAULT_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orchestrator.conf"
CONFIG_FILE="${DEFAULT_CONFIG}"

# Tablica serwerów do inicjalizacji
SERVERS=()

# Flaga --all
INIT_ALL=false

# Statystyki
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ════════════════════════════════════════════════════════════
# PARSOWANIE ARGUMENTÓW
# ════════════════════════════════════════════════════════════

# Jeśli brak argumentów, pokaż help
if [ $# -eq 0 ]; then
    cat << 'EOF'
════════════════════════════════════════════════════════════
  INIT-SERVER - Inicjalizacja serwerów zdalnych
════════════════════════════════════════════════════════════

UŻYCIE:
  ./init-server.sh [OPCJE] SERWER1 [SERWER2 ...]

OPCJE:
  --config FILE   Użyj niestandardowej konfiguracji
                  (domyślnie: ./orchestrator.conf)
  --all           Inicjalizuj wszystkie serwery z servers.txt
  --help, -h      Pokaż tę pomoc

PRZYKŁADY:
  # Inicjalizuj jeden serwer
  ./init-server.sh server1.prod.local

  # Inicjalizuj kilka serwerów
  ./init-server.sh server1.prod.local server2.prod.local

  # Inicjalizuj wszystkie z servers.txt
  ./init-server.sh --all

  # Użyj niestandardowej konfiguracji
  ./init-server.sh --config /custom/config.conf server1

CO ROBI SKRYPT:
  1. Tworzy katalog bazowy na serwerze zdalnym
  2. Tworzy podkatalogi: config/, scripts/, logs/
  3. Ustawia uprawnienia dla użytkownika SSH
  4. Tworzy wpis w /etc/sudoers.d/
  5. Weryfikuje poprawność instalacji

WYMAGA:
  - Klucze SSH skonfigurowane (bez hasła)
  - Dostęp sudo na serwerach zdalnych

════════════════════════════════════════════════════════════
EOF
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --all)
            INIT_ALL=true
            shift
            ;;
        --help|-h)
            cat << 'EOF'
════════════════════════════════════════════════════════════
  INIT-SERVER - Inicjalizacja serwerów zdalnych
════════════════════════════════════════════════════════════

UŻYCIE:
  ./init-server.sh [OPCJE] SERWER1 [SERWER2 ...]

OPCJE:
  --config FILE   Użyj niestandardowej konfiguracji
                  (domyślnie: ./orchestrator.conf)
  --all           Inicjalizuj wszystkie serwery z servers.txt
  --help, -h      Pokaż tę pomoc

PRZYKŁADY:
  # Inicjalizuj jeden serwer
  ./init-server.sh server1.prod.local

  # Inicjalizuj kilka serwerów
  ./init-server.sh server1.prod.local server2.prod.local

  # Inicjalizuj wszystkie z servers.txt
  ./init-server.sh --all

  # Użyj niestandardowej konfiguracji
  ./init-server.sh --config /custom/config.conf server1

CO ROBI SKRYPT:
  1. Tworzy katalog bazowy na serwerze zdalnym
  2. Tworzy podkatalogi: config/, scripts/, logs/
  3. Ustawia uprawnienia dla użytkownika SSH
  4. Tworzy wpis w /etc/sudoers.d/
  5. Weryfikuje poprawność instalacji

WYMAGA:
  - Klucze SSH skonfigurowane (bez hasła)
  - Dostęp sudo na serwerach zdalnych

════════════════════════════════════════════════════════════
EOF
            exit 0
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
    echo "Create it or use --config to specify a different file."
    exit 1
fi

source "$CONFIG_FILE"

# Weryfikacja wymaganych zmiennych
if [ -z "$REMOTE_BASE_DIR" ]; then
    echo -e "${RED}ERROR: REMOTE_BASE_DIR not defined in config${NC}"
    exit 1
fi

if [ -z "$SUDOERS_FILE" ]; then
    echo -e "${RED}ERROR: SUDOERS_FILE not defined in config${NC}"
    exit 1
fi

# ════════════════════════════════════════════════════════════
# OKREŚLENIE LISTY SERWERÓW
# ════════════════════════════════════════════════════════════

if [ "$INIT_ALL" == "true" ]; then
    SERVERS_FILE="${CONTROL_BASE_DIR}/servers.txt"
    
    if [ ! -f "$SERVERS_FILE" ]; then
        echo -e "${RED}ERROR: servers.txt not found: $SERVERS_FILE${NC}"
        exit 1
    fi
    
    # Wczytaj serwery z pliku (pomijając komentarze i puste linie)
    while IFS= read -r line; do
        # Usuń spacje z początku i końca
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Pomiń komentarze i puste linie
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        SERVERS+=("$line")
    done < "$SERVERS_FILE"
fi

if [ ${#SERVERS[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No servers specified${NC}"
    echo "Use: $0 server1 server2 ... or $0 --all"
    echo "Run: $0 --help for more info"
    exit 1
fi

# ════════════════════════════════════════════════════════════
# FUNKCJE POMOCNICZE
# ════════════════════════════════════════════════════════════

# Sprawdza czy serwer jest osiągalny przez SSH
check_ssh_connectivity() {
    local server="$1"
    local ssh_user="$2"
    local ssh_port="${3:-22}"
    
    ssh -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -p "${ssh_port}" \
        "${ssh_user}@${server}" \
        "echo ok" &>/dev/null
    
    return $?
}

# Inicjalizuje jeden serwer
init_single_server() {
    local server="$1"
    local config_file="${CONTROL_BASE_DIR}/config/${server}.conf"
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Serwer: ${server}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Wczytaj konfigurację serwera (config jest już sprawdzony w pętli głównej)
    source "$config_file"
    
    # Użyj wartości z config serwera lub domyślnych
    SSH_USER="${SSH_USER:-$DEFAULT_SSH_USER}"
    SSH_PORT="${SSH_PORT:-$DEFAULT_SSH_PORT}"
    
    echo -e "  SSH: ${SSH_USER}@${server}:${SSH_PORT}"
    echo -e "  Remote dir: ${REMOTE_BASE_DIR}"
    echo ""
    
    # Sprawdź połączenie SSH
    echo -n "  [1/7] Sprawdzam połączenie SSH... "
    if ! check_ssh_connectivity "$server" "$SSH_USER" "$SSH_PORT"; then
        echo -e "${RED}FAIL${NC}"
        echo -e "${RED}  ✗ Nie można połączyć się przez SSH${NC}"
        echo -e "${RED}  ✗ Sprawdź: klucze SSH, sieć, firewall${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Sprawdź czy użytkownik ma sudo bez hasła (KRYTYCZNE!)
    echo -n "  [2/7] Sprawdzam uprawnienia sudo... "
    SUDO_CHECK=$(ssh -o StrictHostKeyChecking=no \
                     -o UserKnownHostsFile=/dev/null \
                     -o LogLevel=ERROR \
                     -p "${SSH_PORT}" \
                     "${SSH_USER}@${server}" \
                     "sudo -n true 2>&1 && echo OK || echo FAIL")
    
    if [ "$SUDO_CHECK" != "OK" ]; then
        echo -e "${RED}FAIL${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}  ✗ Użytkownik ${SSH_USER} nie ma sudo bez hasła!${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  AKCJA WYMAGANA na serwerze ${server}:${NC}"
        echo ""
        echo -e "${YELLOW}  1. Zaloguj się jako root:${NC}"
        echo -e "     ${CYAN}ssh ${server}${NC}"
        echo -e "     ${CYAN}su -${NC}"
        echo ""
        echo -e "${YELLOW}  2. Edytuj sudoers:${NC}"
        echo -e "     ${CYAN}visudo${NC}"
        echo ""
        echo -e "${YELLOW}  3. Dodaj na końcu pliku:${NC}"
        echo -e "     ${CYAN}${SSH_USER} ALL=(ALL) NOPASSWD: ALL${NC}"
        echo ""
        echo -e "${YELLOW}  4. Zapisz i wyjdź${NC}"
        echo ""
        echo -e "${YELLOW}  5. Sprawdź (jako ${SSH_USER}):${NC}"
        echo -e "     ${CYAN}sudo -n true && echo OK${NC}"
        echo ""
        echo -e "${YELLOW}  6. Uruchom ponownie:${NC}"
        echo -e "     ${CYAN}./init-server.sh ${server}${NC}"
        echo ""
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Sprawdź czy katalog już istnieje
    echo -n "  [3/7] Sprawdzam czy katalog istnieje... "
    DIR_EXISTS=$(ssh -o StrictHostKeyChecking=no \
                     -o UserKnownHostsFile=/dev/null \
                     -o LogLevel=ERROR \
                     -p "${SSH_PORT}" \
                     "${SSH_USER}@${server}" \
                     "[ -d '${REMOTE_BASE_DIR}' ] && echo yes || echo no" 2>/dev/null)
    
    if [ "$DIR_EXISTS" == "yes" ]; then
        echo -e "${YELLOW}EXISTS${NC}"
        echo -e "${YELLOW}  ! Katalog już istnieje - aktualizuję konfigurację${NC}"
        SKIP_COUNT=$((SKIP_COUNT + 1))
    else
        echo -e "${GREEN}OK${NC}"
    fi
    
    # Utwórz strukturę katalogów
    echo -n "  [4/7] Tworzę strukturę katalogów... "
    CREATE_RESULT=$(ssh -o StrictHostKeyChecking=no \
                        -o UserKnownHostsFile=/dev/null \
                        -o LogLevel=ERROR \
                        -p "${SSH_PORT}" \
                        "${SSH_USER}@${server}" \
                        "sudo mkdir -p '${REMOTE_BASE_DIR}'/{config,scripts,logs} 2>&1")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}FAIL${NC}"
        echo -e "${RED}  ✗ Błąd: ${CREATE_RESULT}${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Ustaw uprawnienia
    echo -n "  [5/7] Ustawiam uprawnienia... "
    CHOWN_RESULT=$(ssh -o StrictHostKeyChecking=no \
                       -o UserKnownHostsFile=/dev/null \
                       -o LogLevel=ERROR \
                       -p "${SSH_PORT}" \
                       "${SSH_USER}@${server}" \
                       "sudo chown -R ${SSH_USER}: '${REMOTE_BASE_DIR}' && \
                        sudo chmod 755 '${REMOTE_BASE_DIR}' && \
                        sudo chmod 755 '${REMOTE_BASE_DIR}'/{config,scripts,logs} 2>&1")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}FAIL${NC}"
        echo -e "${RED}  ✗ Błąd: ${CHOWN_RESULT}${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Utwórz/zaktualizuj sudoers
    echo -n "  [6/7] Konfiguruję sudoers... "
    
    SUDOERS_CONTENT="${SSH_USER} ALL=(ALL) NOPASSWD: ${REMOTE_BASE_DIR}/scripts/update-worker.sh"
    SUDOERS_PATH="/etc/sudoers.d/${SUDOERS_FILE}"
    
    SUDOERS_RESULT=$(ssh -o StrictHostKeyChecking=no \
                         -o UserKnownHostsFile=/dev/null \
                         -o LogLevel=ERROR \
                         -p "${SSH_PORT}" \
                         "${SSH_USER}@${server}" \
                         "echo '${SUDOERS_CONTENT}' | sudo tee '${SUDOERS_PATH}' > /dev/null && \
                          sudo chmod 440 '${SUDOERS_PATH}' 2>&1")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}FAIL${NC}"
        echo -e "${RED}  ✗ Błąd: ${SUDOERS_RESULT}${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Weryfikuj sudo
    echo -n "  [7/7] Weryfikuję sudo... "
    SUDO_TEST=$(ssh -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR \
                    -p "${SSH_PORT}" \
                    "${SSH_USER}@${server}" \
                    "sudo -n echo ok 2>&1")
    
    if [ "$SUDO_TEST" != "ok" ]; then
        echo -e "${RED}FAIL${NC}"
        echo -e "${RED}  ✗ Sudo nie działa poprawnie${NC}"
        echo -e "${RED}  ✗ ${SUDO_TEST}${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    echo ""
    echo -e "${GREEN}  ✓ Serwer ${server} - GOTOWY${NC}"
    echo ""
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    return 0
}

# ════════════════════════════════════════════════════════════
# GŁÓWNA PĘTLA
# ════════════════════════════════════════════════════════════

echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  INICJALIZACJA SERWERÓW ZDALNYCH${NC}"
echo -e "${YELLOW}  Serwerów do przetworzenia: ${#SERVERS[@]}${NC}"
echo -e "${YELLOW}  Katalog zdalny: ${REMOTE_BASE_DIR}${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo ""

server_num=0
for server in "${SERVERS[@]}"; do
    server_num=$((server_num + 1))
    echo -e "${BLUE}[${server_num}/${#SERVERS[@]}]${NC}"
    
    # Sprawdź czy istnieje plik konfiguracyjny (PRZED SSH)
    config_file="${CONTROL_BASE_DIR}/config/${server}.conf"
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}  Serwer: ${server}${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}  ✗ POMINIĘTO: Brak pliku konfiguracyjnego${NC}"
        echo -e "${RED}    Oczekiwany: ${config_file}${NC}"
        echo -e "${RED}    Akcja wymagana:${NC}"
        echo -e "${RED}      cp config/template.conf ${config_file}${NC}"
        echo -e "${RED}      vim ${config_file}${NC}"
        echo ""
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue  # Następny serwer, BEZ próby SSH
    fi
    
    init_single_server "$server"
done

# ════════════════════════════════════════════════════════════
# PODSUMOWANIE
# ════════════════════════════════════════════════════════════

echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  PODSUMOWANIE INICJALIZACJI${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "  Sukces:         ${GREEN}${SUCCESS_COUNT}${NC}"
echo -e "  Błąd:           ${RED}${FAIL_COUNT}${NC}"
echo -e "  Już istniały:   ${YELLOW}${SKIP_COUNT}${NC}"
echo -e "  Łącznie:        ${#SERVERS[@]}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}✓ Wszystkie serwery gotowe do pracy z orchestratorem${NC}"
    echo ""
    echo -e "${YELLOW}NASTĘPNE KROKI:${NC}"
    echo -e "  1. Upewnij się że pliki konfiguracyjne są wypełnione:"
    echo -e "     ${CONTROL_BASE_DIR}/config/HOSTNAME.conf"
    echo -e "  2. Uruchom orchestrator:"
    echo -e "     ./orchestrator.sh HOSTNAME"
    exit 0
else
    echo -e "${RED}✗ Niektóre serwery nie zostały zainicjalizowane${NC}"
    echo -e "${RED}  Sprawdź błędy powyżej i spróbuj ponownie${NC}"
    exit 1
fi
