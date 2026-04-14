#!/bin/bash
# ════════════════════════════════════════════════════════════
# Skrypt do hurtowej modyfikacji plików .conf
# Autor: Krzysztof Boroń
# Operacje:
#   1. Usuwa 7 ostatnich linijek (końcowy komentarz)
#   2. Waliduje znaczniki przed usunięciem (zabezpieczenie)
#   3. Dodaje nowy blok konfiguracyjny STOP_SERVICES_MODE
# ════════════════════════════════════════════════════════════

# ─── KONFIGURACJA ──────────────────────────────────────────
# Ścieżka do katalogu z plikami .conf (EDYTUJ TĘ WARTOŚĆ!)
CONF_DIR="/ścieżka/do/katalogu/z/plikami/conf"

# Tryb działania: "dry-run" lub "execute"
MODE="dry-run"

# Znaczniki walidacyjne (sprawdzane przed usunięciem 7 linijek)
MARKER1="# KONIEC KONFIGURACJI"          # 6. linia od końca
MARKER2="# Po zapisaniu tego pliku:"     # 4. linia od końca
# ───────────────────────────────────────────────────────────

# Kolory dla outputu
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── WALIDACJA ─────────────────────────────────────────────
if [[ ! -d "$CONF_DIR" ]]; then
    echo -e "${RED}[BŁĄD]${NC} Katalog nie istnieje: $CONF_DIR"
    echo "Edytuj zmienną CONF_DIR w skrypcie i podaj prawidłową ścieżkę."
    exit 1
fi

# Sprawdź czy są pliki .conf
conf_files=("$CONF_DIR"/*.conf)
if [[ ! -e "${conf_files[0]}" ]]; then
    echo -e "${RED}[BŁĄD]${NC} Nie znaleziono plików .conf w katalogu: $CONF_DIR"
    exit 1
fi

# Policz pliki
file_count=$(ls -1 "$CONF_DIR"/*.conf 2>/dev/null | wc -l)

echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Modyfikacja plików .conf${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "Katalog:      ${YELLOW}$CONF_DIR${NC}"
echo -e "Plików .conf: ${YELLOW}$file_count${NC}"
echo -e "Tryb:         ${YELLOW}$MODE${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo

# ─── DRY-RUN: POKAŻ PRZYKŁAD ───────────────────────────────
if [[ "$MODE" == "dry-run" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Pokazuję przykład na pierwszym pliku..."
    echo
    
    first_file="${conf_files[0]}"
    echo -e "${GREEN}Plik przykładowy:${NC} $(basename "$first_file")"
    echo
    
    # Walidacja znaczników
    total_lines=$(wc -l < "$first_file")
    line_minus_6=$(tail -n 6 "$first_file" | head -n 1)
    line_minus_4=$(tail -n 4 "$first_file" | head -n 1)
    
    echo -e "${BLUE}─── WALIDACJA ZNACZNIKÓW: ───${NC}"
    echo "Linia -6: $line_minus_6"
    if [[ "$line_minus_6" == "$MARKER1" ]]; then
        echo -e "${GREEN}✓${NC} Znacznik 1 OK: '$MARKER1'"
    else
        echo -e "${RED}✗${NC} Znacznik 1 NIE PASUJE (oczekiwano: '$MARKER1')"
    fi
    
    echo "Linia -4: $line_minus_4"
    if [[ "$line_minus_4" == "$MARKER2" ]]; then
        echo -e "${GREEN}✓${NC} Znacznik 2 OK: '$MARKER2'"
    else
        echo -e "${RED}✗${NC} Znacznik 2 NIE PASUJE (oczekiwano: '$MARKER2')"
    fi
    echo
    
    # Pokaż 10 ostatnich linijek (przed modyfikacją)
    echo -e "${BLUE}─── OBECNE 10 OSTATNICH LINIJEK: ───${NC}"
    tail -10 "$first_file"
    echo
    
    # Stwórz tymczasowy plik z modyfikacją
    temp_file=$(mktemp)
    lines_to_keep=$((total_lines - 7))
    
    # Usuń 7 ostatnich linijek
    head -n "$lines_to_keep" "$first_file" > "$temp_file"
    
    # Dodaj nowy blok
    cat >> "$temp_file" << 'EOF'
# ─── ZATRZYMYWANIE USŁUG ───────────────────────────────────
# Strategia zatrzymywania usług, aplikacji i baz danych
# Dostępne tryby:
#
#   "auto"   - Zatrzymuj usługi TYLKO gdy restart będzie wykonany (domyślnie)
#              Logika: po co zatrzymywać, skoro nie ma restartu?
#              • AUTO_REBOOT=never     → NIE zatrzymuj usług
#              • AUTO_REBOOT=critical  → zatrzymuj gdy critical packages
#              • AUTO_REBOOT=always    → zatrzymuj zawsze
#              Użyj gdy: chcesz inteligentnego zachowania (zero downtime bez restartu)
#
#   "always" - ZAWSZE zatrzymuj usługi przy critical packages (nawet bez restartu)
#              Użyj gdy: administrator chce manualnie zrestartować po sprawdzeniu
#              Scenariusz: pakiety zainstalowane, usługi zatrzymane, czekam na Twój restart
#
#   "never"  - NIGDY nie zatrzymuj usług (nawet przy restarcie)
#              Użyj gdy: potrzebujesz zero downtime (usługi działają do końca)
#              Scenariusz: load balancer, jeden z nodów w klastrze
#
# Przykłady kombinacji:
#   STOP_SERVICES_MODE="auto"   + AUTO_REBOOT="never"    → zero downtime, brak zatrzymywania
#   STOP_SERVICES_MODE="always" + AUTO_REBOOT="never"    → przygotuj do restartu, ale czekaj
#   STOP_SERVICES_MODE="auto"   + AUTO_REBOOT="critical" → zatrzymuj i restartuj przy critical
#   STOP_SERVICES_MODE="never"  + AUTO_REBOOT="always"   → restart bez zatrzymywania usług
STOP_SERVICES_MODE="auto"
# ════════════════════════════════════════════════════════════
# KONIEC KONFIGURACJI
# ════════════════════════════════════════════════════════════
# Po zapisaniu tego pliku:
# 1. Uruchom init-server.sh aby przygotować serwer
# 2. Uruchom orchestrator.sh aby wykonać aktualizację
# ════════════════════════════════════════════════════════════
EOF
    
    # Pokaż nowe 10 ostatnich linijek
    echo -e "${BLUE}─── NOWE 10 OSTATNICH LINIJEK (PO MODYFIKACJI): ───${NC}"
    tail -10 "$temp_file"
    echo
    
    rm -f "$temp_file"
    
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Jeśli wygląda dobrze:${NC}"
    echo -e "1. Wykonaj backup: ${GREEN}cp -r $CONF_DIR ${CONF_DIR}.backup${NC}"
    echo -e "2. Zmień w skrypcie: ${GREEN}MODE=\"execute\"${NC}"
    echo -e "3. Uruchom ponownie skrypt"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    exit 0
fi

# ─── EXECUTE: WYKONAJ ZMIANY ───────────────────────────────
if [[ "$MODE" == "execute" ]]; then
    echo -e "${GREEN}[EXECUTE]${NC} Wykonuję modyfikację wszystkich plików..."
    echo
    
    success_count=0
    error_count=0
    skipped_count=0
    
    for conf_file in "$CONF_DIR"/*.conf; do
        if [[ -f "$conf_file" ]]; then
            filename=$(basename "$conf_file")
            
            # Sprawdź czy plik ma przynajmniej 7 linijek
            total_lines=$(wc -l < "$conf_file")
            if [[ $total_lines -lt 7 ]]; then
                echo -e "${RED}[POMINIĘTO]${NC} $filename (za mało linijek: $total_lines)"
                ((skipped_count++))
                continue
            fi
            
            # Walidacja znaczników
            line_minus_6=$(tail -n 6 "$conf_file" | head -n 1)
            line_minus_4=$(tail -n 4 "$conf_file" | head -n 1)
            
            if [[ "$line_minus_6" != "$MARKER1" ]] || [[ "$line_minus_4" != "$MARKER2" ]]; then
                echo -e "${YELLOW}[POMINIĘTO]${NC} $filename (znaczniki nie pasują)"
                ((skipped_count++))
                continue
            fi
            
            # Stwórz tymczasowy plik
            temp_file=$(mktemp)
            lines_to_keep=$((total_lines - 7))
            
            # Usuń 7 ostatnich linijek
            head -n "$lines_to_keep" "$conf_file" > "$temp_file"
            
            # Dodaj nowy blok
            cat >> "$temp_file" << 'EOF'
# ─── ZATRZYMYWANIE USŁUG ───────────────────────────────────
# Strategia zatrzymywania usług, aplikacji i baz danych
# Dostępne tryby:
#
#   "auto"   - Zatrzymuj usługi TYLKO gdy restart będzie wykonany (domyślnie)
#              Logika: po co zatrzymywać, skoro nie ma restartu?
#              • AUTO_REBOOT=never     → NIE zatrzymuj usług
#              • AUTO_REBOOT=critical  → zatrzymuj gdy critical packages
#              • AUTO_REBOOT=always    → zatrzymuj zawsze
#              Użyj gdy: chcesz inteligentnego zachowania (zero downtime bez restartu)
#
#   "always" - ZAWSZE zatrzymuj usługi przy critical packages (nawet bez restartu)
#              Użyj gdy: administrator chce manualnie zrestartować po sprawdzeniu
#              Scenariusz: pakiety zainstalowane, usługi zatrzymane, czekam na Twój restart
#
#   "never"  - NIGDY nie zatrzymuj usług (nawet przy restarcie)
#              Użyj gdy: potrzebujesz zero downtime (usługi działają do końca)
#              Scenariusz: load balancer, jeden z nodów w klastrze
#
# Przykłady kombinacji:
#   STOP_SERVICES_MODE="auto"   + AUTO_REBOOT="never"    → zero downtime, brak zatrzymywania
#   STOP_SERVICES_MODE="always" + AUTO_REBOOT="never"    → przygotuj do restartu, ale czekaj
#   STOP_SERVICES_MODE="auto"   + AUTO_REBOOT="critical" → zatrzymuj i restartuj przy critical
#   STOP_SERVICES_MODE="never"  + AUTO_REBOOT="always"   → restart bez zatrzymywania usług
STOP_SERVICES_MODE="auto"
# ════════════════════════════════════════════════════════════
# KONIEC KONFIGURACJI
# ════════════════════════════════════════════════════════════
# Po zapisaniu tego pliku:
# 1. Uruchom init-server.sh aby przygotować serwer
# 2. Uruchom orchestrator.sh aby wykonać aktualizację
# ════════════════════════════════════════════════════════════
EOF
            
            # Nadpisz oryginalny plik
            if mv "$temp_file" "$conf_file"; then
                echo -e "${GREEN}[OK]${NC} $filename"
                ((success_count++))
            else
                echo -e "${RED}[BŁĄD]${NC} $filename (błąd zapisu)"
                rm -f "$temp_file"
                ((error_count++))
            fi
        fi
    done
    
    echo
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Zmodyfikowano:${NC} $success_count plików"
    if [[ $skipped_count -gt 0 ]]; then
        echo -e "${YELLOW}Pominięto:${NC}     $skipped_count plików (brak znaczników lub za mało linijek)"
    fi
    if [[ $error_count -gt 0 ]]; then
        echo -e "${RED}Błędy:${NC}         $error_count plików"
    fi
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    exit 0
fi

# ─── NIEPRAWIDŁOWY TRYB ────────────────────────────────────
echo -e "${RED}[BŁĄD]${NC} Nieprawidłowy tryb: $MODE"
echo "Użyj: MODE=\"dry-run\" lub MODE=\"execute\""
exit 1
