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

usage() {
  cat <<'EOF'
Usage:
  ./deploy_marker_ubuntu22_a10_uv.sh [options]

Options:
  --convert <pdf_path>        Deploy and convert this PDF after setup.
  --out <output_dir>          Output directory for conversion (default: converted_full_gpu).
  --pdftext-workers <n>       marker_single --pdftext_workers value (default: 8).
  --python <version>          Python version for uv venv (default: 3.10).
  --force-recreate-venv       Remove existing .venv and recreate it.
  -h, --help                  Show this help.

Environment overrides:
  PYTORCH_CUDA_INDEX          Force torch CUDA wheel index, e.g. cu124/cu126.
  PYTHON_VERSION              Same as --python.

Examples:
  ./deploy_marker_ubuntu22_a10_uv.sh
  ./deploy_marker_ubuntu22_a10_uv.sh --convert ./2404.17625v3.pdf --out ./converted_full_gpu_mp --pdftext-workers 8
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

if [[ "$CONVERT_AFTER_DEPLOY" -eq 1 ]]; then
  if [[ -z "$PDF_PATH" || ! -f "$PDF_PATH" ]]; then
    echo "[ERROR] --convert requires an existing PDF path. Got: ${PDF_PATH:-<empty>}"
    exit 1
  fi

  echo "[INFO] Running full conversion with GPU + multiprocessing..."
  TORCH_DEVICE=cuda uv run --python .venv marker_single "$PDF_PATH" \
    --output_format markdown \
    --output_dir "$OUT_DIR" \
    --pdftext_workers "$PDFTEXT_WORKERS"

  echo "[INFO] Conversion done: ${OUT_DIR}"
fi

cat <<EOF
[DONE] Deployment complete.

Activate environment:
  source .venv/bin/activate

Full conversion command:
  TORCH_DEVICE=cuda uv run --python .venv marker_single "<your.pdf>" --output_format markdown --output_dir "converted_full_gpu" --pdftext_workers 8

For higher accuracy on formulas/tables (requires API key):
  TORCH_DEVICE=cuda uv run --python .venv marker_single "<your.pdf>" --output_format markdown --output_dir "converted_full_gpu_llm" --pdftext_workers 8 --use_llm --redo_inline_math
EOF
