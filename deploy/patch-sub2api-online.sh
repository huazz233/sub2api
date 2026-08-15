#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-patch}"
REPO_URL="${REPO_URL:-https://github.com/Wei-Shaw/sub2api.git}"
REPO_REF="${REPO_REF:-main}"
CONTAINER_NAME="${CONTAINER_NAME:-sub2api}"
PLATFORM="${PLATFORM:-linux/amd64}"
IMAGE_TAG="${IMAGE_TAG:-sub2api:gpt56-sol-wm-patched}"
NODE_HEAP_MB="${NODE_HEAP_MB:-4096}"
SOURCE_PATCH_MODE="${SOURCE_PATCH_MODE:-inline}"
WORK_ROOT="${WORK_ROOT:-$HOME/sub2api-wm-patch}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/sub2api-wm-backups}"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./patch-sub2api-online.sh patch
  ./patch-sub2api-online.sh rollback

Environment overrides:
  REPO_URL       Git repository URL
  REPO_REF       Git branch or tag, default: main
  CONTAINER_NAME Running container name, default: sub2api
  PLATFORM       Docker target platform, default: linux/amd64
  IMAGE_TAG      Local image tag
  NODE_HEAP_MB   Frontend Node heap size in MB, default: 4096
  SOURCE_PATCH_MODE  inline or fork, default: inline
  WORK_ROOT      Build work directory
  BACKUP_ROOT    Host directory for rollback binaries
EOF
}

run() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

case "$MODE" in
    patch|rollback)
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

require_command docker

if [[ "$MODE" == "rollback" ]]; then
    backup_path="$BACKUP_ROOT/${CONTAINER_NAME}-last"
    [[ -f "$backup_path" ]] || die "rollback backup not found: $backup_path"
    run docker inspect "$CONTAINER_NAME" >/dev/null
    run docker cp "$backup_path" "${CONTAINER_NAME}:/tmp/sub2api"
    run docker exec -u 0 "$CONTAINER_NAME" sh -c 'chmod 755 /tmp/sub2api && mv /tmp/sub2api /app/sub2api'
    run docker restart "$CONTAINER_NAME"
    run docker exec "$CONTAINER_NAME" /app/sub2api --version
    printf 'Rollback complete.\n'
    exit 0
fi

require_command git
run docker inspect "$CONTAINER_NAME" >/dev/null
[[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" == "true" ]] || die "container is not running: $CONTAINER_NAME"

run_id="$(date -u +%Y%m%dT%H%M%SZ)"
source_dir="$WORK_ROOT/source-$run_id"
work_dir="$WORK_ROOT/run-$run_id"
artifact_path="$work_dir/sub2api"
backup_path="$BACKUP_ROOT/${CONTAINER_NAME}-${run_id}.original"
extract_name="sub2api-wm-artifact-$run_id"

mkdir -p "$work_dir" "$BACKUP_ROOT"

printf 'Cloning %s at %s...\n' "$REPO_URL" "$REPO_REF"
run git clone --depth 1 --single-branch --branch "$REPO_REF" "$REPO_URL" "$source_dir"

source_file="$source_dir/backend/internal/service/openai_codex_transform.go"
if [[ "$SOURCE_PATCH_MODE" == "fork" ]]; then
    grep -Fq 'gpt-5.6-sol-wm' "$source_file" || die "fork source does not contain the WM logic"
else
    [[ "$SOURCE_PATCH_MODE" == "inline" ]] || die "SOURCE_PATCH_MODE must be inline or fork"
    grep -Fq 'gpt-5.6-sol-wm' "$source_file" && die "WM patch is already present in the cloned source"
    return_count="$(grep -cF 'return "gpt-5.4"' "$source_file" || true)"
    [[ "$return_count" == "1" ]] || die "expected one GPT-5.4 fallback return, found: $return_count"
    mapping_line_count="$(grep -cF 'if mapped, ok := normalizeKnownCodexModel(model); ok {' "$source_file" || true)"
    [[ "$mapping_line_count" == "1" ]] || die "expected one normalizeCodexModel mapping line, found: $mapping_line_count"

    sed -i '/^[[:space:]]*if mapped, ok := normalizeKnownCodexModel(model); ok {[[:space:]]*$/i\
    // Keep the explicit WM alias for the upstream request.\
    if normalized := canonicalizeOpenAIModelAliasSpelling(model); normalized == "gpt-5.6-sol-wm" {\
        return normalized\
    }' "$source_file"
fi

dockerfile="$source_dir/deploy/Dockerfile"
node_option_count="$(grep -cE '^ENV NODE_OPTIONS=--max-old-space-size=[0-9]+$' "$dockerfile" || true)"
[[ "$node_option_count" == "1" ]] || die "expected one NODE_OPTIONS heap setting in $dockerfile"
sed -i -E "s|^(ENV NODE_OPTIONS=--max-old-space-size=)[0-9]+$|\1${NODE_HEAP_MB}|" "$dockerfile"

printf 'Building %s...\n' "$IMAGE_TAG"
run docker build \
    --platform "$PLATFORM" \
    --build-arg GOLANG_IMAGE=golang:1.26.6-alpine \
    --file "$source_dir/deploy/Dockerfile" \
    --tag "$IMAGE_TAG" \
    "$source_dir"

trap 'docker rm -f "$extract_name" >/dev/null 2>&1 || true' EXIT
run docker create --name "$extract_name" "$IMAGE_TAG"
run docker cp "${extract_name}:/app/sub2api" "$artifact_path"
run docker rm -f "$extract_name"
trap - EXIT

printf 'Backing up current binary to %s...\n' "$backup_path"
run docker cp "${CONTAINER_NAME}:/app/sub2api" "$backup_path"
ln -sfn "$backup_path" "$BACKUP_ROOT/${CONTAINER_NAME}-last"

run docker cp "$artifact_path" "${CONTAINER_NAME}:/tmp/sub2api"
run docker exec -u 0 "$CONTAINER_NAME" sh -c 'chmod 755 /tmp/sub2api && mv /tmp/sub2api /app/sub2api'
run docker restart "$CONTAINER_NAME"
run docker exec "$CONTAINER_NAME" /app/sub2api --version

printf 'Patch complete.\n'
printf 'Image: %s\n' "$IMAGE_TAG"
printf 'Backup: %s\n' "$backup_path"
printf 'Rollback: %s rollback\n' "$0"
