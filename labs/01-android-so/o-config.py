import omvll
from functools import lru_cache

class MyConfig(omvll.ObfuscationConfig):
    def __init__(self):
        super().__init__()
    #字符串加密：先只保护 abc123，方便观察效果
    def obfuscate_string(self, module:omvll.Module, function:omvll.Function, string:bytes):
        if b"abc123" in string:
            return omvll.StringEncOptGlobal()
        return False
    
    # 控制流平坦化：保护 check_password
    def flatten_cfg(self, module: omvll.Module, func: omvll.Function):
        name = func.name #← mangled 名，例如_ZL14check_passwordPKc
        demangled = func.demangled_name # ← demangle 后的可读名，例如check_password(char const*)
        if ("check_password" in name or "check_password" in demangled
            or "check_license" in name or "check_license" in demangled):
            return True
        return False
    
@lru_cache(maxsize=1)
def omvll_get_config() -> omvll.ObfuscationConfig:
    return MyConfig()