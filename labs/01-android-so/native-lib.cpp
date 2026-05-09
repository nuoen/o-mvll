#include <jni.h>
#include <string.h>
#include <android/log.h>

#define LOG_TAG "OMVLLDemo"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

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
