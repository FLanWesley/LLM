# AutoDL:新建隔离的 conda 环境(复刻本机 .venv)+ 注册 Jupyter 内核

目标:AutoDL 上目前只有 `base`,不污染 `base`,新建一个独立环境,版本与本机 `.venv` 一致(Python 3.13.16),
并在 AutoDL 的 JupyterLab 里多出一个内核。

| 文件 | 说明 |
| --- | --- |
| `requirements-lock.txt` | 从本机 `.venv` 导出的 134 个精确 pin;已剔除 `torch`(单独装)、`pip/setuptools/wheel`、Windows 专属包 |
| `setup_env.sh` | 建 conda 环境 → 配镜像 → 装锁文件 → 装 torch → 注册内核 → 自检 |

## 一条命令

仓库在 AutoDL 上的位置:`/root/autodl-tmp`(脚本、锁文件都在 `/root/autodl-tmp/scripts/autodl/`),
在任意目录执行都可以,脚本会自己定位锁文件和项目根目录:

```bash
bash /root/autodl-tmp/scripts/autodl/setup_env.sh          # 默认环境名/内核名 gpt2
conda activate gpt2                      # 之后所有安装都在新环境里,base 保持干净
```

## 关于国内镜像

用,而且默认已经帮你配好 pip:

- **pip**:默认 `https://pypi.tuna.tsinghua.edu.cn/simple`。**只在脚本内用 `-i` 传入**,不改你的全局
  `pip.conf`,不会影响别的环境。若镜像缺少某个精确版本,pip 失败后会自动回退官方 `https://pypi.org/simple` 重试。
- **conda**:AutoDL 镜像通常已经把 conda 源指到国内镜像,所以默认**不动** `~/.condarc`。
  如果 `conda create` 很慢,加 `CONDA_MIRROR=1` 写入清华源(会先检测,已配置则跳过,并备份原文件为
  `~/.condarc.bak.<时间戳>`)。
- **AutoDL 学术加速**:`source /etc/network_turbo` 只加速 GitHub / HuggingFace 等,**对 PyPI 无效**,
  所以装 Python 包还是靠上面的 pip 镜像。
- **pip 缓存**默认放到 `/root/autodl-tmp/.cache/pip`,避免系统盘被撑爆。

## 空间策略(自动)

AutoDL 系统盘 30G,torch 环境 8~10G。脚本默认 `ENV_LOCATION=auto`:

- 系统盘剩余 ≥ 15G → 建**命名环境** `/root/miniconda3/envs/gpt2`,可以 `conda activate gpt2`
- 系统盘剩余 < 15G → 自动改到数据盘 `/root/autodl-tmp/envs/gpt2`,并提示用 `conda activate /root/autodl-tmp/envs/gpt2`

强制指定:

```bash
ENV_LOCATION=conda bash /root/autodl-tmp/scripts/autodl/setup_env.sh              # 必须建在系统盘(命名环境)
ENV_LOCATION=data  bash /root/autodl-tmp/scripts/autodl/setup_env.sh              # 必须建在数据盘
ENV_PREFIX=/root/autodl-tmp/envs/llm bash /root/autodl-tmp/scripts/autodl/setup_env.sh
```

## 常用变体

```bash
# 换名字 / 换内核显示名
ENV_NAME=llm KERNEL_DISPLAY_NAME="Python 3.13 (llm)" bash /root/autodl-tmp/scripts/autodl/setup_env.sh

# 无显卡实例(装 CPU 版 torch)
TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu bash /root/autodl-tmp/scripts/autodl/setup_env.sh

# 驱动较老,torch 报 cuda 不可用(改用 cu126 轮子)
TORCH_VERSION=<该 cu126 索引里可用的版本> TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126 bash /root/autodl-tmp/scripts/autodl/setup_env.sh

# 关掉镜像,走官方源
USE_MIRROR=0 bash /root/autodl-tmp/scripts/autodl/setup_env.sh

# 追加 ch05/ch06/ch07 需要的 TensorFlow(必须 Python < 3.13)
PY_VERSION=3.12 INSTALL_TF=1 bash /root/autodl-tmp/scripts/autodl/setup_env.sh
```

## 验证

```bash
conda activate gpt2
python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
jupyter kernelspec list        # 应出现 gpt2
```

JupyterLab 新建 notebook 选内核 `Python (gpt2)`;列表里没有就刷新页面或重启 AutoDL 的 JupyterLab。

## 排错

- **`No space left on device`**:`ENV_LOCATION=data` 重建;`conda clean -a -y`、`rm -rf /root/autodl-tmp/.cache/pip` 清缓存。
- **`Could not find a version that satisfies ...`**:镜像滞后。脚本会自动回退官方源;仍失败就把锁文件里该行
  改成镜像内可用的最近版本。
- **`conda: command not found`**:先 `source /root/miniconda3/etc/profile.d/conda.sh`。
- **内核里 `sys.executable` 不是新环境**:看 `~/.local/share/jupyter/kernels/gpt2/kernel.json` 的 `argv[0]`。
- **`conda activate gpt2` 无效**:环境在数据盘时要用绝对路径激活,或 `conda config --append envs_dirs /root/autodl-tmp/envs`。

## 与本机环境的差异

- 本机 `torch==2.14.1+cpu` 且没有 TensorFlow;AutoDL 装的是同版本号但带 CUDA 运行库的 Linux wheel。
- `pywin32-ctypes`、`pywinpty` 仅 Windows 需要,已剔除。`id`、`httpx2`、`nest-asyncio2` 等是本机环境的真实依赖,
  一并保留以保证版本完全一致。
