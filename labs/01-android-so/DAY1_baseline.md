❯ source omvll.env
❯ LLVM=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin
❯ strings  labs/01-android-so/libnative_lib_normal.so | grep abc123
abc123
❯ strings  labs/01-android-so/libnative_lib_omvll.so  | grep abc123
❯ $LLVM/llvm-readelf -h labs/01-android-so/libnative_lib_omvll.so | grep Machine
  Machine:                           AArch64
❯ $LLVM/llvm-objdump -d labs/01-android-so/libnative_lib_normal.so > /tmp/normal.asm
❯ $LLVM/llvm-objdump -d labs/01-android-so/libnative_lib_omvll.so  > /tmp/omvll.asm
❯ wc -l /tmp/*.asm
     158 /tmp/normal.asm
     512 /tmp/omvll.asm
     670 total