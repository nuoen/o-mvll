#include <jni.h>
#include <string.h>
#include <android/log.h>

#define LOG_TAG "OMVLLDemo"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)



// check_license: 故意堆满"for + 嵌套 if + switch + 多出口"的分支结构，
// 让 ControlFlowFlattening 能把原始 CFG 打散到足够多的 case block 里——
// BB 数越多，平坦化后 dispatcher 的 switch case 就越多，效果越明显。
//
// 校验规则（随手定的，够花就行）：
//   lic[0]           : 类型码 'A'/'B'/'C'（switch），各自带不同权重
//   lic[1 .. len-2]  : 字符串主体，for 循环逐字符累加（嵌套 if 分数字/字母/非法）
//   lic[len-1]       : 校验位（ASCII '0'~'9'）
//   通过条件         : (sum + type_weight) % 10 == 校验位
__attribute__((noinline))
static int check_license(const char *lic, int len) {
    if (lic == nullptr) return 0;
    if (len < 8)        return 0;

    int type_weight = 0;
    switch (lic[0]) {
        case 'A': type_weight = 10; break;
        case 'B': type_weight = 20; break;
        case 'C': type_weight = 30; break;
        default:  return 0;                         // 非法类型直接退出
    }

    int sum = 0;
    for (int i = 1; i < len - 1; ++i) {
        char c = lic[i];
        if (c >= '0' && c <= '9') {
            sum += (c - '0');
            if (sum > 100) {                        // 嵌套 if：累加溢出则打折
                sum -= 50;
            }
        } else if (c >= 'A' && c <= 'Z') {
            sum += (c - 'A') * 2;
        } else {
            return 0;                               // 非数字非大写字母 → 非法
        }
    }

    int expect = (sum + type_weight) % 10;
    int actual = lic[len - 1] - '0';
    return expect == actual ? 1 : 0;
}



__attribute__((noinline))
static int check_password(const char *s){
    if(s==nullptr){
        return 0;
    }
    int len = strlen(s);
    if(len!=6){
        return 0;
    }

    int score =0;
    if (s[0] == 'a') score += 1;
    if (s[1] == 'b') score += 2;
    if (s[2] == 'c') score += 3;
    if (s[3] == '1') score += 4;
    if (s[4] == '2') score += 5;
    if (s[5] == '3') score += 6;

    return score == 21;
}

__attribute__((noinline))
static const char *get_secret(){
    return "abc123";
}

extern "C"
JNIEXPORT jboolean JNICALL
Java_com_example_omvlldemo_MainActivity_checkKey(JNIEnv *env,jobject thiz,jstring input_){
    const char *input = env->GetStringUTFChars(input_,nullptr);
    LOGI("secret = %s",get_secret());
    int ret = check_password(input);
    env->ReleaseStringUTFChars(input_,input);
    return ret ? JNI_TRUE : JNI_FALSE;
}

// 把 check_license 也暴露成 JNI 入口，一是保证链接器不做 DCE（否则 noinline 还不够）；
// 二是 Day 3 可以从 Java 层直接跑到这个函数，方便 Frida hook 或 Stalker trace。
extern "C"
JNIEXPORT jboolean JNICALL
Java_com_example_omvlldemo_MainActivity_checkLicense(JNIEnv *env, jobject thiz, jstring lic_) {
    const char *lic = env->GetStringUTFChars(lic_, nullptr);
    int len = (int)strlen(lic);
    int ret = check_license(lic, len);
    env->ReleaseStringUTFChars(lic_, lic);
    return ret ? JNI_TRUE : JNI_FALSE;
}
