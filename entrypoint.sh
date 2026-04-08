#!/bin/bash
# Do NOT use set -e here — we handle errors explicitly so a non-fatal
# migration failure doesn't prevent Studio from starting.
 
# =============================================================================
# Unsloth Persistent Entrypoint
# Moves all runtime-writable Studio/Jupyter paths into /data so they can be
# safely volume-mounted on the host without clobbering build-time artifacts.
# =============================================================================
 
DATA_DIR="${UNSLOTH_DATA_DIR:-/data}"
 
CACHE_DIR="${DATA_DIR}/cache"
OUTPUTS_DIR="${DATA_DIR}/outputs"
EXPORTS_DIR="${DATA_DIR}/exports"
AUTH_DIR="${DATA_DIR}/auth"
RUNS_DIR="${DATA_DIR}/runs"
ASSETS_DIR="${DATA_DIR}/assets"
WORK_DIR="${DATA_DIR}/work"
 
echo "[unsloth-persistent] Setting up persistent data directories under ${DATA_DIR}..."
 
# Fix ownership of /data so unsloth (uid=1001) can write to it.
# Host-mounted volumes overwrite Dockerfile ownership, so we fix it at runtime.
# The entrypoint runs as root (supervisord starts as root) so chown always works.
chown -R 1001:1001 "${DATA_DIR}" 2>/dev/null \
    && echo "[unsloth-persistent] Ownership of ${DATA_DIR} set to unsloth (1001:1001)" \
    || echo "[unsloth-persistent] WARNING: Could not chown ${DATA_DIR}"
 
# -----------------------------------------------------------------------------
# link_path CONTAINER_PATH HOST_PATH
#
# Safely redirects CONTAINER_PATH → HOST_PATH via symlink.
# - Creates HOST_PATH if it doesn't exist.
# - If CONTAINER_PATH is a real directory, migrates its contents into HOST_PATH
#   first, then replaces it with a symlink.
# - Migration is skipped if HOST_PATH already has content (not empty), to avoid
#   the nested-copy bug when multiple container paths share the same HOST_PATH.
# - Failures are logged but never fatal — Studio must be allowed to start.
# -----------------------------------------------------------------------------
link_path() {
    local CONTAINER_PATH="$1"
    local HOST_PATH="$2"
 
    # Ensure the target exists
    if ! mkdir -p "${HOST_PATH}" 2>/dev/null; then
        echo "[unsloth-persistent] WARNING: Could not create ${HOST_PATH} — skipping"
        return
    fi
 
    # Already a symlink pointing somewhere — leave it alone
    if [ -L "${CONTAINER_PATH}" ]; then
        echo "[unsloth-persistent] Already linked: ${CONTAINER_PATH} (skipping)"
        return
    fi
 
    # Real directory exists: migrate contents only if HOST_PATH is empty.
    # This prevents the nested-copy bug when several container paths share
    # the same HOST_PATH (e.g. three cache locations → one target dir).
    if [ -d "${CONTAINER_PATH}" ]; then
        if [ -z "$(ls -A "${HOST_PATH}" 2>/dev/null)" ]; then
            echo "[unsloth-persistent] Migrating: ${CONTAINER_PATH} → ${HOST_PATH}"
            cp -rn "${CONTAINER_PATH}/." "${HOST_PATH}/" 2>/dev/null || \
                echo "[unsloth-persistent] WARNING: Partial migration of ${CONTAINER_PATH} (non-fatal)"
        else
            echo "[unsloth-persistent] ${HOST_PATH} already has content — skipping migration of ${CONTAINER_PATH}"
        fi
 
        # Remove the real directory so we can place the symlink.
        # Use a temp-rename approach: if rm fails (e.g. read-only parent),
        # we log and bail rather than crashing the entrypoint.
        if ! rm -rf "${CONTAINER_PATH}" 2>/dev/null; then
            echo "[unsloth-persistent] WARNING: Could not remove ${CONTAINER_PATH} — symlink skipped"
            return
        fi
    fi
 
    # Ensure parent directory exists (needed for deep paths like
    # /home/unsloth/.unsloth/studio/outputs where the parent may not exist yet)
    mkdir -p "$(dirname "${CONTAINER_PATH}")" 2>/dev/null || true
 
    if ln -s "${HOST_PATH}" "${CONTAINER_PATH}" 2>/dev/null; then
        echo "[unsloth-persistent] Linked: ${CONTAINER_PATH} → ${HOST_PATH}"
    else
        echo "[unsloth-persistent] WARNING: Could not create symlink ${CONTAINER_PATH} → ${HOST_PATH}"
    fi
}
 
# -----------------------------------------------------------------------------
# Mappings: CONTAINER_PATH → HOST_PATH
#
# Order matters here because bash processes these sequentially (unlike the
# associative array version which had undefined iteration order).
# Paths that share the same HOST_PATH are grouped together so the first one
# does the migration and the rest see a non-empty target and skip.
# -----------------------------------------------------------------------------
 
# HuggingFace model cache — three container locations, one unified target.
# Run them in order: first one migrates, the rest skip cleanly.
link_path "/workspace/.cache"        "${CACHE_DIR}/huggingface"
link_path "/workspace/studio/cache"  "${CACHE_DIR}/huggingface"
link_path "/home/unsloth/.cache"     "${CACHE_DIR}/huggingface"
 
# /workspace/studio is UNSLOTH_STUDIO_HOME — Studio writes outputs/auth/etc here.
# Symlink it entirely to /data/studio so all subdirs land on the host volume.
# We do NOT symlink /workspace/studio itself (breaks build-time artifacts),
# but we symlink each runtime-written subdir individually.
STUDIO_DIR="${DATA_DIR}/studio"
link_path "/workspace/studio/outputs" "${STUDIO_DIR}/outputs"
link_path "/workspace/studio/exports" "${STUDIO_DIR}/exports"
link_path "/workspace/studio/auth"    "${STUDIO_DIR}/auth"
link_path "/workspace/studio/runs"    "${STUDIO_DIR}/runs"
link_path "/workspace/studio/assets"  "${STUDIO_DIR}/assets"
 
# /home/unsloth/.unsloth/studio/ — a second path Studio also writes to.
# Redirect all subdirs to the same /data/studio targets so everything is unified.
link_path "/home/unsloth/.unsloth/studio/cache"   "${STUDIO_DIR}/cache"
link_path "/home/unsloth/.unsloth/studio/outputs" "${STUDIO_DIR}/outputs"
link_path "/home/unsloth/.unsloth/studio/exports" "${STUDIO_DIR}/exports"
link_path "/home/unsloth/.unsloth/studio/auth"    "${STUDIO_DIR}/auth"
link_path "/home/unsloth/.unsloth/studio/runs"    "${STUDIO_DIR}/runs"
link_path "/home/unsloth/.unsloth/studio/assets"  "${STUDIO_DIR}/assets"
 
# Jupyter workspace.
# /workspace/work may have a sticky bit or root ownership that prevents rm -rf
# even as root. If the symlink fails, we create the host dir and bind the
# content manually — Studio still has a usable /workspace/work either way.
link_path "/workspace/work" "${WORK_DIR}"
# Fallback: if /workspace/work is still a real dir (symlink skipped), at least
# make sure the host dir exists so work isn't silently lost inside the container.
if [ ! -L "/workspace/work" ] && [ -d "/workspace/work" ]; then
    echo "[unsloth-persistent] WARNING: /workspace/work could not be symlinked."
    echo "[unsloth-persistent]   Files saved there will NOT persist across container restarts."
    echo "[unsloth-persistent]   Workaround: save notebooks to /data/work manually."
fi
 
# -----------------------------------------------------------------------------
# Unified cache environment
# -----------------------------------------------------------------------------
export HF_HOME="${CACHE_DIR}/huggingface"
export TRANSFORMERS_CACHE="${CACHE_DIR}/huggingface"
export HF_DATASETS_CACHE="${CACHE_DIR}/datasets"
export TORCH_HOME="${CACHE_DIR}/torch"
 
echo "[unsloth-persistent] Environment:"
echo "  HF_HOME=${HF_HOME}"
echo "  OUTPUTS=${OUTPUTS_DIR}"
echo "  EXPORTS=${EXPORTS_DIR}"
echo "  AUTH=${AUTH_DIR}"
echo ""
 
# -----------------------------------------------------------------------------
# Diagnostics — log path states and Studio supervisor config.
# Helps identify missing paths when Studio crash-loops on startup.
# -----------------------------------------------------------------------------
echo "[unsloth-persistent] Path states:"
for CHECK_PATH in \
    "/home/unsloth/.unsloth/studio" \
    "/workspace/studio" \
    "/workspace/studio/cache" \
    "/workspace/work" \
    "/data"; do
    if [ -L "${CHECK_PATH}" ]; then
        echo "  symlink: ${CHECK_PATH} → $(readlink ${CHECK_PATH})"
    elif [ -d "${CHECK_PATH}" ]; then
        echo "  dir:     ${CHECK_PATH} (owner: $(stat -c '%U' ${CHECK_PATH} 2>/dev/null))"
    else
        echo "  MISSING: ${CHECK_PATH}"
    fi
done
 
echo "[unsloth-persistent] Studio supervisor entry:"
grep -A8 "\[program:studio\]" /etc/supervisor/conf.d/supervisord.conf 2>/dev/null \
    || find /etc/supervisor -name "*.conf" 2>/dev/null \
       | xargs grep -l "studio" 2>/dev/null \
       | xargs grep -A8 "\[program:studio\]" 2>/dev/null \
    || echo "  (studio supervisor config not found)"
 
echo ""
echo "[unsloth-persistent] Setup complete. Handing off to original entrypoint..."
 
# Hand off to the original unsloth entrypoint/command.
# Use exec so our script is fully replaced — no extra shell layer sitting
# between Docker and the Studio process, which matters for signal handling
# (SIGTERM on container stop reaches the right process).
exec "$@"
 
