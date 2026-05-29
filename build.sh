#!/usr/bin/env bash
set -euo pipefail

RUHMI_REPO="https://github.com/renesas/ruhmi-framework-mcu.git"
RUHMI_DIR="ruhmi-framework-mcu"
MODEL_URL="https://huggingface.co/jack-perlo/Lenet5-Mnist/resolve/main/lenet5_int8_mnist.tflite"
MODEL_FILE="models/lenet5_int8_mnist.tflite"
OUT_DIR="deploy_output"
COMPILED_DIR="lenet5_int8_mnist_NPU"

PYTHON=""

find_python() {
    if command -v python3.10 &>/dev/null; then
        PYTHON="python3.10"
    elif command -v python3 &>/dev/null; then
        PYTHON="python3"
    else
        echo "Error: Python 3.10+ is required." >&2
        exit 1
    fi
}

check_tools() {
    for cmd in git curl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: Missing required command: $cmd" >&2
            exit 1
        fi
    done
    find_python
    echo "Using Python: $PYTHON ($($PYTHON --version))"
}

install_python310() {
    echo "On Linux, please install Python 3.10 via your package manager."
    echo "  Ubuntu/Debian: sudo apt install python3.10 python3.10-venv"
    echo "  Fedora:        sudo dnf install python3.10"
    find_python
    echo "Found: $PYTHON ($($PYTHON --version))"
}

download_model() {
    check_tools
    mkdir -p "$(dirname "$MODEL_FILE")"
    if [ ! -f "$MODEL_FILE" ]; then
        echo "Downloading MNIST INT8 TFLite model..."
        curl -L -f -o "$MODEL_FILE" "$MODEL_URL"
    else
        echo "Model already exists: $MODEL_FILE"
    fi
}

download_ruhmi() {
    check_tools
    if [ ! -d "$RUHMI_DIR" ]; then
        echo "Cloning RUHMI framework..."
        git clone "$RUHMI_REPO" "$RUHMI_DIR"
    else
        echo "RUHMI already exists: $RUHMI_DIR"
    fi
}

setup() {
    download_ruhmi
    find_python

    local venv="$RUHMI_DIR/.venv"
    local python="$venv/bin/python"

    if [ ! -f "$python" ]; then
        echo "Creating Python virtual environment..."
        $PYTHON -m venv "$venv"
    fi

    echo "Upgrading pip..."
    "$python" -m pip install --upgrade pip

    local wheel
    wheel=$(find "$RUHMI_DIR/install" -name 'mera-*-cp310-cp310-manylinux_*.whl' -print -quit 2>/dev/null || true)
    if [ -z "$wheel" ]; then
        wheel=$(find "$RUHMI_DIR/install" -name 'mera-*-cp310-cp310-linux_*.whl' -print -quit 2>/dev/null || true)
    fi
    if [ -z "$wheel" ]; then
        echo "Error: RUHMI MERA wheel not found under $RUHMI_DIR/install." >&2
        exit 1
    fi

    echo "Installing RUHMI MERA wheel: $wheel"
    "$python" -m pip install "$wheel"

    echo "Installing Python dependencies..."
    "$python" -m pip install decorator typing_extensions psutil attrs pybind11 cmake junitparser onnx==1.17.0 tflite==2.18.0
}

convert() {
    setup
    download_model

    local venv_bin="$RUHMI_DIR/.venv/bin"
    local python="$venv_bin/python"
    local model
    model="$(pwd)/$MODEL_FILE"
    local out
    out="$(pwd)/$OUT_DIR"

    if [ ! -f "$model" ]; then
        echo "Error: Model file not found. Run: $0 download-model" >&2
        exit 1
    fi

    mkdir -p "$out"
    export PATH="$venv_bin:$PATH"

    echo "Running RUHMI NPU compilation..."
    pushd "$RUHMI_DIR" > /dev/null
    "$python" scripts/mcu_compile.py "$model" "$out" --npu
    popd > /dev/null

    echo "Expected RA8P1 NPU output: $out/$COMPILED_DIR"
}

metrics() {
    convert

    local python="$RUHMI_DIR/.venv/bin/python"
    local out="$OUT_DIR/$COMPILED_DIR"

    if [ ! -d "$out" ]; then
        local candidate
        candidate=$(find "$OUT_DIR" -maxdepth 1 -type d -name '*_NPU' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [ -n "$candidate" ]; then
            out="$candidate"
        fi
    fi

    if [ ! -d "$out" ]; then
        echo "Error: Compiled NPU output directory not found." >&2
        exit 1
    fi

    echo "Running RUHMI metrics check..."
    pushd "$RUHMI_DIR" > /dev/null
    "$python" scripts/utils/check_model_metrics.py "$out"
    popd > /dev/null
}

usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
  all              Run full pipeline: install, download, setup, convert, metrics
  install-python310  Check/install Python 3.10
  check-tools      Verify required tools are installed
  download-model   Download MNIST INT8 TFLite model
  download-ruhmi   Clone RUHMI framework repository
  setup            Create venv and install dependencies
  convert          Run NPU model compilation
  metrics          Run model metrics check
  help             Show this help message
EOF
}

case "${1:-help}" in
    all)
        install_python310
        download_model
        download_ruhmi
        setup
        convert
        metrics
        ;;
    install-python310) install_python310 ;;
    check-tools)       check_tools ;;
    download-model)    download_model ;;
    download-ruhmi)    download_ruhmi ;;
    setup)             setup ;;
    convert)           convert ;;
    metrics)           metrics ;;
    help|--help|-h)    usage ;;
    *)
        echo "Unknown command: $1" >&2
        usage
        exit 1
        ;;
esac
