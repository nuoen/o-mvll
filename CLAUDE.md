# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 仓库定位

O-MVLL 是一个 LLVM pass 插件（以 shared library 形式分发，例如 `omvll-ndk.dylib` / `libOMVLL.so`），对 AArch64/ARM 目标做 native 代码混淆。它由用户提供的 Python 配置文件（通常叫 `o-config.py`）驱动，插件内嵌 CPython 解释器来加载这个文件。各 pass 通过 pybind11 回调 Python 配置，询问每个函数、字符串、结构体应不应该混淆、怎么混淆。

插件入口在 `src/core/plugin.cpp`，`getOMVLLPluginInfo()` 里能看到 pass 注册顺序：LoggerBind → AntiHook → FunctionOutline → StringEncoding → OpaqueFieldAccess → BasicBlockDuplicate → ControlFlowFlattening → BreakControlFlow → OpaqueConstants → Arithmetic →（ObjCleaner，experimental）→ IndirectCall → IndirectBranch → Cleaning。

## 目录结构

- `src/` — 插件的全部 C++ 源码。**CMake 根目录是 `src/`，不是仓库根**。
  - `src/core/` — 插件注册、Python 嵌入（`core/python/`）、JIT 辅助（`jitter.cpp`）、日志、YAML 配置加载。
  - `src/passes/` — 每个混淆 pass 一个子目录，各自带 `CMakeLists.txt`，由 `src/passes/CMakeLists.txt` 统一串起来。**加新 pass 时**：建子目录 → 在 `src/passes/CMakeLists.txt` 里 `add_subdirectory` → 在 `src/include/omvll/passes.hpp` include 头文件 → 在 `src/core/plugin.cpp` 里注册到 pipeline。
  - `src/include/omvll/` — 公开头文件。`ObfuscationConfig.hpp` 定义了 `PyObfuscationConfig` 桥接给用户 Python `ObfuscationConfig` 子类的虚接口。
  - `src/test/` — 基于 LLVM `lit` 的测试，按 pass 分目录。测试用 `RUN:` / `CHECK:` 注释指令，每个场景配一个 `config_*.py`。
  - `src/cmake/GitInfo.cmake` — configure 时从 git tag 推导 `OMVLL_VERSION_*`。
- `scripts/docker/` — CI 用的参考构建脚本，`ndk_r26_compile.sh` 是 Android NDK 构建的权威脚本。
- `scripts/package.py` — 把构建出的 `.so`/`.dylib` 打成发布 tarball。
- `.github/workflows/ndk.yml`、`xcode.yml` — 两种 ABI 的 CI。
- `doc/` — Sphinx 文档源码。
- `labs/`、`handle.sh`、`omvll.env`、`learn.*`、`omvll-logs/`、`omvll-tmp/`、`omvll_v1-6-0_*` — **本地实验脚手架，不是上游的一部分。** `handle.sh` 用本机 NDK clang 编译单个 `.cpp`，`--omvll` 时额外加载插件并自动挑选同目录的 `o-config.py`。这些目录当开发沙盒用，不要把它们的改动推到上游。
- `scripts/ida/` — IDA Python 辅助脚本（decrypt stub、nop BreakControlFlow、patch 等），本地积累的反混淆工具集。
- `.venv/` — 本地 Python 虚拟环境，内含 pip 包 `omvll==1.0.0` stub（**仅 IDE 补全用，与运行时加载的 redist dylib 接口有差异**，见下方「已知踩坑」）。

### handle.sh 的 OMVLL_CONFIG 解析优先级

修过的 `handle.sh` 现在按以下优先级解析配置文件（高 → 低）：

1. 调用者预先 `export OMVLL_CONFIG=...` — **显式覆盖，最高优先级**
2. 输入源文件同目录下存在的 `o-config.py` — lab 目录自动捡
3. `omvll.env` 里设的默认值 — 兜底

因此可以用 `OMVLL_CONFIG=... ./handle.sh --omvll ...` 动态切换不同配置，不会像旧版那样被强制覆盖。每次运行会打印用的是哪一份。

### Git 远程仓库

```
origin    git@github.com:nuoen/o-mvll.git       ← 用户 fork（push 目标）
upstream  https://github.com/open-obfuscator/o-mvll.git  ← 上游原项目
```

同步上游：`git fetch upstream && git merge upstream/main`，推送改动：`git push origin main`（或功能分支）。

## 已知踩坑（开发时先查这里）

1. **`StringEncOptStack` 不存在于 redist dylib**：pip 包 `omvll==1.0.0` 的 stub.py 里还有 `StringEncOptStack`，但 v1.6.0 dylib 里已重命名为 `StringEncOptLocal`（`src/include/omvll/passes/string-encoding/StringEncodingOpt.hpp:16`）。IDE 补全出的 Stack 运行时不存在。确认方法：`strings "$OMVLL_SO" | grep StringEncOpt`。

2. **`.bss` 段不能 `patch_bytes`**：`.bss` 是未初始化段，ELF 文件内无存储。IDA 的 `is_loaded()` 对它返回 False，`patch_bytes` 只在 idb 生效。检测地址是否有效用 `ida_segment.getseg(ea) is not None`。

3. **`StringEncOptReplace()` 无参时替换为空串→全 `\0`**：`processReplace`（`StringEncoding.cpp:575-578`）用 `\0` padding 到原长，运行时 `printf("%s",...)` 遇第一个 `\0` 就停。要看到误导效果必须传非空参：`StringEncOptReplace("FAKE")`。

4. **`obfuscate_string` 返回 `True` 走的是 Local 不是 Global**：`PyObfuscationConfig.cpp:41-43`，`py::bool_` 映射成 `StringEncOptDefault()` → 派发到 `processLocal`（`StringEncoding.cpp:559-561`）。

5. **`BreakControlFlow` ≠ 传统 BCF（虚假控制流）**：它是在函数头注入 anti-disassembly stub（`BreakControlFlow.cpp:29-55`），末尾两个 raw bytes（`F1 FF F2 A2` / `F8 FF E2 C2`）让反汇编器同步错位。O-MVLL 里真正的 BCF 效果由 `BasicBlockDuplicate` + `OpaqueConstants` 组合提供。

6. **`flatten_cfg` 回调中 `func.demangled_name` 可能为 None**：JNI 入口或 C 风格函数返回 `None`，直接 `"key" in None` 会抛 `TypeError`。安全写法：`(func.name or "")` 和 `(func.demangled_name or "")`。

## 构建

CMake 工程根在 `src/`。依赖的 LLVM 版本必须严格匹配，**版本对不上 CMake 直接 fatal_error**：

- Apple ABI → LLVM **19.1.4**
- Android ABI → LLVM **17**（release NDK）或 **17.0.2**（CustomAndroid）

其它依赖（全部通过 `find_package(... NO_DEFAULT_PATH)` 找）：`pybind11`、`spdlog`、Python 3。

关键 CMake 选项：
- `-DOMVLL_ABI=Apple|Android|CustomAndroid` — 决定 LLVM 版本与链接策略。`Android` 链接 NDK 预编译的 monolithic `libLLVM`，其它 ABI 链接独立组件库。
- `-DCMAKE_BUILD_TYPE=Release|RelWithDebInfo|Debug` — 默认 `RelWithDebInfo`。Debug/RelWithDebInfo 会强制 `OMVLL_DEBUG=1`；Release 会 strip 日志，除非 `-DOMVLL_FORCE_LOG_DEBUG=ON`。
- `-DOMVLL_PY_STANDALONE=ON` — 构建独立 Python 模块而非 LLVM pass 插件（会额外拉入 `clang*` 系列库）。

Android NDK 构建（对齐 CI，完整上下文见 `scripts/docker/ndk_r26_compile.sh`）：

```bash
cd src && mkdir -p build && cd build
cmake -GNinja .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER=<NDK stage1>/bin/clang++ \
  -DCMAKE_C_COMPILER=<NDK stage1>/bin/clang \
  -DCMAKE_CXX_FLAGS=-stdlib=libc++ \
  -DPython3_ROOT_DIR=<Python-slim> \
  -DPython3_LIBRARY=<Python-slim>/lib/libpython3.10.a \
  -DPython3_INCLUDE_DIR=<Python-slim>/include/python3.10 \
  -Dpybind11_DIR=<pybind11>/share/cmake/pybind11 \
  -Dspdlog_DIR=<spdlog>/lib/cmake/spdlog \
  -DLLVM_DIR=<NDK stage2>/lib/cmake/llvm \
  -DOMVLL_ABI=CustomAndroid
ninja
```

**NDK 两阶段（two-stage）约束**：插件必须用构建 NDK 自身的 stage-1 toolchain 来编译，然后链接 stage-2 的产物。混用 stage 会得到 ABI 不兼容的插件，加载时不一定报错，但运行结果不可靠。

## 测试

`src/test/` 下是 LLVM `lit` 回归测试，构建生成 `check` 目标：

```bash
ninja -C src/build check                                   # 跑全部测试
<LLVM_TOOLS_DIR>/bin/llvm-lit -vv src/build/test/passes/cfg-flattening/                              # 跑单个 pass 目录
<LLVM_TOOLS_DIR>/bin/llvm-lit -vv src/build/test/passes/cfg-flattening/basic-aarch64-android.c      # 跑单个用例
```

调用 `lit` **必须先 export `OMVLL_PYTHONPATH`**（指向 Python 3.10.7 的 `Lib/` 目录），否则 `src/test/lit.cfg.py` 会直接 `exit(1)`。

测试在 `// RUN:` 行里嵌入 clang 调用，用 `FileCheck` 断言。每个用例用 `REQUIRES:`（比如 `x86-registered-target`、`android_abi`、`apple_abi`）筛选——目标架构没编进 LLVM 的用例会被 skip 而不是 fail。加新测试：把 `.c` / `.cpp` / `.ll` / `.m` / `.swift` 和对应的 `config_*.py` 一起丢到对应 pass 目录即可。

## 插件运行时装配流程

插件 bootstrap（`src/core/plugin.cpp`）在每次 clang 调用时执行一次：
1. 从 CWD 向上逐级找 `omvll.yml`（字段：`OMVLL_PYTHONPATH`、`OMVLL_CONFIG`）；找不到则退回到插件 `.so` 所在目录再找一遍。
2. 环境变量 `OMVLL_CONFIG` 和 `OMVLL_PYTHONPATH` 覆盖 YAML 里的值。
3. 加载 Python 配置，通过 `omvll_get_config()` 实例化用户的 `ObfuscationConfig` 子类，在 pass manager 生命周期内持有。
4. 各 pass 回调 Python，比如 `obfuscate_string(module, func, bytes) → StringEncOpt*`、`flatten_cfg(module, func) → bool / ControlFlowFlatteningOpt`。最小示例见 `labs/01-android-so/o-config.py`，完整接口见 `ObfuscationConfig.hpp`。

**加 pass 时三处都要改**：Python 侧 option 类放在 `src/include/omvll/passes/ObfuscationOpt.hpp`，在 `src/core/python/pyobf_opt.cpp` 里做 pybind11 绑定，`ObfuscationConfig` 虚函数在 `src/core/python/PyObfuscationConfig.cpp` 里做桥接。漏掉任何一处，都会得到一个能编过但用户配置永远启用不了的 pass。

## 平台相关约定

- **Android ABI**（`OMVLL_ABI=Android`）链接 NDK 的 monolithic `LLVM`，用 gold 链接器，加 `--as-needed`、`--gc-sections`、`--exclude-libs,ALL`、`-static-libgcc`。
- **Apple ABI** 用 `-flat_namespace`，通过 `src/exports.txt` 手工维护导出符号列表，**不在列表里的符号一律隐藏**。
- 插件强制 `-fno-rtti`、`-fvisibility=hidden`、`-fvisibility-inlines-hidden`，**pass 里不要依赖 RTTI**。
- spdlog 带 `SPDLOG_DISABLE_DEFAULT_LOGGER`、`SPDLOG_NO_EXCEPTIONS`、`SPDLOG_NO_THREAD_ID` 构建。日志走 `omvll/log.hpp` 的 `SINFO` / `SWARN` / `SERR` / `SDEBUG`，不要用 `fprintf` 或直接调 spdlog。

## 学习笔记维护（learn.md）

**每当本轮对话涉及"新知识"，要同步总结到 `learn.md`**，不要只停留在对话里。

什么算"新知识"——任何满足下列之一：
- 第一次在本仓库语境里澄清的**概念**（例如 "StringEncOpt* 各类的语义差异"、"平坦化 vs 虚假控制流"）
- 第一次确认的**源码事实**（带文件:行号的结论，例如 "`StringEncoding.cpp:551-562` 的 visit 派发表"）
- 第一次踩通的**实操坑**（例如 "`handle.sh` 会覆盖外部 `OMVLL_CONFIG`"、"`.bss` 对 `patch_bytes` 无效"）
- 第一次讲透的**工具用法**（例如 "IDA `patch_byte` vs `patch_bytes` 签名差异"、"Python 生成器表达式 + `bytes()` 构造 XOR 脚本"）

**纯重复问答、已在 learn.md 覆盖过的内容**不要再追加——先 `grep` 确认 learn.md 里没写过。

归位规则（按优先级）：

1. **插入最贴切的已有章节**：优先找 §14（Pass 顺序）、§15（7 天计划的对应 Day）、§18（O-MVLL 实现原理）这类主题章。例如 "StringEncOpt 速查" 归到 §15 Day 2 和 §18.7；"BreakControlFlow 其实是 anti-disassembly" 归到 §18.7 和 §15 Day 3。
2. **在已有章节里拉新子节**：主题接近但深度超出原文，开 `### 18.9 xxx` 这种子节挂进去。
3. **实在找不到合适位置，追加新顶级章**：只有跨主题、跨 pass 的内容才值得新开 `## 19. xxx`，否则优先并入现有章节避免目录膨胀。

归位时同时维护：
- 章节号连续（新开顶级章紧接现有最大编号）
- 同一事实只在**一个权威位置**详述，其他位置引用（"见 §18.7"）而不是复制粘贴
- 代码/源码事实**必须带 `文件:行号`** 锚点，否则不写——日后源码变动时能快速核对是否过期

不满足"新知识"门槛的对话（寒暄、重复提问、纯修 bug 过程）**不要写进 learn.md**，避免把学习笔记变成聊天记录。
