#!/usr/bin/env bash
set -euo pipefail

# ─── Minimum bash version (associative arrays require bash 4+) ───────────────
if (( BASH_VERSINFO[0] < 4 )); then
    echo "Error: bash 4+ is required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

# ─── Interactive TTY check ───────────────────────────────────────────────────
if [[ ! -t 0 || ! -t 1 ]]; then
    echo "Error: this script requires an interactive terminal (TTY)" >&2
    exit 1
fi

# ─── Error trap for readable failures ────────────────────────────────────────
trap 'echo -e "\033[0;31m✗ Failed at line $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

# ─── Colors & helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CONFIGS_DIR="$SCRIPT_DIR/configs"
SECRETS_DIR="$SCRIPT_DIR/secrets"

# Ensure required directories exist with restrictive permissions
mkdir -p "$CONFIGS_DIR" && chmod 700 "$CONFIGS_DIR"
mkdir -p -m 700 "$SECRETS_DIR"

info()    { echo -e "${CYAN}$1${RESET}" >&2; }
success() { echo -e "${GREEN}✓ $1${RESET}" >&2; }
warn()    { echo -e "${YELLOW}⚠ $1${RESET}" >&2; }
error()   { echo -e "${RED}✗ $1${RESET}" >&2; }
header()  { echo -e "\n${BOLD}$1${RESET}" >&2; }
dim()     { echo -e "${DIM}$1${RESET}" >&2; }

ask() {
    local prompt="$1"
    local default="${2:-}"
    if [[ -n "$default" ]]; then
        echo -ne "  ${prompt} ${DIM}[${default}]${RESET}: " >&2
    else
        echo -ne "  ${prompt}: " >&2
    fi
    read -r answer
    echo "${answer:-$default}"
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    echo -e "  ${prompt}" >&2
    for i in "${!options[@]}"; do
        echo -e "    ${BOLD}$((i+1)).${RESET} ${options[$i]}" >&2
    done
    while true; do
        echo -ne "  ${DIM}Enter number [1-${#options[@]}]${RESET}: " >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "$choice"
            return
        fi
        error "Invalid choice, try again"
    done
}

# ─── Clean path from drag & drop ─────────────────────────────────────────────
clean_path() {
    local p="$1"
    # Strip surrounding quotes (single or double)
    p="${p#\'}" ; p="${p%\'}"
    p="${p#\"}" ; p="${p%\"}"
    # Strip trailing whitespace
    p="${p%"${p##*[![:space:]]}"}"
    # Unescape backslash-spaces (drag & drop on macOS)
    p="${p//\\ / }"
    # Expand ~
    p="${p/#\~/$HOME}"
    echo "$p"
}

# ─── Banner ──────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "  ┌─────────────────────────────────┐"
echo "  │       Claudebox Setup           │"
echo "  │   Docker + Claude Code + VPN    │"
echo "  └─────────────────────────────────┘"
echo -e "${RESET}"

# ─── Prerequisites check ────────────────────────────────────────────────────
header "[0/5] Checking prerequisites..."

if ! command -v docker &>/dev/null; then
    error "Docker not found. Install: https://docs.docker.com/get-docker/"
    exit 1
fi

# Check Docker daemon is running
if ! docker info &>/dev/null 2>&1; then
    error "Docker daemon is not running. Start it and re-run this script."
    exit 1
fi

# Detect compose command once and use everywhere
if docker compose version &>/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif docker-compose version &>/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    error "docker compose not found"
    exit 1
fi

success "Docker is installed and running (${COMPOSE[*]})"

# ─── Step 1: VPN ─────────────────────────────────────────────────────────────
header "[1/5] VPN Configuration"
echo ""
dim "  You need an AmneziaWG config file from your Amnezia VPN server."
dim "  It looks like a WireGuard config with extra fields (Jc, Jmin, Jmax, S1, S2, H1-H4)."
dim "  In Amnezia app: Settings → Servers → Share → WireGuard config file."
echo ""

vpn_configured=false

while true; do
    vpn_path=$(ask "Path to your AmneziaWG config file (or drag & drop)")
    vpn_path=$(clean_path "$vpn_path")

    if [[ ! -f "$vpn_path" ]]; then
        error "File not found: $vpn_path"
        choice=$(ask_choice "What would you like to do?" "Try again" "Skip VPN setup (configure later)")
        if [[ "$choice" == "2" ]]; then
            warn "Skipping VPN. You'll need to place your config at configs/amnezia.conf before starting."
            break
        fi
        continue
    fi

    # Basic validation: check for WireGuard-like structure
    if ! grep -qi '\[Interface\]' "$vpn_path"; then
        error "This doesn't look like a valid WireGuard/AmneziaWG config (missing [Interface] section)"
        choice=$(ask_choice "What would you like to do?" "Try another file" "Use it anyway" "Skip VPN setup")
        if [[ "$choice" == "1" ]]; then
            continue
        elif [[ "$choice" == "3" ]]; then
            warn "Skipping VPN setup."
            break
        fi
    fi

    cp "$vpn_path" "$CONFIGS_DIR/amnezia.conf"
    chmod 600 "$CONFIGS_DIR/amnezia.conf"
    success "Config copied to configs/amnezia.conf"
    vpn_configured=true
    break
done

# ─── Step 2: Claude Authentication ──────────────────────────────────────────
header "[2/5] Claude Authentication"
echo ""

auth_choice=$(ask_choice "How do you want to authenticate with Claude?" \
    "API key (paste now)" \
    "Interactive login (in browser, after container starts)")

# Collect .env values (write all at once at the end to avoid partial truncation)
declare -A env_vars

if [[ "$auth_choice" == "1" ]]; then
    while true; do
        echo -ne "  Paste your ANTHROPIC_API_KEY (input is hidden): "
        read -rs api_key
        echo ""

        if [[ -z "$api_key" ]]; then
            error "API key cannot be empty"
            continue
        fi

        if [[ ! "$api_key" =~ ^sk-ant- ]]; then
            warn "Key doesn't start with 'sk-ant-'. It might still work."
            choice=$(ask_choice "Continue with this key?" "Yes" "Re-enter")
            if [[ "$choice" == "2" ]]; then
                continue
            fi
        fi

        # Store API key as a file (more secure than env var — not visible in docker inspect)
        (umask 077; echo -n "$api_key" > "$SECRETS_DIR/anthropic_api_key")
        # Clear the key from shell memory
        api_key=""; unset api_key
        success "API key saved to $SECRETS_DIR/anthropic_api_key"
        break
    done
else
    success "Will open browser login after container starts"
    dim "  Run 'claude' inside the container to authenticate"
fi

# ─── Step 3: Projects directory ──────────────────────────────────────────────
header "[3/5] Projects Directory"
echo ""
dim "  This directory will be mounted inside the container at /home/claude/projects"
dim "  You'll be able to use Claude Code on any project inside it."
echo ""

default_projects="$HOME/projects"
projects_path=$(ask "Path to your projects directory" "$default_projects")
projects_path=$(clean_path "$projects_path")

if [[ ! -d "$projects_path" ]]; then
    choice=$(ask_choice "Directory '$projects_path' doesn't exist. Create it?" "Yes" "Choose different path" "Skip")
    if [[ "$choice" == "1" ]]; then
        mkdir -p "$projects_path"
        success "Created $projects_path"
    elif [[ "$choice" == "2" ]]; then
        projects_path=$(ask "Path to your projects directory")
        projects_path=$(clean_path "$projects_path")
        if [[ ! -d "$projects_path" ]]; then
            mkdir -p "$projects_path"
            success "Created $projects_path"
        fi
    else
        projects_path="$default_projects"
        mkdir -p "$projects_path"
        warn "Using default: $projects_path"
    fi
fi

# Save projects path
env_vars[PROJECTS_PATH]="$projects_path"
success "Will mount $projects_path → /home/claude/projects"

# ─── Write .env file (all at once) ──────────────────────────────────────────
{
    for key in $(printf '%s\n' "${!env_vars[@]}" | sort); do
        val="${env_vars[$key]}"
        # Escape backslashes and double quotes for .env format
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        echo "${key}=\"${val}\""
    done
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# ─── Step 4: Exclude directories ────────────────────────────────────────────
header "[4/5] Exclude Directories"
echo ""
dim "  Hide directories from Claude Code inside your projects."
dim "  Two levels of protection:"
dim "    Soft  — .claudeignore: Claude Code won't search/read these paths"
dim "    Hard  — tmpfs overlay: empty dir mounted over real content (hidden inside container)"
echo ""

# Suspicious path patterns to auto-detect (name patterns for find -name)
SUSPECT_PATTERNS=("datafixes" "secrets")

claudeignore_entries=()
overlay_entries=()

# ── 4a. Auto-detect suspicious paths ────────────────────────────────────────
detected_paths=()
for pattern in "${SUSPECT_PATTERNS[@]}"; do
    while IFS= read -r found_path; do
        # Make relative to projects_path
        rel="${found_path#"$projects_path"/}"
        detected_paths+=("$rel")
    done < <(find "$projects_path" -maxdepth 4 -type d -name "$pattern" 2>/dev/null)
done

if [[ ${#detected_paths[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}Found potentially sensitive paths:${RESET}" >&2
    echo "" >&2

    # Track which items are selected (all selected by default)
    declare -A selected
    for i in "${!detected_paths[@]}"; do
        selected[$i]=1
    done

    # Display and let user toggle
    while true; do
        for i in "${!detected_paths[@]}"; do
            if [[ "${selected[$i]}" == "1" ]]; then
                echo -e "    ${GREEN}[x]${RESET} ${BOLD}$((i+1)).${RESET} ${detected_paths[$i]}" >&2
            else
                echo -e "    ${DIM}[ ]${RESET} ${BOLD}$((i+1)).${RESET} ${DIM}${detected_paths[$i]}${RESET}" >&2
            fi
        done
        echo "" >&2
        echo -ne "  ${DIM}Enter number to toggle, 'a' to select all, 'n' to deselect all, or 'done'${RESET}: " >&2
        read -r toggle_input

        if [[ "$toggle_input" == "done" || "$toggle_input" == "" ]]; then
            break
        elif [[ "$toggle_input" == "a" ]]; then
            for i in "${!detected_paths[@]}"; do selected[$i]=1; done
        elif [[ "$toggle_input" == "n" ]]; then
            for i in "${!detected_paths[@]}"; do selected[$i]=0; done
        elif [[ "$toggle_input" =~ ^[0-9]+$ ]] && (( toggle_input >= 1 )); then
            idx=$((toggle_input - 1))
            if (( idx < ${#detected_paths[@]} )); then
                if [[ "${selected[$idx]}" == "1" ]]; then
                    selected[$idx]=0
                else
                    selected[$idx]=1
                fi
            else
                error "Invalid number"
            fi
        else
            error "Invalid input"
        fi
    done

    # Ask protection level for all selected detected paths
    has_selected=false
    for i in "${!detected_paths[@]}"; do
        if [[ "${selected[$i]}" == "1" ]]; then
            has_selected=true
            break
        fi
    done

    if $has_selected; then
        level=$(ask_choice "Protection level for selected paths?" \
            "Soft (.claudeignore only)" \
            "Hard (tmpfs overlay — physically hidden)")

        for i in "${!detected_paths[@]}"; do
            if [[ "${selected[$i]}" == "1" ]]; then
                claudeignore_entries+=("${detected_paths[$i]}")
                if [[ "$level" == "2" ]]; then
                    overlay_entries+=("${detected_paths[$i]}")
                fi
                success "Added: ${detected_paths[$i]}"
            fi
        done
    fi
else
    dim "  No suspicious paths auto-detected."
fi

# ── 4b. Manual search ───────────────────────────────────────────────────────
echo "" >&2
add_more=$(ask_choice "Search for more paths to exclude?" \
    "Yes, search by name" \
    "No, continue")

while [[ "$add_more" == "1" ]]; do
    echo -ne "  Search (partial name): " >&2
    read -r search_term

    if [[ -z "$search_term" ]]; then
        add_more=$(ask_choice "Search for more?" "Yes" "No, continue")
        continue
    fi

    # Sanitize search term: escape glob characters to prevent find pattern injection
    safe_term=$(printf '%s' "$search_term" | sed 's/[][*?\\]/\\&/g')

    # Find matching paths
    search_results=()
    while IFS= read -r found_path; do
        rel="${found_path#"$projects_path"/}"
        search_results+=("$rel")
    done < <(find "$projects_path" -maxdepth 5 -iname "*${safe_term}*" 2>/dev/null | head -20)

    if [[ ${#search_results[@]} -eq 0 ]]; then
        warn "No matches for '$search_term'"
        add_more=$(ask_choice "Search for more?" "Yes" "No, continue")
        continue
    fi

    echo "" >&2
    echo -e "  ${CYAN}Found ${#search_results[@]} match(es):${RESET}" >&2
    for i in "${!search_results[@]}"; do
        echo -e "    ${BOLD}$((i+1)).${RESET} ${search_results[$i]}" >&2
    done
    echo "" >&2

    echo -ne "  ${DIM}Enter numbers to exclude (comma-separated), or 'skip'${RESET}: " >&2
    read -r pick_input

    if [[ "$pick_input" != "skip" && -n "$pick_input" ]]; then
        IFS=',' read -ra picks <<< "$pick_input"
        for pick in "${picks[@]}"; do
            pick=$(echo "$pick" | tr -d ' ')
            if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 )); then
                idx=$((pick - 1))
                if (( idx < ${#search_results[@]} )); then
                    entry="${search_results[$idx]}"
                    full_entry="$projects_path/$entry"

                    # Check if it's a directory (tmpfs only works on dirs)
                    if [[ -d "$full_entry" ]]; then
                        level=$(ask_choice "Protection level for '$entry'?" \
                            "Soft (.claudeignore only)" \
                            "Hard (tmpfs overlay — physically hidden)")
                    else
                        dim "    '$entry' is a file — only soft exclusion available"
                        level="1"
                    fi

                    claudeignore_entries+=("$entry")
                    if [[ "$level" == "2" ]]; then
                        overlay_entries+=("$entry")
                    fi
                    success "Added: $entry"
                fi
            fi
        done
    fi

    add_more=$(ask_choice "Search for more?" "Yes" "No, continue")
done

# ── 4c. Deduplicate and generate exclusion files ───────────────────────────
# Remove duplicate entries
declare -A seen_ignore seen_overlay
unique_claudeignore=()
unique_overlay=()
for entry in "${claudeignore_entries[@]}"; do
    if [[ -z "${seen_ignore[$entry]+x}" ]]; then
        seen_ignore[$entry]=1
        unique_claudeignore+=("$entry")
    fi
done
for entry in "${overlay_entries[@]}"; do
    if [[ -z "${seen_overlay[$entry]+x}" ]]; then
        seen_overlay[$entry]=1
        unique_overlay+=("$entry")
    fi
done

if [[ ${#unique_claudeignore[@]} -gt 0 ]]; then
    claudeignore_file="$projects_path/.claudeignore"
    # Preserve existing entries if file exists
    existing_entries=()
    if [[ -f "$claudeignore_file" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            existing_entries+=("$line")
        done < "$claudeignore_file"
    fi
    {
        echo "# Managed by claudebox setup.sh"
        echo "# Paths excluded from Claude Code search/read"
        # Write existing entries that aren't in our new list
        for existing in "${existing_entries[@]}"; do
            if [[ -z "${seen_ignore[$existing]+x}" ]]; then
                echo "$existing"
            fi
        done
        # Write new entries
        for entry in "${unique_claudeignore[@]}"; do
            echo "$entry"
        done
    } > "$claudeignore_file"
    success "Updated $claudeignore_file (${#unique_claudeignore[@]} new entries)"
fi

if [[ ${#unique_overlay[@]} -gt 0 ]]; then
    override_file="$SCRIPT_DIR/docker-compose.override.yml"
    # Backup existing override before overwriting
    if [[ -f "$override_file" ]]; then
        backup="${override_file}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$override_file" "$backup"
        warn "docker-compose.override.yml backed up to $(basename "$backup")"
    fi
    {
        echo "# Generated by claudebox setup.sh"
        echo "# tmpfs overlays to physically hide sensitive directories"
        echo "services:"
        echo "  claudebox:"
        echo "    volumes:"
        for entry in "${unique_overlay[@]}"; do
            echo "      - type: tmpfs"
            echo "        target: /home/claude/projects/${entry}"
        done
    } > "$override_file"
    success "Created docker-compose.override.yml with ${#unique_overlay[@]} tmpfs overlay(s)"
fi

if [[ ${#claudeignore_entries[@]} -eq 0 ]]; then
    dim "  No exclusions configured. You can add them later:"
    dim "    Soft: create .claudeignore in your project"
    dim "    Hard: add tmpfs volumes to docker-compose.override.yml"
fi

# ─── Step 5: Build & Launch ──────────────────────────────────────────────────
header "[5/5] Build & Launch"
echo ""

choice=$(ask_choice "Ready to build and start the container?" \
    "Build and start now" \
    "Just build (don't start)" \
    "Skip (I'll do it manually)")

if [[ "$choice" == "1" || "$choice" == "2" ]]; then
    echo ""
    info "Building Docker image (this may take a few minutes on first run)..."
    echo ""

    # Run from SCRIPT_DIR so compose auto-picks up docker-compose.override.yml
    if ! (cd "$SCRIPT_DIR" && "${COMPOSE[@]}" build); then
        error "Build failed. Check the output above for details."
        exit 1
    fi
    success "Image built successfully"

    if [[ "$choice" == "1" ]]; then
        echo ""
        info "Starting container..."

        if ! (cd "$SCRIPT_DIR" && "${COMPOSE[@]}" up -d); then
            error "Failed to start. Check: cd $SCRIPT_DIR && ${COMPOSE[*]} logs"
            exit 1
        fi

        success "Container is running!"
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        echo -e "  ${GREEN}${BOLD}To enter the container:${RESET}"
        echo -e "  ${CYAN}${COMPOSE[*]} exec claudebox bash${RESET}"
        echo ""
        echo -e "  ${GREEN}${BOLD}Inside the container:${RESET}"
        echo -e "  ${CYAN}claude-safe${RESET}  — start Claude Code (with API key)"
        echo -e "  ${CYAN}health-check${RESET}  — check VPN & API status"
        echo ""
        echo -e "  ${GREEN}${BOLD}Your projects are at:${RESET} /home/claude/projects"
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    fi
else
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${GREEN}${BOLD}When you're ready:${RESET}"
    echo -e "  ${CYAN}cd $(basename "$SCRIPT_DIR") && ${COMPOSE[*]} build${RESET}"
    echo -e "  ${CYAN}${COMPOSE[*]} up -d${RESET}"
    echo -e "  ${CYAN}${COMPOSE[*]} exec claudebox bash${RESET}"
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
fi
