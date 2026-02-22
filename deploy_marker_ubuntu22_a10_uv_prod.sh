#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

CONVERT_AFTER_DEPLOY=0
PDF_PATH=""
OUT_DIR="converted_full_gpu"
PDFTEXT_WORKERS="8"
PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
FORCE_RECREATE_VENV=0
RETRY_COUNT="3"
RETRY_WAIT_SECONDS="30"
RESUME_CONVERSION=1
LOG_DIR="logs"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOCK_FILE=".deploy_marker.lock"

usage() {
  cat <<'EOF'
Usage:
  ./deploy_marker_ubuntu22_a10_uv_prod.sh [options]

Options:
  --convert <pdf_path>        Deploy and convert this PDF after setup.
  --out <output_dir>          Conversion output directory (default: converted_full_gpu).
  --pdftext-workers <n>       marker_single --pdftext_workers value (default: 8).
  --python <version>          Python version for uv venv (default: 3.10).
  --force-recreate-venv       Remove and recreate existing .venv.
  --retry <n>                 Conversion retry attempts on failure (default: 3).
  --retry-wait <seconds>      Wait time between retries (default: 30).
  --no-resume                 Always run conversion even if output already exists.
  --log-dir <dir>             Log directory (default: logs).
  --run-id <id>               Custom run id for log/state file names.
  -h, --help                  Show this help.

Environment overrides:
  PYTORCH_CUDA_INDEX          Force torch CUDA wheel index, e.g. cu124/cu126.
  PYTHON_VERSION              Same as --python.

Examples:
  ./deploy_marker_ubuntu22_a10_uv_prod.sh
  ./deploy_marker_ubuntu22_a10_uv_prod.sh --convert ./2404.17625v3.pdf --out ./converted_full_gpu_mp --pdftext-workers 8
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --convert)
      CONVERT_AFTER_DEPLOY=1
      PDF_PATH="${2:-}"
      shift 2
      ;;
    --out)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --pdftext-workers)
      PDFTEXT_WORKERS="${2:-}"
      shift 2
      ;;
    --python)
      PYTHON_VERSION="${2:-}"
      shift 2
      ;;
    --force-recreate-venv)
      FORCE_RECREATE_VENV=1
      shift
      ;;
    --retry)
      RETRY_COUNT="${2:-}"
      shift 2
      ;;
    --retry-wait)
      RETRY_WAIT_SECONDS="${2:-}"
      shift 2
      ;;
    --no-resume)
      RESUME_CONVERSION=0
      shift
      ;;
    --log-dir)
      LOG_DIR="${2:-}"
      shift 2
      ;;
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy_marker_${RUN_ID}.log"
STATE_FILE="$LOG_DIR/deploy_marker_${RUN_ID}.state"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Run id: $RUN_ID"
echo "[INFO] Log file: $LOG_FILE"
echo "[INFO] State file: $STATE_FILE"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "[ERROR] Another deployment/conversion run is in progress (lock: $LOCK_FILE)."
    exit 1
  fi
fi

on_error() {
  local exit_code="$1"
  local line_no="$2"
  echo "[ERROR] Script failed at line ${line_no}, exit code ${exit_code}."
  echo "failed_line=${line_no}" >> "$STATE_FILE"
  echo "exit_code=${exit_code}" >> "$STATE_FILE"
}
trap 'on_error $? $LINENO' ERR

echo "status=started" > "$STATE_FILE"
echo "timestamp=$(date -Iseconds)" >> "$STATE_FILE"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
    echo "[WARN] Target is Ubuntu 22.04, current is ${PRETTY_NAME:-unknown}. Continuing..."
  fi
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[ERROR] nvidia-smi not found. Install NVIDIA driver first."
  exit 1
fi

echo "[INFO] GPU status:"
nvidia-smi

if command -v apt-get >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    SUDO=""
  fi

  echo "[INFO] Installing system dependencies..."
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y curl git build-essential pkg-config libgl1 libglib2.0-0
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "[INFO] Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "[ERROR] uv installation failed."
  exit 1
fi

if [[ "$FORCE_RECREATE_VENV" -eq 1 && -d .venv ]]; then
  echo "[INFO] Removing existing .venv..."
  rm -rf .venv
fi

echo "[INFO] Installing Python ${PYTHON_VERSION} via uv (if needed)..."
uv python install "$PYTHON_VERSION"

if [[ ! -d .venv ]]; then
  echo "[INFO] Creating virtual environment .venv..."
  uv venv --python "$PYTHON_VERSION" .venv
fi

echo "[INFO] Installing project dependencies..."
uv pip install --python .venv -e .

CUDA_VERSION_RAW="$(nvidia-smi | awk -F 'CUDA Version: ' '/CUDA Version:/ {split($2,a," "); print a[1]; exit}')"
if [[ -z "$CUDA_VERSION_RAW" ]]; then
  echo "[ERROR] Could not detect CUDA runtime version from nvidia-smi."
  exit 1
fi

CUDA_MAJOR="${CUDA_VERSION_RAW%%.*}"
CUDA_MINOR="${CUDA_VERSION_RAW#*.}"
CUDA_MINOR="${CUDA_MINOR%%.*}"

if (( CUDA_MAJOR > 12 || (CUDA_MAJOR == 12 && CUDA_MINOR >= 6) )); then
  AUTO_CUDA_INDEX="cu126"
elif (( CUDA_MAJOR == 12 && CUDA_MINOR >= 4 )); then
  AUTO_CUDA_INDEX="cu124"
elif (( CUDA_MAJOR == 12 && CUDA_MINOR >= 1 )); then
  AUTO_CUDA_INDEX="cu121"
else
  AUTO_CUDA_INDEX="cu118"
fi

CUDA_INDEX="${PYTORCH_CUDA_INDEX:-$AUTO_CUDA_INDEX}"
echo "[INFO] Installing GPU torch from index ${CUDA_INDEX} (detected CUDA ${CUDA_VERSION_RAW})..."
uv pip install --python .venv --reinstall torch --index-url "https://download.pytorch.org/whl/${CUDA_INDEX}"

echo "[INFO] Verifying torch CUDA backend..."
uv run --python .venv python - <<'PY'
import sys
import torch

msg = {
    "torch": torch.__version__,
    "torch_cuda": torch.version.cuda,
    "cuda_available": torch.cuda.is_available(),
    "device_count": torch.cuda.device_count(),
}
print(msg)

if not torch.cuda.is_available():
    sys.exit("[ERROR] torch.cuda.is_available() is False.")

print(torch.cuda.get_device_name(0))
PY

echo "[INFO] marker_single smoke check..."
uv run --python .venv marker_single --help >/dev/null
echo "status=deploy_ok" >> "$STATE_FILE"

run_conversion_once() {
  TORCH_DEVICE=cuda uv run --python .venv marker_single "$PDF_PATH" \
    --output_format markdown \
    --output_dir "$OUT_DIR" \
    --pdftext_workers "$PDFTEXT_WORKERS"
}

if [[ "$CONVERT_AFTER_DEPLOY" -eq 1 ]]; then
  if [[ -z "$PDF_PATH" || ! -f "$PDF_PATH" ]]; then
    echo "[ERROR] --convert requires an existing PDF path. Got: ${PDF_PATH:-<empty>}"
    exit 1
  fi

  PDF_BASENAME="$(basename "$PDF_PATH")"
  PDF_STEM="${PDF_BASENAME%.*}"
  EXPECTED_MD_PATH="$OUT_DIR/$PDF_STEM/$PDF_STEM.md"

  if [[ "$RESUME_CONVERSION" -eq 1 && -s "$EXPECTED_MD_PATH" ]]; then
    echo "[INFO] Resume enabled and output already exists: $EXPECTED_MD_PATH"
    echo "status=convert_skipped_existing" >> "$STATE_FILE"
  else
    attempt=1
    while true; do
      echo "[INFO] Conversion attempt ${attempt}/${RETRY_COUNT}..."
      if run_conversion_once; then
        echo "[INFO] Conversion succeeded."
        break
      fi

      if [[ "$attempt" -ge "$RETRY_COUNT" ]]; then
        echo "[ERROR] Conversion failed after ${RETRY_COUNT} attempts."
        exit 1
      fi

      echo "[WARN] Conversion failed. Retrying after ${RETRY_WAIT_SECONDS}s..."
      sleep "$RETRY_WAIT_SECONDS"
      attempt=$((attempt + 1))
    done
  fi

  if [[ ! -s "$EXPECTED_MD_PATH" ]]; then
    echo "[ERROR] Expected markdown output not found: $EXPECTED_MD_PATH"
    exit 1
  fi

  echo "status=convert_ok" >> "$STATE_FILE"
  echo "output_markdown=$EXPECTED_MD_PATH" >> "$STATE_FILE"
fi

echo "status=done" >> "$STATE_FILE"
echo "finished_at=$(date -Iseconds)" >> "$STATE_FILE"

cat <<EOF
[DONE] Deployment complete.

Activate environment:
  source .venv/bin/activate

Full conversion command:
  TORCH_DEVICE=cuda uv run --python .venv marker_single "<your.pdf>" --output_format markdown --output_dir "converted_full_gpu" --pdftext_workers 8

Production script with conversion + retry + logs:
  ./deploy_marker_ubuntu22_a10_uv_prod.sh --convert "<your.pdf>" --out "converted_full_gpu" --pdftext-workers 8 --retry 3 --retry-wait 30
EOF
