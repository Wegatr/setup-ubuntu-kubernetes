#!/usr/bin/env bash
#
# check-env-drift.sh — structural drift guard for the three per-env GitOps
# trees (argocd/{dev,test,prod}).
#
# The three trees are intentionally near-copies (dev additionally carries the
# build plane: tekton / registry / image-builder, the `cicd` AppProject and
# tenants.yaml). Because they are maintained by hand, structural drift can
# creep in silently — a sync option added on dev but forgotten on prod, a
# project destination widened in one env only, etc. This script compares the
# trees STRUCTURALLY (comments stripped via yq round-trip, env names
# normalized) and fails when anything but the documented dev-only extras
# differs.
#
# Checks:
#   1. applicationset.yaml: TEST and PROD must be identical (modulo env name).
#   2. applicationset.yaml: template/templatePatch/syncPolicy of DEV must be
#      identical to TEST; every app present in TEST must have a deep-equal
#      element in DEV. Apps only in DEV are reported as info (expected:
#      tekton, registry, image-builder).
#   3. projects.yaml: TEST and PROD identical; every project present in TEST
#      deep-equal in DEV. Projects only in DEV are info (expected: cicd).
#   4. root-app.yaml: all three identical (modulo the per-env path).
#
# Comments are NOT compared (yq drops them) — keeping the rich docs on dev
# and shorter ones on test/prod stays legal.
#
# Usage: ./check-env-drift.sh            (or: bash check-env-drift.sh)
# Exit:  0 = no drift, 1 = drift found, 2 = missing prerequisites.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq (mikefarah v4) is required" >&2; exit 2; }

fail() { echo "DRIFT: $*" >&2; FAILURES=$((FAILURES + 1)); }
info() { echo "info:  $*"; }
ok()   { echo "ok:    $*"; }

# Re-emit a YAML file as canonical JSON (drops comments + formatting) and
# replace the env-specific tokens with a placeholder so envs are comparable.
# Tokens are matched EXACTLY (no \b word-boundary games — "tekton.dev" and
# "zot.dev.<domain>" must never be touched).
normalize() {
    local env="$1" file="$2"
    yq -o=json '.' "$file" | sed \
        -e "s/platform-apps-${env}/platform-apps-ENV/g" \
        -e "s/values-${env}\.yaml/values-ENV.yaml/g" \
        -e "s/{{ \.name }}-${env}/{{ .name }}-ENV/g" \
        -e "s|argocd/${env}/apps|argocd/ENV/apps|g"
}

# Same, but for one element of the AppSet generator list.
element_of() {
    local file="$1" app="$2"
    yq -o=json ".spec.generators[0].list.elements[] | select(.name == \"${app}\")" "$file"
}

# Same, but for one named document of a multi-doc file (projects.yaml).
doc_of() {
    local file="$1" name="$2"
    yq -o=json "select(.metadata.name == \"${name}\")" "$file"
}

diff_or_fail() {
    local label="$1" left="$2" right="$3"
    if ! diff -u <(printf '%s\n' "$left") <(printf '%s\n' "$right") >/tmp/drift-diff.$$ 2>&1; then
        fail "$label"
        sed 's/^/         /' /tmp/drift-diff.$$ >&2
    fi
    rm -f /tmp/drift-diff.$$
}

# ----------------------------------------------------------------------------
# 1+2. applicationset.yaml
# ----------------------------------------------------------------------------
APPSET_DEV="$SCRIPT_DIR/dev/apps/applicationset.yaml"
APPSET_TEST="$SCRIPT_DIR/test/apps/applicationset.yaml"
APPSET_PROD="$SCRIPT_DIR/prod/apps/applicationset.yaml"

# TEST vs PROD: byte-identical after normalization.
diff_or_fail "applicationset.yaml: TEST and PROD differ structurally" \
    "$(normalize test "$APPSET_TEST")" "$(normalize prod "$APPSET_PROD")"

# DEV vs TEST: everything except the generator element list must match.
diff_or_fail "applicationset.yaml: DEV template/templatePatch/policies differ from TEST" \
    "$(normalize dev "$APPSET_DEV" | yq -o=json 'del(.spec.generators)')" \
    "$(normalize test "$APPSET_TEST" | yq -o=json 'del(.spec.generators)')"

# Per-app elements: every TEST app must exist in DEV with identical fields.
mapfile -t TEST_APPS < <(yq -r '.spec.generators[0].list.elements[].name' "$APPSET_TEST")
mapfile -t DEV_APPS  < <(yq -r '.spec.generators[0].list.elements[].name' "$APPSET_DEV")

for app in "${TEST_APPS[@]}"; do
    dev_el="$(element_of "$APPSET_DEV" "$app")"
    if [[ -z "$dev_el" ]]; then
        fail "applicationset.yaml: app '$app' exists in TEST but not in DEV"
        continue
    fi
    diff_or_fail "applicationset.yaml: element '$app' differs between DEV and TEST" \
        "$dev_el" "$(element_of "$APPSET_TEST" "$app")"
done

for app in "${DEV_APPS[@]}"; do
    if ! printf '%s\n' "${TEST_APPS[@]}" | grep -qx -e "$app"; then
        info "app '$app' is DEV-only (expected for the build plane: tekton / registry / image-builder)"
    fi
done

# ----------------------------------------------------------------------------
# 3. projects.yaml
# ----------------------------------------------------------------------------
PROJ_DEV="$SCRIPT_DIR/dev/apps/projects.yaml"
PROJ_TEST="$SCRIPT_DIR/test/apps/projects.yaml"
PROJ_PROD="$SCRIPT_DIR/prod/apps/projects.yaml"

diff_or_fail "projects.yaml: TEST and PROD differ structurally" \
    "$(normalize test "$PROJ_TEST")" "$(normalize prod "$PROJ_PROD")"

# sed: yq prints `---` separators between documents of a multi-doc file —
# drop them so they don't masquerade as project names.
mapfile -t TEST_PROJECTS < <(yq -r '.metadata.name' "$PROJ_TEST" | sed '/^---$/d')
mapfile -t DEV_PROJECTS  < <(yq -r '.metadata.name' "$PROJ_DEV" | sed '/^---$/d')

for proj in "${TEST_PROJECTS[@]}"; do
    dev_doc="$(doc_of "$PROJ_DEV" "$proj")"
    if [[ -z "$dev_doc" ]]; then
        fail "projects.yaml: project '$proj' exists in TEST but not in DEV"
        continue
    fi
    diff_or_fail "projects.yaml: project '$proj' differs between DEV and TEST" \
        "$dev_doc" "$(doc_of "$PROJ_TEST" "$proj")"
done

for proj in "${DEV_PROJECTS[@]}"; do
    if ! printf '%s\n' "${TEST_PROJECTS[@]}" | grep -qx -e "$proj"; then
        info "project '$proj' is DEV-only (expected: cicd — build plane runs on DEV only)"
    fi
done

if [[ -f "$SCRIPT_DIR/dev/apps/tenants.yaml" ]]; then
    info "tenants.yaml is DEV-only by design — not compared"
fi

# ----------------------------------------------------------------------------
# 4. root-app.yaml
# ----------------------------------------------------------------------------
diff_or_fail "root-app.yaml: TEST and PROD differ" \
    "$(normalize test "$SCRIPT_DIR/test/root-app.yaml")" \
    "$(normalize prod "$SCRIPT_DIR/prod/root-app.yaml")"
diff_or_fail "root-app.yaml: DEV and TEST differ" \
    "$(normalize dev "$SCRIPT_DIR/dev/root-app.yaml")" \
    "$(normalize test "$SCRIPT_DIR/test/root-app.yaml")"

# ----------------------------------------------------------------------------
echo
if [[ $FAILURES -gt 0 ]]; then
    echo "RESULT: $FAILURES structural difference(s) found between the env trees." >&2
    echo "        If a difference is INTENDED, make it symmetrical or document it here." >&2
    exit 1
fi
ok "no structural drift between argocd/{dev,test,prod}"
exit 0
