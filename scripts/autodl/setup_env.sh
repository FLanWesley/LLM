#!/usr/bin/env bash
# 在 AutoDL (Linux/GPU) 上，用 conda 新建一个与本地 .venv 版本一致、与 base 隔离的环境，
# 并把它注册成 Jupyter 内核。默认使用国内镜像加速下载。
#
# 用法（本机放在 /root/autodl-tmp/scripts/autodl/，任意路径下执行都可以）:
#   bash /root/autodl-tmp/scripts/autodl/setup_env.sh
#   ENV_NAME=llm bash /root/autodl-tmp/scripts/autodl/setup_env.sh
#   cd /root/autodl-tmp && bash scripts/autodl/setup_env.sh
#
# 可覆盖的环境变量:
#   ENV_NAME            环境名 / 内核 ID，默认 gpt2
#   PY_VERSION          Python 版本，默认 3.13（本地为 3.13.16）
#   ENV_PREFIX          指定安装路径；留空则用 conda 的 envs/$ENV_NAME（可用 conda activate 名字激活）
#   ENV_LOCATION        auto | conda | data，默认 auto：系统盘空间不足时自动改放 /root/autodl-tmp
#   MIN_FREE_GB         auto 模式下的空间阈值，默认 15
#   LOCK_FILE           锁文件，默认同目录 requirements-lock.txt
#   KERNEL_NAME         内核 ID，默认等于 ENV_NAME
#   KERNEL_DISPLAY_NAME 内核显示名，默认 "Python ($ENV_NAME)"
#   TORCH_VERSION       torch 版本，默认 2.14.1
#   TORCH_INDEX_URL     torch 专用源；留空 = PyPI Linux wheel（自带 CUDA 运行库）
#   INSTALL_TF          1 = 追加 tensorflow[and-cuda]>=2.18（需 PY_VERSION<3.13）
#   USE_MIRROR          1 = 使用国内镜像（默认 1）
#   PIP_INDEX           pip 源，默认清华；设成别的值即可覆盖
#   PIP_FALLBACK_INDEX  镜像缺版本时的回退源，默认 https://pypi.org/simple
#   CONDA_MIRROR        1 = 把清华 conda 源写入 ~/.condarc（会自动检测是否已配置）
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PROJECT_DIR="$(cd "$(dirname "$SELF")/../.." && pwd)"

ENV_NAME="${ENV_NAME:-gpt2}"
PY_VERSION="${PY_VERSION:-3.13}"
ENV_PREFIX="${ENV_PREFIX:-}"
ENV_LOCATION="${ENV_LOCATION:-auto}"
MIN_FREE_GB="${MIN_FREE_GB:-15}"
LOCK_FILE="${LOCK_FILE:-$(dirname "$SELF")/requirements-lock.txt}"
KERNEL_NAME="${KERNEL_NAME:-$ENV_NAME}"
KERNEL_DISPLAY_NAME="${KERNEL_DISPLAY_NAME:-Python ($ENV_NAME)}"
TORCH_VERSION="${TORCH_VERSION:-2.14.1}"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-}"
INSTALL_TF="${INSTALL_TF:-0}"
USE_MIRROR="${USE_MIRROR:-1}"
PIP_INDEX="${PIP_INDEX:-}"
CONDA_MIRROR="${CONDA_MIRROR:-0}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

free_gb() {
    local dir="$1"
    while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
    df -Pk "$dir" | awk 'NR==2 {printf "%d", $4/1048576}'
}

[ -f "$LOCK_FILE" ] || die "找不到锁文件: $LOCK_FILE"
command -v conda >/dev/null 2>&1 || die "未找到 conda，请先 'source /root/miniconda3/etc/profile.d/conda.sh'"
log "项目目录: $PROJECT_DIR"

# ---- 1. 镜像 ---------------------------------------------------------------
if [ -z "$PIP_INDEX" ] && [ "$USE_MIRROR" = "1" ]; then
    PIP_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
    PIP_FALLBACK_INDEX="${PIP_FALLBACK_INDEX:-https://pypi.org/simple}"
fi
PIP_ARGS=()
if [ -n "$PIP_INDEX" ]; then
    PIP_ARGS=(-i "$PIP_INDEX" --timeout 120 --retries 5)
    log "pip 源: $PIP_INDEX"
else
    log "pip 源: 默认（PyPI 官方）"
fi

if [ "$CONDA_MIRROR" = "1" ]; then
    if [ -f "$HOME/.condarc" ] && grep -qE 'tuna|aliyun|ustc|bfsu|douban' "$HOME/.condarc" 2>/dev/null; then
        log "conda 已配置国内镜像，跳过 ~/.condarc 写入"
    else
        if [ -f "$HOME/.condarc" ]; then
            cp "$HOME/.condarc" "$HOME/.condarc.bak.$(date +%s)"
        fi
        log "写入清华 conda 镜像到 ~/.condarc"
        cat > "$HOME/.condarc" <<'YAML'
channels:
  - defaults
show_channel_urls: true
default_channels:
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/msys2
custom_channels:
  conda-forge: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
  pytorch: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
YAML
    fi
else
    log "conda 源保持不变（AutoDL 镜像通常已配好；需要时用 CONDA_MIRROR=1 写入清华源）"
fi

# pip 缓存也放数据盘，避免撑爆系统盘
if [ -z "${PIP_CACHE_DIR:-}" ] && [ -d /root/autodl-tmp ]; then
    export PIP_CACHE_DIR=/root/autodl-tmp/.cache/pip
    log "pip 缓存目录: $PIP_CACHE_DIR"
fi

pip_install() {
    if "$ENV_PY" -m pip install "${PIP_ARGS[@]}" "$@"; then
        return 0
    fi
    if [ -n "${PIP_FALLBACK_INDEX:-}" ]; then
        warn "镜像安装失败，改用 $PIP_FALLBACK_INDEX 重试"
        "$ENV_PY" -m pip install -i "$PIP_FALLBACK_INDEX" --timeout 120 --retries 5 "$@"
        return
    fi
    return 1
}

# ---- 2. 环境位置 -----------------------------------------------------------
CONDA_BASE="$(conda info --base)"
ENV_DIR="$CONDA_BASE/envs/$ENV_NAME"
if [ -n "$ENV_PREFIX" ]; then
    ENV_DIR="$ENV_PREFIX"
elif [ "$ENV_LOCATION" = "data" ]; then
    ENV_DIR="/root/autodl-tmp/envs/$ENV_NAME"
elif [ "$ENV_LOCATION" = "auto" ] && [ -d /root/autodl-tmp ]; then
    sys_avail="$(free_gb "$CONDA_BASE/envs")"
    if [ "$sys_avail" -lt "$MIN_FREE_GB" ]; then
        ENV_DIR="/root/autodl-tmp/envs/$ENV_NAME"
        warn "系统盘仅剩 ${sys_avail}G (<${MIN_FREE_GB}G)，环境改放数据盘: $ENV_DIR"
    fi
fi

if [ "$ENV_DIR" = "$CONDA_BASE/envs/$ENV_NAME" ]; then
    CREATE_ARGS=(-n "$ENV_NAME")
    ACTIVATE_CMD="conda activate $ENV_NAME"
    REMOVE_CMD="conda env remove -n $ENV_NAME"
else
    CREATE_ARGS=(-p "$ENV_DIR")
    ACTIVATE_CMD="conda activate $ENV_DIR"
    REMOVE_CMD="conda env remove -p $ENV_DIR"
fi
ENV_PY="$ENV_DIR/bin/python"

# ---- 3. 创建隔离环境 -------------------------------------------------------
if [ -x "$ENV_PY" ]; then
    warn "环境已存在，跳过创建: $ENV_DIR"
else
    log "创建 conda 环境: python=$PY_VERSION -> $ENV_DIR"
    conda create -y --no-default-packages "${CREATE_ARGS[@]}" "python=$PY_VERSION"
fi
[ -x "$ENV_PY" ] || die "环境创建失败: 未找到 $ENV_PY"
log "解释器: $("$ENV_PY" --version 2>&1) ($ENV_PY)"

# ---- 4. 安装与本地一致的依赖 -----------------------------------------------
log "升级 pip / setuptools / wheel"
"$ENV_PY" -m pip install --quiet --upgrade pip setuptools wheel "${PIP_ARGS[@]}"

log "安装 requirements-lock.txt（134 个精确版本，与本地 .venv 一致）"
pip_install -r "$LOCK_FILE"

# ---- 5. 安装 torch ---------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
    log "GPU: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n1)"
else
    warn "未检测到 nvidia-smi，torch 只能以 CPU 模式运行"
fi

if [ -n "$TORCH_INDEX_URL" ]; then
    log "安装 torch==$TORCH_VERSION (index-url: $TORCH_INDEX_URL)"
    "$ENV_PY" -m pip install "torch==$TORCH_VERSION" --index-url "$TORCH_INDEX_URL"
else
    log "安装 torch==$TORCH_VERSION (PyPI Linux wheel，自带 CUDA 运行库)"
    pip_install "torch==$TORCH_VERSION"
fi

# ---- 6. 可选组件 -----------------------------------------------------------
if [ "$INSTALL_TF" = "1" ]; then
    case "$PY_VERSION" in
        3.10*|3.11*|3.12*)
            log "安装 tensorflow[and-cuda]（ch05/ch06/ch07 需要）"
            pip_install "tensorflow[and-cuda]>=2.18.0"
            ;;
        *)
            warn "TensorFlow 不支持 Python $PY_VERSION，已跳过；需要时用 PY_VERSION=3.12 重建"
            ;;
    esac
fi

# ---- 7. 注册 Jupyter 内核（与 base 隔离，但共享 JupyterLab） ----------------
log "注册 Jupyter 内核: $KERNEL_NAME ($KERNEL_DISPLAY_NAME)"
"$ENV_PY" -m ipykernel install --user --name "$KERNEL_NAME" --display-name "$KERNEL_DISPLAY_NAME"

# ---- 8. 验证 ---------------------------------------------------------------
log "验证"
"$ENV_PY" - <<'PY'
import sys
import torch
print(f"python      : {sys.version.split()[0]}  ({sys.executable})")
print(f"torch       : {torch.__version__}")
print(f"cuda avail  : {torch.cuda.is_available()}"
      + (f" ({torch.cuda.get_device_name(0)})" if torch.cuda.is_available() else ""))
import matplotlib, numpy, pandas, tiktoken  # noqa: E402
print(f"numpy/pandas: {numpy.__version__} / {pandas.__version__}")
print(f"tiktoken    : {tiktoken.__version__}")
PY

if ! "$ENV_PY" -c "import sys, torch; sys.exit(0 if torch.cuda.is_available() else 1)"; then
    warn "torch 未启用 GPU：多为驱动版本低于 wheel 内置的 CUDA 运行库"
    warn "换用匹配驱动的版本重装，例如:"
    warn "  TORCH_VERSION=<版本> TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126 bash $SELF"
fi

if command -v jupyter >/dev/null 2>&1; then
    jupyter kernelspec list | grep -E "^\s+$KERNEL_NAME\s+" || true
fi

cat <<EOF

完成。使用方式:
  $ACTIVATE_CMD
  python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
  JupyterLab 新建 notebook 时选择内核: $KERNEL_DISPLAY_NAME
  （列表里没有就刷新页面，或重启 AutoDL 的 JupyterLab）
环境位置: $ENV_DIR
删除:
  $REMOVE_CMD
  $ENV_PY -m ipykernel uninstall $KERNEL_NAME
EOF
