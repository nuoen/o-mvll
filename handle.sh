#!/usr/bin/env bash
# 使用 omvll.env 中配置的 Android NDK clang++ 编译单个 native 源文件。
# 默认生成普通 so；传入 --omvll 时，会额外通过 -fpass-plugin 加载 O-MVLL
# LLVM pass 插件，生成混淆后的 so。
set -euo pipefail

usage() {
  echo "Usage: $0 [--normal|--omvll] <input.cpp|input.c> [output.so]"
  echo
  echo "Options:"
  echo "  --normal  Compile without O-MVLL. This is the default."
  echo "  --omvll   Compile with -fpass-plugin=\$OMVLL_SO."
  echo
  echo "Example:"
  echo "  $0 /Users/nuoen/Documents/AndroidSecurity/ollvm/o-mvll/labs/01-android-so/native-lib.cpp"
  echo "  $0 --omvll /Users/nuoen/Documents/AndroidSecurity/ollvm/o-mvll/labs/01-android-so/native-lib.cpp"
  echo "  $0 --omvll /path/to/native-lib.cpp /path/to/libnative_omvll.so"
}

# 编译模式：
#   normal：普通 Android NDK shared library
#   omvll： 在普通编译命令基础上额外加载 O-MVLL pass plugin
MODE="normal"

# 解析可选的第一个参数。这个代码块执行完后，剩余参数必须是：
#   1. 输入源文件路径
#   2. 可选的输出 so 路径
if [ "$#" -gt 0 ]; then
  case "$1" in
    --normal)
      MODE="normal"
      shift
      ;;
    --omvll|--obfuscate)
      MODE="omvll"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
fi

# 这个脚本刻意只接受一个源文件，适合 O-MVLL 学习实验：
# 不经过 CMake/Gradle，直接把一个 .cpp 编译成一个 .so，方便快速对比
# normal so 和 omvll so 的差异。
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 1
fi

# 获取脚本所在目录，而不是用户当前所在目录。
# 这样无论从哪个目录调用 handle.sh，都能稳定加载项目根目录下的 omvll.env。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INPUT="$1"

if [ ! -f "$INPUT" ]; then
  echo "[-] Input file not found: $INPUT"
  exit 1
fi

# 把输入路径规范化成绝对路径，避免后续 clang 调用时受当前目录影响。
INPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd -P)"
INPUT_FILE="$(basename "$INPUT")"
INPUT_ABS="$INPUT_DIR/$INPUT_FILE"

# 如果调用方没有指定输出路径，就在输入文件同目录下自动生成固定格式的文件名：
#   native-lib.cpp + normal -> libnative_lib_normal.so
#   native-lib.cpp + omvll  -> libnative_lib_omvll.so
if [ "$#" -eq 2 ]; then
  OUTPUT="$2"
else
  STEM="${INPUT_FILE%.*}"
  STEM="${STEM//-/_}"
  OUTPUT="$INPUT_DIR/lib${STEM}_${MODE}.so"
fi

# omvll.env 里定义了本实验需要的关键环境变量：
#   CLANGXX          用于生成 Android arm64 so 的 NDK clang++
#   OMVLL_SO         macOS 版 O-MVLL NDK 插件，例如 omvll-ndk.dylib
#   OMVLL_PYTHONPATH O-MVLL 内嵌 Python 解释器需要的 Python 3.10.7 标准库路径
#   OMVLL_CONFIG     O-MVLL 默认 Python 配置文件路径
#
# 注意：omvll.env 里的 `export OMVLL_CONFIG=...` 会覆盖调用者预先 export 的同名变量，
# 所以这里要先把调用者传进来的值快照下来，source 之后再恢复，避免 Day 2 这种
#   for k in global stack; do OMVLL_CONFIG=...$k.py ./handle.sh ...; done
# 的循环里每次都被强制改回同一份配置，结果产物 md5 完全相同。
CALLER_OMVLL_CONFIG="${OMVLL_CONFIG:-}"
source "$SCRIPT_DIR/omvll.env"

# OMVLL_CONFIG 解析优先级（高 → 低）：
#   1. 调用者预先 export OMVLL_CONFIG=...        （显式覆盖，最高优先级）
#   2. 输入源文件同目录下存在的 o-config.py      （lab 目录自动捡）
#   3. omvll.env 里设的默认值                    （兜底）
if [ -n "$CALLER_OMVLL_CONFIG" ]; then
  export OMVLL_CONFIG="$CALLER_OMVLL_CONFIG"
  echo "[i] OMVLL_CONFIG (from caller env): $OMVLL_CONFIG"
elif [ "$MODE" = "omvll" ] && [ -f "$INPUT_DIR/o-config.py" ]; then
  export OMVLL_CONFIG="$INPUT_DIR/o-config.py"
  echo "[i] OMVLL_CONFIG (from input dir):  $OMVLL_CONFIG"
elif [ "$MODE" = "omvll" ]; then
  echo "[i] OMVLL_CONFIG (from omvll.env): $OMVLL_CONFIG"
fi

# 在真正调用 clang 前先检查关键环境。
# 编译器报错通常比较长，提前检查能更快定位是环境问题还是代码问题。
if [ ! -x "$CLANGXX" ]; then
  echo "[-] clang++ not found: $CLANGXX"
  exit 1
fi

# O-MVLL 模式相比普通 NDK 编译额外依赖三项：
#   1. OMVLL_SO：通过 -fpass-plugin 加载的 LLVM pass 插件
#   2. OMVLL_CONFIG：决定哪些函数/字符串需要混淆的 Python 策略文件
#   3. OMVLL_PYTHONPATH：O-MVLL 内嵌 Python 解释器使用的标准库路径
if [ "$MODE" = "omvll" ]; then
  if [ ! -f "$OMVLL_SO" ]; then
    echo "[-] O-MVLL plugin not found: $OMVLL_SO"
    exit 1
  fi

  if [ ! -f "$OMVLL_CONFIG" ]; then
    echo "[-] O-MVLL config not found: $OMVLL_CONFIG"
    echo "    Put o-config.py next to the input file or export OMVLL_CONFIG."
    exit 1
  fi

  if [ ! -d "$OMVLL_PYTHONPATH" ]; then
    echo "[-] OMVLL_PYTHONPATH not found: $OMVLL_PYTHONPATH"
    exit 1
  fi
fi

# 如果调用方传了自定义输出路径，确保输出目录存在。
mkdir -p "$(dirname "$OUTPUT")"

# 用 Bash 数组组装 clang 参数，避免路径里有空格时被错误拆分。
# 同时也方便 --omvll 模式只追加一个额外编译参数。
CLANG_ARGS=(
  -shared
  -fPIC
  -O1
)

# normal 编译和 O-MVLL 编译的核心区别就在这里：
# O-MVLL 模式会通过 -fpass-plugin 加载插件；插件随后从环境变量中读取
# OMVLL_CONFIG 和 OMVLL_PYTHONPATH。
if [ "$MODE" = "omvll" ]; then
  CLANG_ARGS+=("-fpass-plugin=$OMVLL_SO")
fi

# 链接 Android log 库，因为 demo 代码通过 <android/log.h> 使用了
# __android_log_print。
CLANG_ARGS+=(
  "$INPUT_ABS"
  -o "$OUTPUT"
  -llog
)

"$CLANGXX" "${CLANG_ARGS[@]}"

echo "[+] Generated: $OUTPUT"
