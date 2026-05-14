#!/usr/bin/env bash
#
# argo-manage.sh — menu-driven ArgoCD GitOps bootstrap + management.
#
# Lives in argocd/. Operates on the GitOps tree in this repo:
#   argocd/<env>/root-app.yaml              (kubectl-applied once to bootstrap)
#   argocd/<env>/apps/applicationset.yaml   (the AppSet that generates Applications)
#   apps/<name>/                            (per-app umbrella charts)
#
# Features (all reachable from the main menu):
#   • Bootstrap a per-env root-app (idempotent kubectl apply with health probe).
#   • Per-app enable / disable (durable: edits the ApplicationSet element list
#     with backup + diff + optional commit + push).
#   • Per-app pause / unpause (instant: ArgoCD skip-reconcile annotation on
#     the generated Application — survives until next AppSet reconcile, so
#     paired with element-flag for durability).
#   • Toggle auto-sync globally (edits the templatePatch under spec).
#   • Per-app status (health, sync state, pod readiness, recent events).
#   • Per-app sync / refresh / hard-refresh.
#   • Settings: env selection, repoURL placeholder replacement.
#
# Defensive design:
#   • Detects color/Unicode terminal support; degrades to ASCII on dumb terms.
#   • Validates every prerequisite (kubectl, yq, jq, file existence, cluster
#     reachability) before any mutating action.
#   • Backs up YAML before editing; shows diff; offers rollback.
#   • Trap SIGINT/SIGTERM to restore the terminal and clean up temp files.
#
# Usage: ./argo-manage.sh   (interactive)
#        ./argo-manage.sh --env dev --bootstrap   (non-interactive, scriptable)
#        ./argo-manage.sh --help

set -uo pipefail

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly TMP_DIR="$(mktemp -d -t argo-manage-XXXXXX)"
readonly BACKUP_DIR="$REPO_ROOT/argocd/.backups"

readonly SUPPORTED_ENVS=(dev test prod)
# Tokens that indicate the GitOps tree still ships the placeholder repoURL.
# Match any of these (extended regex). The repo has evolved through two
# placeholder shapes — the legacy `https://to-your-repo-folder` and the
# current `https://github.com/<github-account>/<github-repo>.git` — so we
# look for either, plus any leftover angle-bracket marker.
readonly REPO_PLACEHOLDER_REGEX='to-your-repo-folder|<github-account>|<github-repo>'
readonly BRANCH_PLACEHOLDER='master'

# ----------------------------------------------------------------------------
# Cleanup on exit (always restore terminal + remove temp files)
# ----------------------------------------------------------------------------

cleanup() {
  local rc=$?
  tput cnorm 2>/dev/null || true   # show cursor
  stty echo 2>/dev/null || true    # restore echo
  printf '\033[0m'                 # reset colors
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT
trap 'cleanup' INT TERM

# ----------------------------------------------------------------------------
# Color + glyph detection
# ----------------------------------------------------------------------------

setup_colors_and_glyphs() {
  # Honor NO_COLOR (https://no-color.org/) and non-TTY stdouts.
  if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    readonly USE_COLOR=1
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_MAGENTA=$'\033[35m'
    readonly C_CYAN=$'\033[36m'
    readonly C_WHITE=$'\033[37m'
    readonly C_BG_BLUE=$'\033[44m'
  else
    readonly USE_COLOR=0
    readonly C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
    readonly C_BLUE='' C_MAGENTA='' C_CYAN='' C_WHITE='' C_BG_BLUE=''
  fi

  # Unicode? Check LANG / LC_CTYPE for UTF-8.
  if [[ "${LANG:-}${LC_CTYPE:-}${LC_ALL:-}" =~ [Uu][Tt][Ff]-?8 ]]; then
    readonly USE_UNICODE=1
    readonly G_TL='╔' G_TR='╗' G_BL='╚' G_BR='╝' G_H='═' G_V='║'
    readonly G_TEE_L='╠' G_TEE_R='╣' G_ARROW='➜' G_CHECK='✔' G_CROSS='✘'
    readonly G_DOT='•' G_STAR='★' G_HOURGLASS='⏳' G_GEAR='⚙'
  else
    readonly USE_UNICODE=0
    readonly G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_H='-' G_V='|'
    readonly G_TEE_L='+' G_TEE_R='+' G_ARROW='>' G_CHECK='OK' G_CROSS='X'
    readonly G_DOT='*' G_STAR='*' G_HOURGLASS='...' G_GEAR='*'
  fi
}

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

log_info()    { printf '%b%s %b%s%b\n' "$C_BLUE"   "$G_DOT"   "$C_RESET" "$*" "$C_RESET" >&2; }
log_warn()    { printf '%b%s %b%s%b\n' "$C_YELLOW" "!"        "$C_RESET" "$*" "$C_RESET" >&2; }
log_error()   { printf '%b%s %b%s%b\n' "$C_RED"    "$G_CROSS" "$C_RESET" "$*" "$C_RESET" >&2; }
log_success() { printf '%b%s %b%s%b\n' "$C_GREEN"  "$G_CHECK" "$C_RESET" "$*" "$C_RESET" >&2; }

# ----------------------------------------------------------------------------
# Terminal UI primitives
# ----------------------------------------------------------------------------

term_width() { tput cols 2>/dev/null || echo 80; }
clear_screen() { tput clear 2>/dev/null || printf '\033[2J\033[H'; }
hide_cursor() { tput civis 2>/dev/null || true; }
show_cursor() { tput cnorm 2>/dev/null || true; }

# repeat_str <char> <count>
repeat_str() {
  local s=""
  local i
  for ((i = 0; i < $2; i++)); do s+="$1"; done
  printf '%s' "$s"
}

# draw_header <title>
draw_header() {
  local title="$1"
  local width
  width=$(term_width)
  (( width > 100 )) && width=100
  local inner=$((width - 2))
  local pad=$(( (inner - ${#title} - 2) / 2 ))
  (( pad < 0 )) && pad=0

  printf '%b' "$C_BLUE"
  printf '%s' "$G_TL"; repeat_str "$G_H" "$inner"; printf '%s\n' "$G_TR"
  printf '%s%b' "$G_V" "$C_RESET"
  printf '%b%*s%b%s%b%*s%b' \
    "$C_BG_BLUE$C_BOLD$C_WHITE" "$pad" "" "$C_RESET$C_BG_BLUE$C_BOLD$C_WHITE" " $title " \
    "$C_RESET$C_BG_BLUE$C_WHITE" "$(( inner - pad - ${#title} - 2 ))" "" "$C_RESET"
  printf '%b%s%b\n' "$C_BLUE" "$G_V" "$C_RESET"
  printf '%b%s' "$C_BLUE" "$G_TEE_L"; repeat_str "$G_H" "$inner"; printf '%s%b\n' "$G_TEE_R" "$C_RESET"
}

# draw_footer <hint>
draw_footer() {
  local hint="$1"
  local width
  width=$(term_width)
  (( width > 100 )) && width=100
  local inner=$((width - 2))

  printf '%b%s' "$C_BLUE" "$G_TEE_L"; repeat_str "$G_H" "$inner"; printf '%s\n' "$G_TEE_R"
  printf '%s%b %b%-*s%b%b %s%b\n' \
    "$G_V" "$C_RESET" "$C_DIM" "$((inner - 2))" "$hint" "$C_RESET" "$C_BLUE" "$G_V" "$C_RESET"
  printf '%b%s' "$C_BLUE" "$G_BL"; repeat_str "$G_H" "$inner"; printf '%s%b\n' "$G_BR" "$C_RESET"
}

# pause_for_key [message] — no-op in non-interactive mode (--bootstrap, --overview).
pause_for_key() {
  (( NONINTERACTIVE )) && return 0
  local msg="${1:-Press any key to continue}"
  printf '\n%b%s...%b ' "$C_DIM" "$msg" "$C_RESET"
  read -rsn1 _ || true
  printf '\n'
}

# confirm <prompt>  -> exit 0 if yes, 1 if no
confirm() {
  local prompt="$1"
  local answer
  while true; do
    printf '%b? %s%b [y/N]: ' "$C_YELLOW" "$prompt" "$C_RESET" >&2
    read -r answer || return 1
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no|'') return 1 ;;
      *) printf '%bPlease answer y or n.%b\n' "$C_RED" "$C_RESET" >&2 ;;
    esac
  done
}

# read_key — read a single key, normalize arrows to UP/DOWN/LEFT/RIGHT/ENTER/ESC/Q/etc.
read_key() {
  local key rest
  IFS= read -rsn1 key
  if [[ $key == $'\033' ]]; then
    IFS= read -rsn2 -t 0.01 rest || true
    case "$rest" in
      '[A') printf 'UP'     ;;
      '[B') printf 'DOWN'   ;;
      '[C') printf 'RIGHT'  ;;
      '[D') printf 'LEFT'   ;;
      '')   printf 'ESC'    ;;
      *)    printf 'ESC'    ;;
    esac
  elif [[ -z $key ]]; then
    printf 'ENTER'
  else
    printf '%s' "$key"
  fi
}

# draw_menu <title> <footer> <opt1> [opt2 ...]
# Returns selected index in $MENU_RESULT, or 255 on back (LEFT / ESC).
# 'q'/'Q' exits the script with code 0.
draw_menu() {
  local title="$1" footer="$2"
  shift 2
  local -a opts=("$@")
  local selected=0
  local key

  hide_cursor
  while true; do
    clear_screen
    draw_header "$title"

    local i
    for i in "${!opts[@]}"; do
      if (( i == selected )); then
        printf ' %b%s %s%b\n' "$C_BOLD$C_CYAN" "$G_ARROW" "${opts[$i]}" "$C_RESET"
      else
        printf '   %s\n' "${opts[$i]}"
      fi
    done

    draw_footer "$footer"

    key=$(read_key)
    case "$key" in
      UP)    (( selected = (selected - 1 + ${#opts[@]}) % ${#opts[@]} )) ;;
      DOWN)  (( selected = (selected + 1) % ${#opts[@]} )) ;;
      ENTER|RIGHT) MENU_RESULT=$selected; show_cursor; return 0 ;;
      LEFT|ESC) MENU_RESULT=255; show_cursor; return 255 ;;
      q|Q) show_cursor; exit 0 ;;
    esac
  done
}

# spinner <command> [args...] — run command, show spinner, capture output to $TMP_DIR/spin.out
spinner() {
  local frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
  (( USE_UNICODE == 0 )) && frames=( '|' '/' '-' '\' )
  local msg="$1"; shift

  ( "$@" >"$TMP_DIR/spin.out" 2>&1 ) &
  local pid=$!
  local i=0
  hide_cursor
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%b%s%b %s ' "$C_CYAN" "${frames[i % ${#frames[@]}]}" "$C_RESET" "$msg"
    sleep 0.08
    (( i++ ))
  done
  wait "$pid"
  local rc=$?
  printf '\r%*s\r' "$(( ${#msg} + 4 ))" ''
  show_cursor
  return $rc
}

# ----------------------------------------------------------------------------
# Prerequisite checks
# ----------------------------------------------------------------------------

# require_cmd <command> [hint]
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    [[ -n "${2:-}" ]] && log_error "Hint: $2"
    return 1
  fi
}

# setup_kubectl_fallback — on hosts where the user runs `kubectl` via a
# shell alias (e.g. `alias kubectl='microk8s.kubectl'` in ~/.bashrc), the
# standalone binary isn't on PATH and `command -v kubectl` fails inside this
# script. Detect that case and define a `kubectl` shell function that fans
# the call out to `microk8s kubectl`. The function shadows the (absent)
# binary for the rest of the run, so every existing `kubectl …` call (and
# the `require_cmd kubectl` probe below) works unchanged.
#
# Idempotent: no-op if a real `kubectl` binary is already on PATH.
setup_kubectl_fallback() {
  if command -v kubectl >/dev/null 2>&1; then
    return 0
  fi
  if command -v microk8s >/dev/null 2>&1 && microk8s kubectl version --client --request-timeout=3s >/dev/null 2>&1; then
    kubectl() { microk8s kubectl "$@"; }
    export -f kubectl
    log_info "Using 'microk8s kubectl' (no standalone kubectl on PATH)."
    return 0
  fi
  return 1
}

check_prerequisites() {
  setup_kubectl_fallback || true
  local missing=0
  require_cmd kubectl "Install: snap install kubectl --classic   OR   apt install kubectl   OR   ensure 'microk8s' is on PATH" || ((missing++))
  require_cmd yq      "Install: snap install yq    OR    wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x /usr/local/bin/yq" || ((missing++))
  require_cmd jq      "Install: apt install jq    OR    snap install jq" || ((missing++))
  (( missing > 0 )) && return 1

  # yq must be the mikefarah Go version (we use its `eval` syntax)
  if ! yq --version 2>&1 | grep -qi 'mikefarah\|go'; then
    log_warn "Detected yq does not look like mikefarah/yq. Some edits may fail."
    log_warn "If you have python-yq, install the Go version: https://github.com/mikefarah/yq"
  fi

  mkdir -p "$BACKUP_DIR"
  return 0
}

check_cluster() {
  if ! kubectl version --request-timeout=3s >/dev/null 2>&1; then
    log_error "kubectl can't reach the cluster (timeout / not configured)."
    log_error "Try: microk8s config > ~/.kube/config   OR   kubectl config use-context <name>"
    return 1
  fi
  if ! kubectl get ns argocd >/dev/null 2>&1; then
    log_error "Namespace 'argocd' not found. Has setup-kubernetes.sh --deploy-argocd run?"
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Environment selection
# ----------------------------------------------------------------------------

ENV=""             # set by select_env / --env flag
NONINTERACTIVE=0   # set to 1 by --bootstrap / --overview args

env_dir() { echo "$REPO_ROOT/argocd/$ENV"; }
root_app_file() { echo "$(env_dir)/root-app.yaml"; }
appset_file() { echo "$(env_dir)/apps/applicationset.yaml"; }

select_env() {
  local -a opts=()
  local e
  for e in "${SUPPORTED_ENVS[@]}"; do
    if [[ -f "$REPO_ROOT/argocd/$e/root-app.yaml" ]]; then
      opts+=("$e   ($G_CHECK files present)")
    else
      opts+=("$e   ($C_DIM no manifests$C_RESET)")
    fi
  done

  draw_menu "Select environment" "Pick the env to manage. Use ↑↓, Enter, Esc/← back, q quit." "${opts[@]}" || return 255
  ENV="${SUPPORTED_ENVS[$MENU_RESULT]}"
  if [[ ! -f $(root_app_file) ]]; then
    log_error "No manifests for env '$ENV' at $(env_dir)"
    pause_for_key
    return 255
  fi
  log_success "Env set to: $ENV"
}

# ----------------------------------------------------------------------------
# Bootstrap operations
# ----------------------------------------------------------------------------

# Detect: is root-app already applied in cluster?
is_root_app_applied() {
  kubectl -n argocd get application root-applications >/dev/null 2>&1
}

action_bootstrap() {
  clear_screen
  draw_header "Bootstrap — apply argocd/$ENV/root-app.yaml"

  if [[ ! -f $(root_app_file) ]]; then
    log_error "Missing $(root_app_file)"
    pause_for_key; return
  fi

  # Detect placeholder + offer to substitute.
  if grep -Eq "$REPO_PLACEHOLDER_REGEX" "$(root_app_file)" 2>/dev/null; then
    log_warn "root-app.yaml still contains the repoURL placeholder."
    log_warn "ArgoCD won't be able to pull manifests until that's replaced."
    if confirm "Substitute repoURL + branch now (across argocd/$ENV/)?"; then
      action_set_repo_url || return
    else
      log_warn "Bootstrap will create an Application that ArgoCD cannot sync until fixed."
      confirm "Proceed anyway?" || return
    fi
  fi

  if is_root_app_applied; then
    log_info "root-applications Application already exists in cluster. Re-apply (refresh)?"
    confirm "Apply again?" || return
  fi

  echo
  log_info "Applying $(root_app_file) ..."
  if kubectl apply -f "$(root_app_file)"; then
    log_success "Bootstrap applied."
    echo
    # Wait up to 30s for the AppSet controller to materialize the per-env
    # ApplicationSet. Break out as soon as it appears — previously this loop
    # just slept the full window regardless of state.
    log_info "Waiting up to 30s for ApplicationSet 'platform-apps-$ENV' to appear..."
    local i appset_ready=0
    for i in {1..30}; do
      if kubectl -n argocd get applicationset "platform-apps-$ENV" >/dev/null 2>&1; then
        appset_ready=1
        break
      fi
      sleep 1
    done
    if (( appset_ready )); then
      log_success "ApplicationSet present after ${i}s."
    else
      log_warn "ApplicationSet did not appear within 30s — root-app may still be syncing."
    fi
    # Show downstream resources the root-app created.
    log_info "ApplicationSets in argocd ns:"
    kubectl -n argocd get applicationsets 2>/dev/null | sed 's/^/  /' || log_warn "  (none yet — ApplicationSet controller may need a few more seconds)"
    log_info "Applications in argocd ns:"
    kubectl -n argocd get applications 2>/dev/null | sed 's/^/  /' || log_warn "  (none yet)"
  else
    log_error "kubectl apply failed."
  fi

  pause_for_key
}

# ----------------------------------------------------------------------------
# Settings: set the repoURL + branch placeholders to real values
# ----------------------------------------------------------------------------

action_set_repo_url() {
  clear_screen
  draw_header "Settings — replace repoURL + targetRevision placeholders"

  # Detect current values
  local current_repo current_branch
  current_repo=$(grep -h 'repoURL:' "$(env_dir)"/*.yaml "$(env_dir)/apps"/*.yaml 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '"' )
  current_branch=$(grep -h 'targetRevision:' "$(env_dir)"/*.yaml "$(env_dir)/apps"/*.yaml 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '"')

  log_info "Current repoURL:        $current_repo"
  log_info "Current targetRevision: $current_branch"
  echo

  local new_repo new_branch
  printf '%bNew repoURL (or blank to keep): %b' "$C_CYAN" "$C_RESET"
  read -r new_repo || return
  printf '%bNew targetRevision/branch (or blank to keep): %b' "$C_CYAN" "$C_RESET"
  read -r new_branch || return

  [[ -z $new_repo ]] && new_repo="$current_repo"
  [[ -z $new_branch ]] && new_branch="$current_branch"

  if [[ $new_repo == "$current_repo" ]] && [[ $new_branch == "$current_branch" ]]; then
    log_info "No changes."
    pause_for_key; return
  fi

  echo
  log_info "Files that will be edited:"
  find "$(env_dir)" -name '*.yaml' | sed 's/^/  /'
  echo

  if confirm "Proceed with substitution?"; then
    local f
    # Use NUL-terminated find output so paths with spaces are safe; and
    # restrict each sed to lines matching repoURL:/targetRevision: so we
    # never touch unrelated YAML by accident. The branch substitution uses
    # a word-boundary match so it catches both the bare form
    # (`targetRevision: master`) and the YAML-anchor form used by the
    # ApplicationSet template (`targetRevision: &branch master`).
    while IFS= read -r -d '' f; do
      cp -p "$f" "$BACKUP_DIR/$(basename "$f").$(date +%s).bak"
      sed -i \
        -e "/repoURL:/ s|$current_repo|$new_repo|g" \
        -e "/targetRevision:/ s|\\b$current_branch\\b|$new_branch|g" \
        "$f"
    done < <(find "$(env_dir)" -name '*.yaml' -print0)
    log_success "Files updated. Backups in $BACKUP_DIR/"
    echo
    log_info "Next step: commit + push so ArgoCD picks them up."
    if confirm "Commit + push now from this dir?"; then
      ( cd "$REPO_ROOT" && \
        git -c user.email='kartalbas@gmail.com' -c user.name='Mehmet Kartalbas' \
          commit -am "argocd: point at $new_repo @ $new_branch" && \
        git push ) || log_error "Git commit/push failed — fix manually."
    fi
  else
    log_info "Cancelled."
  fi
  pause_for_key
}

# ----------------------------------------------------------------------------
# Apps management — read the AppSet's element list, present each app
# ----------------------------------------------------------------------------

# Output: one line per app: <name>|<syncWave>|<namespace>|<enabled>
# mikefarah/yq's string interpolation (`"\(.x // "-")"`) errors on the `"-"`
# default with "strings cannot be subtracted". Use the array + join("|") form,
# which yq parses correctly. Missing fields become empty strings in the
# pipe-separated output (handled by `[[ -z $name ]] && continue` in callers).
list_apps() {
  if [[ ! -f $(appset_file) ]]; then
    return 1
  fi
  yq -r '.spec.generators[0].list.elements[] | [.name, .syncWave, .namespace, (.enabled // true)] | join("|")' "$(appset_file)" 2>/dev/null
}

# query live ArgoCD status for an Application: returns "<sync>|<health>"
app_status() {
  local name="$1"
  local out
  out=$(kubectl -n argocd get application "$name-$ENV" -o json 2>/dev/null) || { echo "-|-"; return; }
  local sync health
  sync=$(echo "$out" | jq -r '.status.sync.status // "-"')
  health=$(echo "$out" | jq -r '.status.health.status // "-"')
  echo "$sync|$health"
}

# Format a status pair with colors.
fmt_sync() {
  case "$1" in
    Synced)     printf '%b%s%b' "$C_GREEN"  "Synced"   "$C_RESET" ;;
    OutOfSync)  printf '%b%s%b' "$C_YELLOW" "OutOfSync" "$C_RESET" ;;
    Unknown|-)  printf '%b%s%b' "$C_DIM"    "Unknown"  "$C_RESET" ;;
    *)          printf '%s' "$1" ;;
  esac
}
fmt_health() {
  case "$1" in
    Healthy)    printf '%b%s%b' "$C_GREEN"  "Healthy"      "$C_RESET" ;;
    Progressing)printf '%b%s%b' "$C_BLUE"   "Progressing"  "$C_RESET" ;;
    Degraded)   printf '%b%s%b' "$C_RED"    "Degraded"     "$C_RESET" ;;
    Suspended)  printf '%b%s%b' "$C_YELLOW" "Suspended"    "$C_RESET" ;;
    Missing)    printf '%b%s%b' "$C_DIM"    "Missing"      "$C_RESET" ;;
    Unknown|-)  printf '%b%s%b' "$C_DIM"    "Unknown"      "$C_RESET" ;;
    *)          printf '%s' "$1" ;;
  esac
}

# Render the apps overview screen.
print_apps_overview() {
  draw_header "Apps in argocd/$ENV/apps/applicationset.yaml"

  printf '  %-18s %-5s %-22s %-9s %-12s %s\n' "NAME" "WAVE" "NAMESPACE" "ENABLED" "SYNC" "HEALTH"
  printf '  %s\n' "$(repeat_str '-' 80)"

  local line
  while IFS='|' read -r name wave ns enabled; do
    [[ -z $name ]] && continue
    local s h ; IFS='|' read -r s h <<< "$(app_status "$name")"
    local enstr
    if [[ $enabled == false ]]; then
      enstr="${C_RED}DISABLED${C_RESET}"
    else
      enstr="${C_GREEN}enabled${C_RESET}"
    fi
    printf '  %-18s %-5s %-22s %b%-9b %-21b %b\n' \
      "$name" "$wave" "$ns" "$enstr" "" "$(fmt_sync "$s")" "$(fmt_health "$h")"
  done < <(list_apps)
  echo
}

# Operate on a single app — submenu per app.
action_per_app() {
  local app="$1"
  while true; do
    clear_screen
    draw_header "App: $app  ($ENV)"

    local enabled
    enabled=$(yq -r ".spec.generators[0].list.elements[] | select(.name == \"$app\") | .enabled // true" "$(appset_file)")
    local syncwave ns
    syncwave=$(yq -r ".spec.generators[0].list.elements[] | select(.name == \"$app\") | .syncWave" "$(appset_file)")
    ns=$(yq -r ".spec.generators[0].list.elements[] | select(.name == \"$app\") | .namespace" "$(appset_file)")
    local sync health
    IFS='|' read -r sync health <<< "$(app_status "$app")"
    local paused="no"
    if kubectl -n argocd get application "$app-$ENV" -o json 2>/dev/null | jq -e '.metadata.annotations["argocd.argoproj.io/skip-reconcile"] == "true"' >/dev/null; then
      paused="yes"
    fi

    printf '  syncWave:  %s\n' "$syncwave"
    printf '  namespace: %s\n' "$ns"
    printf '  enabled:   %s\n' "$enabled"
    printf '  paused:    %s\n' "$paused"
    printf '  sync:      %b\n' "$(fmt_sync "$sync")"
    printf '  health:    %b\n' "$(fmt_health "$health")"
    echo

    local -a opts=()
    if [[ $enabled == false ]]; then
      opts+=("$G_CHECK  Enable in ApplicationSet (durable)")
    else
      opts+=("$G_CROSS  Disable in ApplicationSet (durable, prunes resources)")
    fi
    if [[ $paused == yes ]]; then
      opts+=("$G_CHECK  Resume reconciliation (remove skip-reconcile annotation)")
    else
      opts+=("$G_HOURGLASS  Pause reconciliation (set skip-reconcile annotation)")
    fi
    opts+=("$G_GEAR  Force sync now")
    opts+=("$G_GEAR  Refresh (re-fetch git)")
    opts+=("$G_GEAR  Hard refresh (drop cache + re-fetch)")
    opts+=("$G_DOT  View pods in namespace")
    opts+=("$G_DOT  View recent events")
    opts+=("$G_DOT  Tail logs of first pod")
    opts+=("← Back")

    draw_menu "App: $app" "Use ↑↓, Enter, Esc/← back, q quit." "${opts[@]}" || return
    case $MENU_RESULT in
      0) if [[ $enabled == false ]]; then toggle_app_in_appset "$app" true; else toggle_app_in_appset "$app" false; fi ;;
      1) if [[ $paused == yes ]]; then pause_app "$app" false; else pause_app "$app" true; fi ;;
      2) force_sync_app "$app" ;;
      3) refresh_app "$app" normal ;;
      4) refresh_app "$app" hard ;;
      5) view_pods "$ns" ;;
      6) view_events "$app" "$ns" ;;
      7) tail_logs "$ns" ;;
      8) return ;;
    esac
  done
}

# Edit the AppSet element list — add/remove enabled flag for one app.
# $1 = app name, $2 = true|false
toggle_app_in_appset() {
  local app="$1" new_state="$2"
  local file backup
  file=$(appset_file)
  # Capture the backup path once — the diff at the end needs to read the
  # SAME file we just wrote, not a backup with a fresh `date +%s` (which
  # would be a non-existent path and silently produce an empty diff).
  backup="$BACKUP_DIR/applicationset.yaml.$(date +%s).bak"

  cp -p "$file" "$backup"

  if [[ $new_state == true ]]; then
    # Remove the `enabled: false` field (default is enabled).
    yq -i "(.spec.generators[0].list.elements[] | select(.name == \"$app\")) |= del(.enabled)" "$file"
    log_success "Removed 'enabled: false' from $app — app re-enabled on next ArgoCD reconcile."
  else
    yq -i "(.spec.generators[0].list.elements[] | select(.name == \"$app\")) |= .enabled = false" "$file"
    log_success "Set $app.enabled = false in the ApplicationSet."
    log_warn "Note: the AppSet template still generates the Application unless you also patch the AppSet's generator filter (see Settings → Add 'enabled' filter to AppSet)."
  fi

  echo
  log_info "Diff:"
  diff -u "$backup" "$file" 2>/dev/null | sed -n '1,40p' | sed 's/^/    /' || true

  echo
  if confirm "Commit + push the change now?"; then
    ( cd "$REPO_ROOT" && \
      git -c user.email='kartalbas@gmail.com' -c user.name='Mehmet Kartalbas' \
        commit -am "argocd($ENV): toggle $app -> enabled=$new_state" && \
      git push ) || log_error "git failed — fix manually."
  fi
  pause_for_key
}

# Pause/unpause via ArgoCD skip-reconcile annotation. Note: AppSet may overwrite
# the annotation on next reconcile if it's not in the template. For durable pause,
# combine with toggle_app_in_appset disable.
pause_app() {
  local app="$1" pause="$2"
  if [[ $pause == true ]]; then
    if kubectl -n argocd annotate application "$app-$ENV" \
        argocd.argoproj.io/skip-reconcile=true --overwrite; then
      log_success "Annotated $app-$ENV with skip-reconcile=true"
    else
      log_error "Failed to annotate $app-$ENV (does the Application exist?)"
    fi
  else
    if kubectl -n argocd annotate application "$app-$ENV" \
        argocd.argoproj.io/skip-reconcile- --overwrite; then
      log_success "Removed skip-reconcile annotation from $app-$ENV"
    else
      log_error "Failed to remove annotation on $app-$ENV (does the Application exist?)"
    fi
  fi
  pause_for_key
}

force_sync_app() {
  local app="$1"
  log_info "Triggering sync for $app-$ENV ..."
  # Set sync operation via annotation (works without argocd CLI login).
  if kubectl -n argocd patch application "$app-$ENV" --type merge -p \
      '{"operation":{"initiatedBy":{"username":"argo-manage.sh"},"sync":{"revision":"HEAD"}}}'; then
    log_success "Sync triggered."
  else
    log_error "kubectl patch failed — sync NOT triggered."
  fi
  pause_for_key
}

refresh_app() {
  local app="$1" mode="$2"
  local value="normal"
  [[ $mode == hard ]] && value="hard"
  if kubectl -n argocd annotate application "$app-$ENV" \
      argocd.argoproj.io/refresh="$value" --overwrite; then
    log_success "Triggered $mode refresh for $app-$ENV."
  else
    log_error "kubectl annotate failed — refresh NOT triggered."
  fi
  pause_for_key
}

view_pods() {
  local ns="$1"
  clear_screen
  draw_header "Pods in namespace: $ns"
  kubectl -n "$ns" get pods -o wide 2>&1 | sed 's/^/  /'
  pause_for_key
}

view_events() {
  local app="$1" ns="$2"
  clear_screen
  draw_header "Recent events — Application + namespace $ns"
  echo
  printf '%bApplication events:%b\n' "$C_BOLD" "$C_RESET"
  kubectl -n argocd describe application "$app-$ENV" 2>/dev/null | sed -n '/^Events:/,$p' | sed 's/^/  /'
  echo
  printf '%bNamespace events (last 20):%b\n' "$C_BOLD" "$C_RESET"
  kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 | sed 's/^/  /'
  pause_for_key
}

tail_logs() {
  local ns="$1"
  local pod
  pod=$(kubectl -n "$ns" get pods -o name 2>/dev/null | head -1)
  if [[ -z $pod ]]; then
    log_warn "No pods in namespace $ns."
    pause_for_key; return
  fi
  clear_screen
  draw_header "Logs — $pod (Ctrl+C to stop)"
  kubectl -n "$ns" logs "$pod" --tail=100 -f 2>&1 || true
  pause_for_key "Logs ended"
}

# Apps menu — list, pick one for actions.
menu_apps() {
  while true; do
    clear_screen
    print_apps_overview

    # Build menu options
    local -a names=()
    local -a opts=()
    while IFS='|' read -r name wave ns enabled; do
      [[ -z $name ]] && continue
      names+=("$name")
      local enstr="enabled"
      [[ $enabled == false ]] && enstr="DISABLED"
      opts+=("$(printf '%-18s wave=%-3s ns=%-22s %s' "$name" "$wave" "$ns" "$enstr")")
    done < <(list_apps)
    opts+=("← Back to main menu")

    draw_menu "Apps — pick one for actions" "↑↓ to navigate, Enter to open, Esc/← back." "${opts[@]}" || return
    if (( MENU_RESULT == ${#opts[@]} - 1 )); then
      return
    fi
    action_per_app "${names[$MENU_RESULT]}"
  done
}

# ----------------------------------------------------------------------------
# Auto-sync (global) — toggles the templatePatch's automated block
# ----------------------------------------------------------------------------

action_toggle_autosync_global() {
  clear_screen
  draw_header "Global auto-sync toggle"

  local file
  file=$(appset_file)
  local has_auto
  has_auto=$(yq -r '.spec.templatePatch | contains("automated:")' "$file")

  echo
  if [[ $has_auto == true ]]; then
    log_info "Current state: auto-sync IS enabled (templatePatch contains 'automated:')."
    log_warn "Disabling will require manual sync for every app in this env."
    if confirm "Disable global auto-sync?"; then
      cp -p "$file" "$BACKUP_DIR/applicationset.yaml.$(date +%s).bak"
      # Replace `automated: { prune: …, selfHeal: true }` block with an empty
      # syncPolicy — apps stop auto-syncing on next reconcile.
      yq -i '.spec.templatePatch |= sub("(?s)automated:\\s*\\n\\s*prune:.*?selfHeal:\\s*true", "")' "$file"
      log_success "Removed 'automated:' block from templatePatch."
    else
      return
    fi
  else
    log_info "Current state: auto-sync is OFF in the templatePatch."
    if confirm "Re-enable global auto-sync?"; then
      log_error "Manual re-enable: re-add the 'automated:' block to spec.templatePatch."
      log_error "(Easier: restore the latest backup from $BACKUP_DIR/)"
      pause_for_key; return
    else
      return
    fi
  fi

  echo
  if confirm "Commit + push the AppSet change?"; then
    ( cd "$REPO_ROOT" && \
      git -c user.email='kartalbas@gmail.com' -c user.name='Mehmet Kartalbas' \
        commit -am "argocd($ENV): toggle global auto-sync" && \
      git push ) || log_error "git failed."
  fi
  pause_for_key
}

# ----------------------------------------------------------------------------
# Overview / dashboard
# ----------------------------------------------------------------------------

action_overview() {
  clear_screen
  draw_header "Overview — argocd ns + all Applications ($ENV)"
  echo
  printf '%bApplicationSet:%b\n' "$C_BOLD" "$C_RESET"
  kubectl -n argocd get applicationset "platform-apps-$ENV" -o wide 2>/dev/null | sed 's/^/  /' || log_warn "  (not yet present — bootstrap first)"
  echo
  printf '%bApplications:%b\n' "$C_BOLD" "$C_RESET"
  kubectl -n argocd get applications -o wide 2>/dev/null | sed 's/^/  /' || log_warn "  (none)"
  echo
  printf '%bPod count per namespace:%b\n' "$C_BOLD" "$C_RESET"
  local ns
  while IFS='|' read -r _ _ ns _; do
    [[ -z $ns ]] && continue
    local n
    n=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l)
    printf '  %-22s %s\n' "$ns" "$n pods"
  done < <(list_apps)
  pause_for_key
}

# ----------------------------------------------------------------------------
# Reset / cleanup
# ----------------------------------------------------------------------------

action_uninstall_one_app() {
  local -a names=()
  local -a opts=()
  local line
  while IFS='|' read -r name _ _ _; do
    [[ -z $name ]] && continue
    names+=("$name")
    opts+=("$name")
  done < <(list_apps)
  opts+=("← Back")

  draw_menu "Delete which Application? (kubectl delete — AppSet will recreate unless removed from list)" "↑↓ Enter Esc" "${opts[@]}" || return
  (( MENU_RESULT == ${#opts[@]} - 1 )) && return

  local app="${names[$MENU_RESULT]}"
  log_warn "About to: kubectl -n argocd delete application $app-$ENV"
  log_warn "This will prune the resources in namespace if prune=true (default)."
  if confirm "Proceed?"; then
    if kubectl -n argocd delete application "$app-$ENV"; then
      log_success "Deleted $app-$ENV."
      log_warn "ApplicationSet will recreate it on next reconcile. To make this durable, also disable the app in the AppSet (Apps → $app → Disable)."
    else
      log_error "kubectl delete failed — Application may still be present."
    fi
  fi
  pause_for_key
}

action_uninstall_everything() {
  clear_screen
  draw_header "DANGER — uninstall the GitOps tree from this cluster"
  echo
  log_warn "This will:"
  log_warn "  1. Delete every Application created by the ApplicationSet"
  log_warn "  2. Delete the ApplicationSet itself"
  log_warn "  3. Delete the root-applications Application"
  log_warn "  4. Prune-policy means resources in app namespaces WILL be removed"
  log_warn "It does NOT touch ArgoCD itself or your git repo."
  echo
  if ! confirm "Are you sure?"; then return; fi
  if ! confirm "REALLY sure? Type yes to confirm"; then return; fi

  log_info "Deleting Applications..."
  kubectl -n argocd delete application --all --ignore-not-found
  log_info "Deleting ApplicationSet..."
  kubectl -n argocd delete applicationset "platform-apps-$ENV" --ignore-not-found
  log_info "Deleting root-applications..."
  kubectl -n argocd delete application root-applications --ignore-not-found
  log_success "Tree removed. ArgoCD itself is untouched."
  pause_for_key
}

menu_reset() {
  while true; do
    local -a opts=(
      "$G_CROSS  Delete one Application (transient — AppSet recreates)"
      "$G_CROSS  Uninstall the entire GitOps tree (danger)"
      "← Back to main menu"
    )
    draw_menu "Reset / cleanup ($ENV)" "↑↓ Enter Esc/← back" "${opts[@]}" || return
    case $MENU_RESULT in
      0) action_uninstall_one_app ;;
      1) action_uninstall_everything ;;
      2) return ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# Settings menu
# ----------------------------------------------------------------------------

menu_settings() {
  while true; do
    local -a opts=(
      "$G_GEAR  Change environment (current: $ENV)"
      "$G_GEAR  Replace repoURL + branch placeholders (current: $(grep -h 'repoURL:' "$(env_dir)"/root-app.yaml 2>/dev/null | head -1 | awk '{print $NF}'))"
      "$G_GEAR  Toggle global auto-sync (edits AppSet templatePatch)"
      "$G_DOT  Show recent backups"
      "← Back to main menu"
    )
    draw_menu "Settings ($ENV)" "↑↓ Enter Esc/← back" "${opts[@]}" || return
    case $MENU_RESULT in
      0) select_env || true ;;
      1) action_set_repo_url ;;
      2) action_toggle_autosync_global ;;
      3) clear_screen; draw_header "Backups in $BACKUP_DIR"; ls -la "$BACKUP_DIR" 2>/dev/null | sed 's/^/  /'; pause_for_key ;;
      4) return ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# Main menu
# ----------------------------------------------------------------------------

menu_main() {
  while true; do
    local bootstrap_label
    if is_root_app_applied 2>/dev/null; then
      bootstrap_label="$G_CHECK  Bootstrap root-app (already applied — re-apply)"
    else
      bootstrap_label="$G_ARROW  Bootstrap root-app (kubectl apply)"
    fi

    local -a opts=(
      "$bootstrap_label"
      "$G_DOT  Apps — list / enable / disable / pause / sync (current env: $ENV)"
      "$G_DOT  Overview — ApplicationSet + Applications + pod counts"
      "$G_GEAR  Settings — env, repoURL, global auto-sync"
      "$G_CROSS  Reset / cleanup"
      "$G_DOT  Quit"
    )
    draw_menu "argo-manage v$SCRIPT_VERSION — ArgoCD GitOps console ($ENV)" \
              "↑↓ navigate · Enter select · Esc/← back · q quit · h help" \
              "${opts[@]}" || true
    case $MENU_RESULT in
      0) action_bootstrap ;;
      1) menu_apps ;;
      2) action_overview ;;
      3) menu_settings ;;
      4) menu_reset ;;
      5) exit 0 ;;
      255) : ;;   # ESC at top level — no-op
    esac
  done
}

# ----------------------------------------------------------------------------
# CLI args
# ----------------------------------------------------------------------------

usage() {
  cat <<EOF
argo-manage.sh v$SCRIPT_VERSION — menu-driven ArgoCD GitOps console.

  Usage:
    argo-manage.sh                          # interactive (default)
    argo-manage.sh --env <dev|test|prod>    # skip env selection
    argo-manage.sh --env <env> --bootstrap  # apply root-app non-interactively
    argo-manage.sh --env <env> --overview   # print overview and exit

  Options:
    --env <name>     Pre-select environment.
    --bootstrap      Apply argocd/<env>/root-app.yaml then exit.
    --overview       Print AppSet + Applications + pod counts then exit.
    --no-color       Disable ANSI colors.
    --version        Print version.
    --help           This message.

  Files:
    Operates on:    $REPO_ROOT/argocd/<env>/
    Backups:        $BACKUP_DIR/
    Tmp:            \$TMPDIR (auto-cleaned)

EOF
}

parse_args() {
  local non_interactive_action=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)        ENV="$2"; shift 2 ;;
      --bootstrap)  non_interactive_action="bootstrap"; shift ;;
      --overview)   non_interactive_action="overview"; shift ;;
      --no-color)   export NO_COLOR=1; shift ;;
      --version)    echo "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h)    usage; exit 0 ;;
      *)            log_error "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done

  if [[ -n $non_interactive_action ]]; then
    [[ -z $ENV ]] && { log_error "Non-interactive mode requires --env"; exit 1; }
    NONINTERACTIVE=1
    case $non_interactive_action in
      bootstrap) action_bootstrap; exit 0 ;;
      overview)  action_overview;  exit 0 ;;
    esac
  fi
}

# ----------------------------------------------------------------------------
# Entry
# ----------------------------------------------------------------------------

main() {
  setup_colors_and_glyphs

  check_prerequisites || { log_error "Missing prerequisites — see above."; exit 1; }
  check_cluster || { log_error "Cluster unreachable — see above."; exit 1; }

  parse_args "$@"

  if [[ -z $ENV ]]; then
    select_env || exit 0
  fi

  menu_main
}

main "$@"
