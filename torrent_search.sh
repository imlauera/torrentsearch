#!/usr/bin/env bash
# =============================================================================
# ares.sh — "El nuevo Ares"
# https://imlauera.github.io/post/el_nuevo_ares/
#
# Uso:
#   ./ares.sh "Formula 1"
#   ./ares.sh --reset
#   ./ares.sh --setup
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
step()  { echo -e "\n${MAGENTA}───${RESET} ${BOLD}$*${RESET}"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

# ─── Config ──────────────────────────────────────────────────────────────────
QBT_HOST="http://127.0.0.1:8080"
QBT_USER="admin"
QBT_PASS="adminadmin"
QBT_COOKIES="/tmp/qbt_cookies.txt"
QBT_CONF="$HOME/.config/qBittorrent/qBittorrent.conf"
QBT_CONF_SYS="/var/lib/qbittorrent/.config/qBittorrent/qBittorrent.conf"
QBT_LOG="/tmp/qbt.log"

JACKETT_HOST="http://127.0.0.1:9117"
JACKETT_ENGINES_DIR="$HOME/.local/share/qBittorrent/nova3/engines"
JACKETT_KEY_FILE="$JACKETT_ENGINES_DIR/jackett.json"
JACKETT_PLUGIN_URL="https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/jackett.py"

DOWNLOAD_DIR="/var/lib/qbittorrent/Downloads"
RESULTS_JSON="[]"  # global, se llena en do_search y se lee en show_menu
MAGNET=""          # global, se llena en show_menu y se lee en add_torrent

# ─── Args ────────────────────────────────────────────────────────────────────
MODE="search"
QUERY=""

usage() {
    echo -e "${BOLD}Uso:${RESET}"
    echo "  $0 \"búsqueda\"   Buscar torrents y elegir interactivamente"
    echo "  $0 --setup      Instalar y configurar todo"
    echo "  $0 --reset      Reiniciar servicios cuando algo falla"
    echo "  $0 --help"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --help|-h) usage ;;
        --reset)   MODE="reset" ;;
        --setup)   MODE="setup" ;;
        *)         QUERY="$arg" ;;
    esac
done

# ─── Banner ──────────────────────────────────────────────────────────────────
banner() {
    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║   ⚡  El Nuevo Ares — Torrent Searcher       ║${RESET}"
    echo -e "${BOLD}${CYAN}║   qBittorrent-nox + Jackett + mpv            ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
    echo -e "   ${DIM}https://imlauera.github.io/post/el_nuevo_ares/${RESET}\n"
    echo -e "${YELLOW}┌──────────────────────────────────────────────┐${RESET}"
    echo -e "${YELLOW}│  ⚠  Configurar Jackett antes de usar         │${RESET}"
    echo -e "${YELLOW}│  1. Abrí http://localhost:9117               │${RESET}"
    echo -e "${YELLOW}│  2. Add indexer → marcá los que querés       │${RESET}"
    echo -e "${YELLOW}│     (cada indexer = una fuente de torrents)  │${RESET}"
    echo -e "${YELLOW}│  3. Add selected → guardar API key en        │${RESET}"
    echo -e "${YELLOW}│     ~/.local/share/qBittorrent/nova3/        │${RESET}"
    echo -e "${YELLOW}│     engines/jackett.json                     │${RESET}"
    echo -e "${YELLOW}└──────────────────────────────────────────────┘${RESET}\n"
}

# ─── Reset ───────────────────────────────────────────────────────────────────
do_reset() {
    step "Reiniciando servicios..."
    pkill -f qbittorrent-nox 2>/dev/null && ok "qBittorrent-nox detenido." || info "No había proceso activo."
    rm -f "$QBT_COOKIES" "$QBT_LOG" /tmp/qbt_*.txt
    sudo systemctl restart qbittorrent-nox 2>/dev/null && ok "qBittorrent-nox reiniciado." || true
    sudo systemctl restart jackett         2>/dev/null && ok "Jackett reiniciado."          || true
    ok "Reset completo."
    exit 0
}

# ─── Setup ───────────────────────────────────────────────────────────────────
do_setup() {
    step "Instalando dependencias..."
    if command -v apt &>/dev/null; then
        sudo apt update -qq && sudo apt install -y qbittorrent-nox jackett curl jq mpv python3
    elif command -v yay &>/dev/null; then
        yay -S --noconfirm qbittorrent-nox jackett-bin curl jq mpv
    elif command -v pacman &>/dev/null; then
        sudo pacman -Sy --noconfirm qbittorrent-nox curl jq mpv
        warn "Instalá jackett: yay -S jackett-bin"
    else
        warn "Instalá manualmente: qbittorrent-nox jackett curl jq mpv"
    fi

    step "Configurando jackett.json..."
    setup_jackett_json

    step "Descargando plugin jackett.py..."
    mkdir -p "$JACKETT_ENGINES_DIR"
    curl -sL "$JACKETT_PLUGIN_URL" -o "$JACKETT_ENGINES_DIR/jackett.py" \
        && ok "Plugin: $JACKETT_ENGINES_DIR/jackett.py" \
        || warn "Descargalo manualmente: $JACKETT_PLUGIN_URL"

    configure_qbt
    ok "Setup completo. Corré: $0 \"nombre del torrent\""
    exit 0
}

# ─── Deps ────────────────────────────────────────────────────────────────────
check_deps() {
    step "Verificando dependencias..."
    local missing=0
    for cmd in qbittorrent-nox curl jq python3; do
        if command -v "$cmd" &>/dev/null; then ok "  ✓ $cmd"
        else warn "  ✗ $cmd"; missing=1; fi
    done
    local jf=0
    command -v jackett &>/dev/null && jf=1
    [[ -f /usr/lib/jackett/jackett ]] && jf=1
    [[ -f /usr/lib/jackett/Jackett ]] && jf=1
    systemctl list-unit-files --type=service 2>/dev/null | grep -qi jackett && jf=1
    if [[ $jf -eq 1 ]]; then ok "  ✓ jackett"
    else warn "  ✗ jackett (yay -S jackett-bin)"; missing=1; fi
    [[ $missing -eq 1 ]] && die "Faltan dependencias. Corré: $0 --setup"
}

# ─── jackett.json ────────────────────────────────────────────────────────────
setup_jackett_json() {
    mkdir -p "$JACKETT_ENGINES_DIR"
    if [[ ! -f "$JACKETT_KEY_FILE" ]]; then
        cat > "$JACKETT_KEY_FILE" <<'EOF'
{
    "api_key": "YOUR_API_KEY_HERE",
    "url": "http://127.0.0.1:9117",
    "tracker_first": false,
    "thread_count": 20
}
EOF
        warn "Editá $JACKETT_KEY_FILE con tu API key de http://localhost:9117"
    else
        local updated
        updated=$(jq '. + {
            "url":           (.url           // "http://127.0.0.1:9117"),
            "tracker_first": (.tracker_first // false),
            "thread_count":  (.thread_count  // 20)
          }' "$JACKETT_KEY_FILE" 2>/dev/null) || true
        [[ -n "$updated" ]] && echo "$updated" > "$JACKETT_KEY_FILE"
        ok "jackett.json OK."
    fi
}

# ─── qBittorrent.conf ────────────────────────────────────────────────────────
configure_qbt() {
    local PASS_LINE
    PASS_LINE='WebUI\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ==)"'

    for conf in "$QBT_CONF" "$QBT_CONF_SYS"; do
        local dir; dir=$(dirname "$conf")
        local use_sudo=false
        [[ "$conf" == "$QBT_CONF_SYS" ]] && use_sudo=true

        if $use_sudo; then
            sudo mkdir -p "$dir" 2>/dev/null || continue
        else
            mkdir -p "$dir"
        fi

        local write_cmd="tee"
        $use_sudo && write_cmd="sudo tee"

        if [[ ! -f "$conf" ]]; then
            printf '[Preferences]\n%s\nWebUI\\Port=8080\nWebUI\\Username=admin\nWebUI\\LocalHostAuth=false\n' \
                "$PASS_LINE" | $write_cmd "$conf" > /dev/null
            $use_sudo && sudo chown -R qbt:qbt "$dir" 2>/dev/null || true
            ok "Config creada: $conf"
        elif grep -qF 'Password_PBKDF2' "$conf" 2>/dev/null; then
            ok "Contraseña ya OK: $conf"
        else
            if $use_sudo; then
                sudo sed -i "/^\[Preferences\]/a ${PASS_LINE}" "$conf" 2>/dev/null || true
            else
                sed -i "/^\[Preferences\]/a ${PASS_LINE}" "$conf" 2>/dev/null || true
            fi
            ok "Contraseña insertada: $conf"
        fi
    done
}

# ─── qBittorrent-nox ─────────────────────────────────────────────────────────
start_qbt() {
    if curl -sf "$QBT_HOST/api/v2/app/version" &>/dev/null; then
        ok "qBittorrent-nox ya está corriendo."; return
    fi
    configure_qbt
    sudo mkdir -p "$DOWNLOAD_DIR"
    sudo chown qbt:qbt "$DOWNLOAD_DIR" 2>/dev/null || true
    sudo chmod 775 "$DOWNLOAD_DIR" 2>/dev/null || true
    sudo usermod -aG qbt "$USER" 2>/dev/null || true

    info "Iniciando qBittorrent-nox via systemd..."
    sudo systemctl start qbittorrent-nox \
        || die "systemctl start qbittorrent-nox falló."

    local tries=0
    while true; do
        curl -sf "$QBT_HOST/api/v2/app/version" &>/dev/null && { ok "qBittorrent-nox corriendo."; break; }
        tries=$(( tries + 1 ))
        if [[ $tries -ge 30 ]]; then
            sudo systemctl status qbittorrent-nox --no-pager -l >&2
            die "qBittorrent-nox no responde en $QBT_HOST"
        fi
        sleep 1
    done
}

# ─── Login ───────────────────────────────────────────────────────────────────
login_qbt() {
    info "Login en WebUI..."
    local result
    result=$(curl -sf -X POST "$QBT_HOST/api/v2/auth/login" \
        -d "username=${QBT_USER}&password=${QBT_PASS}" \
        -c "$QBT_COOKIES" 2>/dev/null) || result=""

    case "$result" in
        "Ok.") ok "Login exitoso." ;;
        "Fails.")
            warn "Contraseña incorrecta. Buscando contraseña temporal en journal..."
            local tmp_pass
            tmp_pass=$(sudo journalctl -u qbittorrent-nox -n 50 --no-pager 2>/dev/null \
                | grep -oE "temporary password is provided for this session: [^ ]+" \
                | awk '{print $NF}' | tail -1)
            if [[ -n "$tmp_pass" ]]; then
                result=$(curl -sf -X POST "$QBT_HOST/api/v2/auth/login" \
                    -d "username=admin&password=${tmp_pass}" \
                    -c "$QBT_COOKIES" 2>/dev/null) || result=""
                [[ "$result" == "Ok." ]] || die "Login fallido. Corré --reset."
                ok "Login con contraseña temporal."
                curl -sf -X POST "$QBT_HOST/api/v2/app/setPreferences" \
                    -b "$QBT_COOKIES" \
                    -d 'json={"web_ui_password":"adminadmin"}' &>/dev/null || true
                ok "Contraseña fijada a 'adminadmin'."
            else
                die "Login fallido. Corré --reset."
            fi ;;
        *) warn "Respuesta: '${result:-vacía}' (asumiendo sesión activa)." ;;
    esac
}

# ─── Jackett ─────────────────────────────────────────────────────────────────
start_jackett() {
    info "Iniciando Jackett..."
    systemctl is-active --quiet jackett 2>/dev/null || \
        sudo systemctl start jackett 2>/dev/null || \
        warn "No se pudo iniciar Jackett con systemd."

    local tries=0
    while ! curl -sf "$JACKETT_HOST" &>/dev/null; do
        tries=$(( tries + 1 ))
        [[ $tries -ge 25 ]] && die "Jackett no responde en $JACKETT_HOST"
        sleep 1
    done
    ok "Jackett disponible."
}

get_jackett_key() {
    setup_jackett_json
    JACKETT_API_KEY=$(jq -r '.api_key // empty' "$JACKETT_KEY_FILE" 2>/dev/null) || JACKETT_API_KEY=""
    [[ -z "$JACKETT_API_KEY" || "$JACKETT_API_KEY" == "YOUR_API_KEY_HERE" ]] && \
        die "API key no configurada. Editá $JACKETT_KEY_FILE"
    ok "API key OK."
}

# ─── Búsqueda ────────────────────────────────────────────────────────────────
do_search() {
    local query_encoded
    query_encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$QUERY")

    step "Buscando '${BOLD}${QUERY}${RESET}'..."
    local raw
    raw=$(curl -sf \
        "${JACKETT_HOST}/api/v2.0/indexers/all/results?Query=${query_encoded}&apikey=${JACKETT_API_KEY}" \
        2>/dev/null) || raw=""

    [[ -z "$raw" ]] && die "Sin respuesta de Jackett. ¿API key correcta?"

    local total
    total=$(echo "$raw" | jq '.Results | length' 2>/dev/null) || total=0
    [[ "$total" -eq 0 ]] && die "Sin resultados para '${QUERY}'. Agregá más indexers en http://localhost:9117"

    # El magnet puede estar en:
    #   1. Guid       → empieza con "magnet:?"
    #   2. MagnetUri  → empieza con "magnet:?"
    #   3. Link       → URL de Jackett proxy (127.0.0.1:9117/dl/...) que redirige al magnet
    # Guardamos todos los resultados con cualquier link válido, resolvemos el magnet después

    local total_raw
    total_raw=$(echo "$raw" | jq '.Results | length' 2>/dev/null) || total_raw=0
    info "Resultados totales de Jackett: $total_raw"

    RESULTS_JSON=$(echo "$raw" | jq -r '[
        .Results[]
        | {
            title:    (.Title       // "sin título"),
            seeds:    (.Seeders     // 0),
            peers:    (.Peers       // 0),
            size:     (.Size        // 0),
            date:     (.PublishDate // ""),
            indexer:  (.Tracker // .TrackerId // "?"),
            infohash: (.InfoHash    // ""),
            magnet:   (if ((.MagnetUri // "") | startswith("magnet:?")) then .MagnetUri
                       elif ((.Guid // "") | startswith("magnet:?")) then .Guid
                       else "" end),
            link:     (.Link // "")
          }
      ] | sort_by(-.seeds)
    ' 2>/dev/null) || RESULTS_JSON="[]"

    local count
    count=$(echo "$RESULTS_JSON" | jq 'length' 2>/dev/null) || count=0
    info "Con magnet o link: $count"
    [[ "$count" -eq 0 ]] && die "Sin resultados. Agregá indexers en http://localhost:9117"

    ok "Encontrados: ${BOLD}${count}${RESET} torrents con magnet link (de $total totales)"
}

# ─── Menú interactivo ────────────────────────────────────────────────────────
show_menu() {
    local count
    count=$(echo "$RESULTS_JSON" | jq 'length')
    local page_size=15
    local page=0
    local total_pages=$(( (count + page_size - 1) / page_size ))

    while true; do
        local start=$(( page * page_size ))
        local end=$(( start + page_size ))
        [[ $end -gt $count ]] && end=$count

        echo ""
        echo -e "${BOLD}${CYAN}Resultados para: \"${QUERY}\"${RESET}  ${DIM}(página $(( page + 1 ))/${total_pages})${RESET}"
        echo -e "${DIM}─────────────────────────────────────────────────────────────────────────${RESET}"
        printf "${BOLD}%-4s %-7s %-7s %-10s %-12s %s${RESET}\n" "#" "SEEDS" "PEERS" "TAMAÑO" "INDEXER" "NOMBRE"
        echo -e "${DIM}─────────────────────────────────────────────────────────────────────────${RESET}"

        local i=$start
        while [[ $i -lt $end ]]; do
            local item
            item=$(echo "$RESULTS_JSON" | jq -r ".[$i]")
            local seeds peers size_bytes size_str title indexer date
            seeds=$(echo "$item"   | jq -r '.seeds')
            peers=$(echo "$item"   | jq -r '.peers')
            size_bytes=$(echo "$item" | jq -r '.size')
            title=$(echo "$item"   | jq -r '.title')
            indexer=$(echo "$item" | jq -r '.indexer')
            date=$(echo "$item"    | jq -r '.date' | cut -c1-10)

            # Formatear tamaño
            if [[ "$size_bytes" -gt 1073741824 ]] 2>/dev/null; then
                size_str=$(awk "BEGIN{printf \"%.1fGB\", $size_bytes/1073741824}")
            elif [[ "$size_bytes" -gt 1048576 ]] 2>/dev/null; then
                size_str=$(awk "BEGIN{printf \"%.0fMB\", $size_bytes/1048576}")
            else
                size_str="${size_bytes}B"
            fi

            # Color según seeds
            local num=$((i - start + 1))
            local seed_color="$RED"
            [[ "$seeds" -ge 5  ]] 2>/dev/null && seed_color="$YELLOW"
            [[ "$seeds" -ge 20 ]] 2>/dev/null && seed_color="$GREEN"

            # Truncar título
            local title_short="${title:0:52}"
            [[ ${#title} -gt 52 ]] && title_short="${title_short}…"

            printf "${BOLD}%-4s${RESET} ${seed_color}%-7s${RESET} ${DIM}%-7s${RESET} %-10s ${DIM}%-12s${RESET} %s\n" \
                "$num" "$seeds" "$peers" "$size_str" "${indexer:0:12}" "$title_short"

            i=$(( i + 1 ))
        done

        echo -e "${DIM}─────────────────────────────────────────────────────────────────────────${RESET}"

        # Opciones de navegación
        local nav_opts=""
        [[ $page -gt 0 ]]                    && nav_opts="${nav_opts}  ${BOLD}p${RESET}=anterior"
        [[ $(( page + 1 )) -lt $total_pages ]] && nav_opts="${nav_opts}  ${BOLD}n${RESET}=siguiente"
        nav_opts="${nav_opts}  ${BOLD}q${RESET}=salir  ${BOLD}b${RESET}=nueva búsqueda"

        echo -e "\n  Elegí un número para descargar | $nav_opts"
        echo -ne "\n  ${BOLD}→ ${RESET}"
        read -r choice

        case "$choice" in
            q|Q) echo "Saliendo."; exit 0 ;;
            n|N)
                if [[ $(( page + 1 )) -lt $total_pages ]]; then
                    page=$(( page + 1 ))
                else
                    warn "Ya estás en la última página."
                fi ;;
            p|P)
                if [[ $page -gt 0 ]]; then
                    page=$(( page - 1 ))
                else
                    warn "Ya estás en la primera página."
                fi ;;
            b|B)
                echo -ne "\n  ${BOLD}Nueva búsqueda: ${RESET}"
                read -r QUERY
                [[ -z "$QUERY" ]] && continue
                do_search
                count=$(echo "$RESULTS_JSON" | jq 'length')
                total_pages=$(( (count + page_size - 1) / page_size ))
                page=0 ;;
            ''|*[!0-9]*)
                warn "Opción inválida." ;;
            *)
                local idx=$(( start + choice - 1 ))
                if [[ $idx -lt $start || $idx -ge $end ]]; then
                    warn "Número fuera de rango (1-$(( end - start )))."
                    continue
                fi
                local sel_magnet sel_link sel_infohash sel_title sel_seeds
                sel_magnet=$(echo "$RESULTS_JSON"   | jq -r ".[$idx].magnet   // empty")
                sel_link=$(echo "$RESULTS_JSON"     | jq -r ".[$idx].link     // empty")
                sel_infohash=$(echo "$RESULTS_JSON" | jq -r ".[$idx].infohash // empty")
                sel_title=$(echo "$RESULTS_JSON"    | jq -r ".[$idx].title")
                sel_seeds=$(echo "$RESULTS_JSON"    | jq -r ".[$idx].seeds")

                echo ""
                ok "Seleccionado: ${BOLD}${sel_title}${RESET}"
                ok "Seeds: ${BOLD}${sel_seeds}${RESET}"

                if [[ -n "$sel_magnet" ]]; then
                    MAGNET="$sel_magnet"
                    ok "Magnet directo disponible."
                elif [[ -n "$sel_infohash" ]]; then
                    local enc_title
                    enc_title=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$sel_title")
                    MAGNET="magnet:?xt=urn:btih:${sel_infohash}&dn=${enc_title}"
                    ok "Magnet construido desde InfoHash."
                elif [[ -n "$sel_link" ]]; then
                    info "Resolviendo link de Jackett..."
                    local resolved
                    resolved=$(curl -sIL --max-redirs 10 "$sel_link" 2>/dev/null                         | grep -i "^location:" | tail -1 | tr -d '
' | sed 's/location: //i')
                    if echo "$resolved" | grep -q "^magnet:"; then
                        MAGNET="$resolved"
                        ok "Magnet resuelto desde redirect."
                    else
                        # qBittorrent acepta URLs de .torrent directamente
                        MAGNET="$sel_link"
                        ok "Usando URL de torrent (qBittorrent lo descarga solo)."
                    fi
                else
                    warn "Sin magnet, infohash ni link. Elegí otro."
                    continue
                fi
                return ;;
        esac
    done
}

# ─── Agregar torrent ─────────────────────────────────────────────────────────
add_torrent() {
    info "Agregando a qBittorrent..."
    local resp
    resp=$(curl -sf -X POST "$QBT_HOST/api/v2/torrents/add" \
        -b "$QBT_COOKIES" \
        --data-urlencode "urls=$MAGNET" \
        -d "savepath=$DOWNLOAD_DIR" \
        -d "sequentialDownload=true" \
        -d "firstLastPiecePrio=true" \
        2>/dev/null) || resp="(sin respuesta)"
    ok "qBittorrent: ${resp}"
}

# ─── Esperar y abrir ─────────────────────────────────────────────────────────
wait_and_open() {
    local torrent_hash state="" metadl_count=0
    torrent_hash=$(echo "$MAGNET" | grep -oE 'btih:[a-fA-F0-9]+' | cut -d: -f2 | tr '[:upper:]' '[:lower:]')
    info "Hash: $torrent_hash"
    info "Esperando descarga... (Ctrl+C para cancelar)"

    local found="" tries=0 max_wait=600

    while [[ $tries -lt $max_wait ]]; do
        local torrent_info content_path
        torrent_info=$(curl -sf "$QBT_HOST/api/v2/torrents/info?hashes=$torrent_hash" \
            -b "$QBT_COOKIES" 2>/dev/null) || torrent_info=""

        if [[ -n "$torrent_info" && "$torrent_info" != "[]" ]]; then
            state=$(echo "$torrent_info"        | jq -r '.[0].state        // empty' 2>/dev/null) || state=""
            content_path=$(echo "$torrent_info" | jq -r '.[0].content_path // empty' 2>/dev/null) || content_path=""
            local pct dl_speed
            pct=$(echo "$torrent_info" | jq -r '.[0].progress // 0' 2>/dev/null) || pct=0
            pct=$(awk "BEGIN{printf \"%.1f\", $pct * 100}" 2>/dev/null) || pct="?"
            dl_speed=$(echo "$torrent_info" | jq -r '.[0].dlspeed // 0' 2>/dev/null) || dl_speed=0
            local speed_str
            speed_str=$(awk "BEGIN{printf \"%.0f KB/s\", $dl_speed/1024}" 2>/dev/null) || speed_str="?"
            info "Estado: ${BOLD}${state:-?}${RESET} | ${pct}% | ↓ ${speed_str}"

            # Detectar metaDL prolongado (sin seeds reales)
            if [[ "$state" == "metaDL" ]]; then
                metadl_count=$(( metadl_count + 1 ))
                if [[ $metadl_count -ge 6 ]]; then
                    warn "Sin seeds reales (metaDL 30s). Cancelando..."
                    curl -sf -X POST "$QBT_HOST/api/v2/torrents/delete" \
                        -b "$QBT_COOKIES" \
                        -d "hashes=$torrent_hash&deleteFiles=false" &>/dev/null || true
                    warn "Volviendo al menú para elegir otro torrent..."
                    show_menu
                    add_torrent
                    torrent_hash=$(echo "$MAGNET" | grep -oE 'btih:[a-fA-F0-9]+' | cut -d: -f2 | tr '[:upper:]' '[:lower:]')
                    metadl_count=0; tries=0
                    info "Nuevo hash: $torrent_hash"
                    continue
                fi
            else
                metadl_count=0
            fi

            # Si terminó → abrir
            case "$state" in
                uploading|stalledUP|pausedUP|forcedUP|checkingUP|completed)
                    found="$content_path"
                    ok "¡Descarga completa!"
                    break ;;
            esac

            # Si está bajando y tiene suficiente para reproducir (video/audio)
            if [[ -n "$content_path" && -e "$content_path" ]]; then
                local size
                size=$(stat -c%s "$content_path" 2>/dev/null) || size=0
                # Para archivos grandes (>50MB): abrir apenas hay datos
                if [[ $size -gt 52428800 ]]; then
                    found="$content_path"
                    ok "Suficientes datos para reproducir ($(( size / 1048576 )) MB)"
                    break
                fi
            fi
        fi

        sleep 5
        tries=$(( tries + 5 ))
    done

    if [[ -z "$found" || ! -e "$found" ]]; then
        warn "No se encontró el archivo descargado."
        warn "Buscá en: $DOWNLOAD_DIR"
        info "WebUI: $QBT_HOST"
        exit 0
    fi

    open_file "$found"
}

# ─── Abrir archivo ────────────────────────────────────────────────────────────
open_file() {
    local target="$1"

    # Si es directorio: mostrar contenido y dejar elegir al usuario
    if [[ -d "$target" ]]; then
        echo ""
        info "El torrent es una carpeta. Contenido:"
        local files=()
        while IFS= read -r f; do
            files+=("$f")
        done < <(find "$target" -type f | sort)

        local i=1
        for f in "${files[@]}"; do
            local sz
            sz=$(stat -c%s "$f" 2>/dev/null) || sz=0
            local sz_str
            if [[ $sz -gt 1073741824 ]] 2>/dev/null; then
                sz_str=$(awk "BEGIN{printf \"%.1fGB\", $sz/1073741824}")
            elif [[ $sz -gt 1048576 ]] 2>/dev/null; then
                sz_str=$(awk "BEGIN{printf \"%.0fMB\", $sz/1048576}")
            else
                sz_str="${sz}B"
            fi
            printf "  ${BOLD}%2d${RESET}  %-8s  %s\n" "$i" "$sz_str" "$(basename "$f")"
            i=$(( i + 1 ))
        done

        echo ""
        echo -ne "  ${BOLD}¿Qué archivo abrís? (número, Enter=el más grande, q=no abrir): ${RESET}"
        read -r file_choice

        case "$file_choice" in
            q|Q) info "Archivos en: $target"; return ;;
            ''|*[!0-9]*)
                # Enter → el más grande
                target=$(find "$target" -type f -exec stat -c "%s %n" {} \; 2>/dev/null \
                    | sort -rn | head -1 | cut -d' ' -f2-) ;;
            *)
                local fidx=$(( file_choice - 1 ))
                if [[ $fidx -ge 0 && $fidx -lt ${#files[@]} ]]; then
                    target="${files[$fidx]}"
                else
                    warn "Número inválido. Abriendo el más grande."
                    target=$(find "$target" -type f -exec stat -c "%s %n" {} \; 2>/dev/null \
                        | sort -rn | head -1 | cut -d' ' -f2-)
                fi ;;
        esac
    fi

    [[ -z "$target" || ! -f "$target" ]] && { warn "Archivo no encontrado."; return; }

    echo ""
    ok "Abriendo: ${BOLD}$(basename "$target")${RESET}"

    # Elegir cómo abrir según extensión
    local ext="${target##*.}"
    case "${ext,,}" in
        mkv|mp4|avi|mov|webm|ts|m4v|m2ts|flv|wmv)
            mpv --cache=yes --cache-secs=120 --demuxer-readahead-secs=60 \
                --force-seekable=yes --title="$(basename "$target")" "$target" ;;
        mp3|flac|ogg|opus|aac|wav|m4a|wma)
            mpv --no-video --title="$(basename "$target")" "$target" ;;
        *)
            # Cualquier otra cosa: intentar xdg-open, si no mpv
            if command -v xdg-open &>/dev/null; then
                xdg-open "$target" &
                ok "Abierto con xdg-open."
            else
                mpv "$target" || warn "No sé cómo abrir .${ext}. Archivo en: $target"
            fi ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
banner

case "$MODE" in
    reset) do_reset ;;
    setup) do_setup ;;
    search)
        if [[ -z "$QUERY" ]]; then
            echo -ne "  ${BOLD}¿Qué querés buscar? ${RESET}"
            read -r QUERY
            [[ -z "$QUERY" ]] && die "Búsqueda vacía."
        fi

        check_deps
        start_qbt
        login_qbt
        start_jackett
        get_jackett_key
        do_search
        show_menu
        add_torrent
        wait_and_open

        echo ""
        ok "¡Listo! 🍿"
        ;;
esac
