#!/usr/bin/env bash
set -euo pipefail

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

info()    { echo -e "${CYAN}$1${RESET}"; }
success() { echo -e "${GREEN}✓ $1${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $1${RESET}"; }
error()   { echo -e "${RED}✗ $1${RESET}"; }
header()  { echo -e "\n${BOLD}$1${RESET}"; }
dim()     { echo -e "${DIM}$1${RESET}"; }

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
    # Strip quotes, trailing spaces, and backslash-escaped spaces
    p=$(echo "$p" | sed "s/^['\"]//;s/['\"]$//;s/ *$//;s/\\\\\\ / /g")
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

missing=()
if ! command -v docker &>/dev/null; then
    missing+=("docker")
fi
if ! docker compose version &>/dev/null 2>&1 && ! docker-compose version &>/dev/null 2>&1; then
    missing+=("docker compose")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing: ${missing[*]}"
    echo "  Install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

# Check Docker daemon is running
if ! docker info &>/dev/null 2>&1; then
    error "Docker daemon is not running. Start it and re-run this script."
    exit 1
fi

success "Docker is installed and running"

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
        secrets_dir="$SCRIPT_DIR/secrets"
        mkdir -p "$secrets_dir"
        echo -n "$api_key" > "$secrets_dir/anthropic_api_key"
        chmod 600 "$secrets_dir/anthropic_api_key"
        success "API key saved to secrets/anthropic_api_key"
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
    for key in "${!env_vars[@]}"; do
        echo "${key}=\"${env_vars[$key]}\""
    done
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# ─── Step 4: Exclude directories ────────────────────────────────────────────
header "[4/5] Exclude Directories"
echo ""
dim "  Hide directories from Claude Code inside your projects."
dim "  Two levels of protection:"
dim "    Soft  — .claudeignore: Claude Code won't search/read these paths"
dim "    Hard  — tmpfs overlay: empty dir mounted over real content (physically invisible)"
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
    done < <(find "$projects_path" -maxdepth 4 -name "$pattern" 2>/dev/null)
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
        elif [[ "$toggle_input" =~ ^[0-9]+$ ]]; then
            idx=$((toggle_input - 1))
            if [[ -n "${detected_paths[$idx]+x}" ]]; then
                if [[ "${selected[$idx]}" == "1" ]]; then
                    selected[$idx]=0
                else
                    selected[$idx]=1
                fi
            else
                error "Invalid number" >&2
            fi
        else
            error "Invalid input" >&2
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

    # Find matching paths
    search_results=()
    while IFS= read -r found_path; do
        rel="${found_path#"$projects_path"/}"
        search_results+=("$rel")
    done < <(find "$projects_path" -maxdepth 5 -iname "*${search_term}*" 2>/dev/null | head -20)

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
            if [[ "$pick" =~ ^[0-9]+$ ]]; then
                idx=$((pick - 1))
                if [[ -n "${search_results[$idx]+x}" ]]; then
                    level=$(ask_choice "Protection level for '${search_results[$idx]}'?" \
                        "Soft (.claudeignore only)" \
                        "Hard (tmpfs overlay — physically hidden)")

                    claudeignore_entries+=("${search_results[$idx]}")
                    if [[ "$level" == "2" ]]; then
                        overlay_entries+=("${search_results[$idx]}")
                    fi
                    success "Added: ${search_results[$idx]}"
                fi
            fi
        done
    fi

    add_more=$(ask_choice "Search for more?" "Yes" "No, continue")
done

# ── 4c. Generate exclusion files ────────────────────────────────────────────
if [[ ${#claudeignore_entries[@]} -gt 0 ]]; then
    claudeignore_file="$projects_path/.claudeignore"
    {
        echo "# Generated by claudebox setup.sh"
        echo "# Paths excluded from Claude Code search/read"
        for entry in "${claudeignore_entries[@]}"; do
            echo "$entry"
        done
    } > "$claudeignore_file"
    success "Created $claudeignore_file (${#claudeignore_entries[@]} entries)"
fi

if [[ ${#overlay_entries[@]} -gt 0 ]]; then
    override_file="$SCRIPT_DIR/docker-compose.override.yml"
    {
        echo "# Generated by claudebox setup.sh"
        echo "# tmpfs overlays to physically hide sensitive directories"
        echo "services:"
        echo "  claudebox:"
        echo "    volumes:"
        for entry in "${overlay_entries[@]}"; do
            echo "      - type: tmpfs"
            echo "        target: /home/claude/projects/${entry}"
        done
    } > "$override_file"
    success "Created docker-compose.override.yml with ${#overlay_entries[@]} tmpfs overlay(s)"
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

    if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" build; then
        error "Build failed. Check the output above for details."
        exit 1
    fi
    success "Image built successfully"

    if [[ "$choice" == "1" ]]; then
        echo ""
        info "Starting container..."

        if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d; then
            error "Failed to start. Check: docker compose logs"
            exit 1
        fi

        success "Container is running!"
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        echo -e "  ${GREEN}${BOLD}To enter the container:${RESET}"
        echo -e "  ${CYAN}docker compose exec claudebox bash${RESET}"
        echo ""
        echo -e "  ${GREEN}${BOLD}Inside the container:${RESET}"
        echo -e "  ${CYAN}claude${RESET}  — start Claude Code"
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
    echo -e "  ${CYAN}docker compose build${RESET}"
    echo -e "  ${CYAN}docker compose up -d${RESET}"
    echo -e "  ${CYAN}docker compose exec claudebox bash${RESET}"
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
fi
