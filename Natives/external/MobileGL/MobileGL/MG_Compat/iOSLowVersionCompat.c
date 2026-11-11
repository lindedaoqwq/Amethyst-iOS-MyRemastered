/*
 * iOSLowVersionCompat.c —— MobileGL iOS 低版本兼容层
 * ---------------------------------------------------------------------------
 * 背景（Amethyst / Air Alternate，CI 实测 + Mach-O 符号表解析）：
 *
 *   MobileGL 源码大量使用 C++20 std::format。libc++ 的 <format> 模板展开会拉进
 *   __format/formatter_floating_point.h，进而调用 std::to_chars 的浮点重载。
 *   这些重载在 Apple SDK 里带 availability(introduced=iOS 16.3)。
 *   本工程为了能在 deployment target 14.0 下编过，在 CMakeLists.txt 的 iOS 分支
 *   里定义了 _LIBCPP_DISABLE_AVAILABILITY，压掉了 availability 检查 —— 代价是
 *   clang 生成了 **强引用**（而非 weak import），且 two-level namespace 把这几个
 *   符号绑定到 /usr/lib/libc++.1.dylib（library ordinal = 6）。
 *
 *   结果：vendored 的 libMobileGL.dylib / libMobileGL-gles.dylib 里留下 9 个
 *   undefined 的浮点 to_chars 符号，minos 却虚标为 14.0。在 iPadOS 15.x 上系统
 *   libc++ 没有这些符号，dyld 在 dlopen 阶段直接报
 *       Symbol not found: __ZNSt3__18to_charsEPcS0_d
 *   br_init() 返回 1，之后 pojavCreateContext 继续走未初始化的函数指针 -> SIGSEGV。
 *   换 DirectGLES / DirectVulkan 后端都无用：两个 dylib 是同一份二进制的两个副本，
 *   符号表完全一致。
 *
 * 本兼容层的做法：
 *   在同一个 image 内提供这 9 个符号的 **defined** 实现。链接时 ld64 会把所有
 *   对 std::__1::to_chars 的 undefined 引用解析到本文件，最终 dylib 里不再有
 *   undefined 符号，dyld 不需要向系统 libc++ 找，iOS 14~16.2 与 16.3+ 都能加载。
 *   这比"把全树 std::format 换成自研 format"改动小得多，且能覆盖静态链入的
 *   第三方库（glslang / SPIRV-Tools 等）产生的引用。
 *
 * ABI 约定（arm64 iOS / Darwin）：
 *   - 返回类型 std::__1::to_chars_result { char* ptr; std::errc ec; }
 *     std::errc 底层是 int，结构体 16 字节，按 AAPCS64 经 x0/x1 返回。
 *     这里用等价的 C 结构体，布局与调用约定一致。
 *   - std::__1::chars_format 是 enum class : unsigned，按值传（w2）。
 *   - 带 precision 的重载第 5 个参数是 int（w3）。
 *   - arm64 iOS 上 long double == double，所以 'e' 重载用 double 参数即可。
 *   - 用 __asm__ 绑定精确的 mangled 名，避免与 SDK <charconv> 的声明/ODR 纠缠，
 *     本文件不 include 任何 C++ 头，交叉编译必然通过。
 *
 * 运行时开关（设置页 "MobileGL iOS 低版本兼容层"）：
 *   JavaLauncher.m 按 video.mobilegl_ios_compat 注入 AME_MOBILEGL_IOS_COMPAT：
 *     "1"/未设置（默认）: 启用兼容层 —— 使用下面的内置 snprintf 实现。
 *     "0"              : 关闭兼容层 —— 优先 dlsym 转发系统 libc++ 的原生实现
 *                        （iOS 16.3+ 精确且更快）；低版本找不到时自动回退内置
 *                        实现并打印一行日志，保证任何情况下都不会崩。
 *
 * 说明：MobileGL 的 std::format 调用几乎都是整数/十六进制/字符串，浮点分支在
 * 运行时很少走到；内置实现以"最短往返"为目标做近似，仅用于兜底，不追求与
 * libc++ 逐位一致。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <errno.h>
#include <dlfcn.h>
#include <stdint.h>

/* [fix12] dlsym(RTLD_DEFAULT, MANGLED) 会命中本兼容层自己用 __asm__ 绑定的
   同名符号。AME_MOBILEGL_IOS_COMPAT=0 的转发路径若不排除自身就会无限递归
   -> 栈溢出。用 dladdr 比较目标与本文件所在 image，只有落在别的 image
   （系统 libc++）才转发。 */
static int ame_is_self_symbol(void *p) {
    Dl_info target, self;
    if (p == NULL) return 0;
    if (dladdr(p, &target) == 0 || target.dli_fname == NULL) return 0;
    if (dladdr((void *)(uintptr_t)&ame_is_self_symbol, &self) == 0 ||
        self.dli_fname == NULL) return 0;
    return strcmp(target.dli_fname, self.dli_fname) == 0;
}

/* [fix12] to_chars polyfill 采样诊断。
   Air Alternate 真机上 MobileGL-GLES 出现主菜单按钮不渲染，怀疑 GUI shader /
   常量字符串里的浮点格式化经本 polyfill 产出了非预期文本。前 12 次调用把实参
   与输出完整打点，之后每 4096 次打一行汇总。由
   AME_MOBILEGL_IOS_COMPAT_TRACE=1 显式开启，默认关闭（仅一次 getenv）。 */
static void ame_tc_sample(double value, int is_float, int has_fmt, unsigned fmt,
                          int has_prec, int precision, const char *out, int n) {
    static int enabled = -1;
    static unsigned long calls = 0;
    static unsigned long logged = 0;
    if (enabled < 0) {
        const char *v = getenv("AME_MOBILEGL_IOS_COMPAT_TRACE");
        enabled = (v != NULL && v[0] != '\0' && v[0] != '0') ? 1 : 0;
    }
    if (!enabled) return;
    calls++;
    if (logged < 12 || (calls % 4096UL) == 0UL) {
        logged++;
        fprintf(stderr,
                "[MobileGL-iOS-Compat][AME-DIAG] to_chars #%lu value=%.17g "
                "is_float=%d has_fmt=%d fmt=0x%x has_prec=%d precision=%d -> \"%.*s\"\n",
                calls, value, is_float, has_fmt, fmt, has_prec, precision,
                n > 0 ? n : 0, out ? out : "");
    }
}

/* 与 std::__1::to_chars_result 布局一致的等价 C 结构 */
typedef struct ame_to_chars_result {
    char *ptr;
    int   ec;
} ame_to_chars_result_t;

/* std::errc::value_too_large 在 Darwin 上等于 EOVERFLOW */
#define AME_TC_ERR EOVERFLOW

/* std::__1::chars_format 的位标志（C++ 标准值） */
enum {
    AME_FMT_SCIENTIFIC = 0x1,
    AME_FMT_FIXED      = 0x2,
    AME_FMT_HEX        = 0x4,
    AME_FMT_GENERAL    = 0x3   /* fixed | scientific */
};

/* 只有显式 "0" 才关闭；未设置 / "1" / 其它值一律启用（默认安全） */
static int ame_compat_enabled(void) {
    const char *v = getenv("AME_MOBILEGL_IOS_COMPAT");
    if (v == NULL) return 1;
    if (v[0] == '0' && (v[1] == '\0' || v[1] == '\n' || v[1] == '\r')) return 0;
    return 1;
}

/* Mach-O 符号表带一个前导 '_'，dlsym 的名字可能带也可能不带，两种都试 */
static void *ame_lookup_native(const char *mangled) {
    char stripped[256];
    void *p = dlsym(RTLD_DEFAULT, mangled);
    if (p != NULL) return p;
    if (mangled[0] == '_' && mangled[1] == '_') {
        size_t n = strlen(mangled + 1);
        if (n < sizeof(stripped)) {
            memcpy(stripped, mangled + 1, n + 1);
            return dlsym(RTLD_DEFAULT, stripped);
        }
    }
    return NULL;
}

static void ame_log_fallback_once(void) {
    static int once = 0;
    if (once) return;
    once = 1;
    fprintf(stderr,
            "[MobileGL-iOS-Compat] AME_MOBILEGL_IOS_COMPAT=0 but this OS has no "
            "native floating to_chars; falling back to the builtin polyfill.\n");
}

/*
 * 内置实现：把浮点值格式化进 [first, last)。
 * 先在栈上缓冲里生成，再检查长度并拷贝；缓冲区不足按标准返回 {last, EOVERFLOW}。
 */
static ame_to_chars_result_t ame_polyfill(char *first, char *last,
                                          double value, int is_float,
                                          int has_fmt, unsigned fmt,
                                          int has_prec, int precision) {
    ame_to_chars_result_t r;
    char tmp[512];
    int n;

    r.ptr = last;
    r.ec = AME_TC_ERR;
    if (first == NULL || last < first) return r;

    if (isnan(value)) {
        n = snprintf(tmp, sizeof(tmp), "%s", signbit(value) ? "-nan" : "nan");
    } else if (isinf(value)) {
        n = snprintf(tmp, sizeof(tmp), "%s", signbit(value) ? "-inf" : "inf");
    } else {
        const double v = is_float ? (double)(float)value : value;
        const int maxdig = is_float ? 9 : 17;
        unsigned f = has_fmt ? fmt : (unsigned)AME_FMT_GENERAL;
        int p;

        if (has_prec) {
            p = precision;
            if (p < 0) p = 6;
            if (p > 100) p = 100;   /* 防止病态 precision 撑爆缓冲 */
        }

        if ((f & AME_FMT_HEX) && !(f & (AME_FMT_FIXED | AME_FMT_SCIENTIFIC))) {
            /* 十六进制浮点：std::to_chars 用 1.8p+0，%a 用 0x1.8p+0；
               兜底路径下近似即可 */
            n = has_prec ? snprintf(tmp, sizeof(tmp), "%.*a", p, v)
                         : snprintf(tmp, sizeof(tmp), "%a", v);
        } else if ((f & AME_FMT_FIXED) && !(f & AME_FMT_SCIENTIFIC)) {
            if (has_prec) {
                n = snprintf(tmp, sizeof(tmp), "%.*f", p, v);
            } else {
                /* 定点、无 precision：从小到大找能往返还原的最短小数位 */
                for (p = 0; p <= maxdig + 24; ++p) {
                    n = snprintf(tmp, sizeof(tmp), "%.*f", p, v);
                    if (n < 0 || (size_t)n >= sizeof(tmp)) break;
                    if (is_float ? (strtof(tmp, NULL) == (float)v)
                                 : (strtod(tmp, NULL) == v)) break;
                }
            }
        } else if ((f & AME_FMT_SCIENTIFIC) && !(f & AME_FMT_FIXED)) {
            if (has_prec) {
                n = snprintf(tmp, sizeof(tmp), "%.*e", p, v);
            } else {
                for (p = 0; p <= maxdig; ++p) {
                    n = snprintf(tmp, sizeof(tmp), "%.*e", p, v);
                    if (n < 0 || (size_t)n >= sizeof(tmp)) break;
                    if (is_float ? (strtof(tmp, NULL) == (float)v)
                                 : (strtod(tmp, NULL) == v)) break;
                }
            }
        } else {
            /* general：有效数字从 1 位开始，找最短往返表示 */
            const int limit = has_prec ? p : maxdig;
            for (p = 1; p <= limit; ++p) {
                n = snprintf(tmp, sizeof(tmp), "%.*g", p, v);
                if (n < 0 || (size_t)n >= sizeof(tmp)) break;
                if (is_float ? (strtof(tmp, NULL) == (float)v)
                             : (strtod(tmp, NULL) == v)) break;
            }
            if (has_prec && p > limit) {
                n = snprintf(tmp, sizeof(tmp), "%.*g", limit, v);
            }
        }
    }

    if (n < 0 || (size_t)n >= sizeof(tmp)) return r;
    ame_tc_sample(value, is_float, has_fmt, fmt, has_prec, precision, tmp, n);
    {
        size_t need = (size_t)n;
        if (need > (size_t)(last - first)) return r;
        memcpy(first, tmp, need);
        r.ptr = first + need;
        r.ec = 0;
    }
    return r;
}

/* 关闭开关时尝试转发到系统原生实现；失败则回退内置实现 */
#define AME_TC_TRY_NATIVE(MANGLED, SIG, ARGS)                                  \
    do {                                                                        \
        if (!ame_compat_enabled()) {                                            \
            typedef ame_to_chars_result_t (*ame_native_fn) SIG;                 \
            void *ame_p = ame_lookup_native(MANGLED);                           \
            if (ame_p != NULL && !ame_is_self_symbol(ame_p))                    \
                return ((ame_native_fn)ame_p) ARGS;                              \
            ame_log_fallback_once();                                            \
        }                                                                       \
    } while (0)

/* ---------------------------------------------------------------------------
 * 9 个浮点 std::__1::to_chars 重载 —— mangled 名取自 libMobileGL*.dylib 的
 * undefined 符号表（两个后端一致），由 __asm__ 精确绑定。
 * ------------------------------------------------------------------------- */

/* double ('d') */
ame_to_chars_result_t ame_tc_d(char *first, char *last, double value)
    __asm__("__ZNSt3__18to_charsEPcS0_d");
ame_to_chars_result_t ame_tc_d(char *first, char *last, double value) {
    AME_TC_TRY_NATIVE("__ZNSt3__18to_charsEPcS0_d",
                      (char *, char *, double), (first, last, value));
    return ame_polyfill(first, last, value, 0, 0, 0, 0, 0);
}

ame_to_chars_result_t ame_tc_d_fmt(char *first, char *last, double value, unsigned fmt)
    __asm__("__ZNSt3__18to_charsEPcS0_dNS_12chars_formatE");
ame_to_chars_result_t ame_tc_d_fmt(char *first, char *last, double value, unsigned fmt) {
    AME_TC_TRY_NATIVE("__ZNSt3__18to_charsEPcS0_dNS_12chars_formatE",
                      (char *, char *, double, unsigned), (first, last, value, fmt));
    return ame_polyfill(first, last, value, 0, 1, fmt, 0, 0);
}

ame_to_chars_result_t ame_tc_d_fmt_p(char *first, char *last, double value, unsigned fmt, int precision)
    __asm__("__ZNSt3__18to_charsEPcS0_dNS_12chars_formatEi");
ame_to_chars_result_t ame_tc_d_fmt_p(char *first, char *last, double value, unsigned fmt, int precision) {
    AME_TC_TRY_NATIVE("__ZNSt3__18to_charsEPcS0_dNS_12chars_formatEi",
                      (char *, char *, double, unsigned, int),
                      (first, last, value, fmt, precision));
    return ame_polyfill(first, last, value, 0, 1, fmt, 1, precision);
}

/* long double ('e') —— arm64 iOS 上 ABI 与 double 相同 */
ame_to_chars_result_t ame_tc_e(char *first, char *last, double value)
    __asm__("__ZNSt3__18to_charsEPcS0_e");
ame_to_chars_result_t ame_tc_e(char *first, char *last, double value) {
    AME_TC_TRY_NATIVE("__ZNSt3__18to_charsEPcS0_e",
                      (char *, char *, double), (first, last, value));
    return ame_polyfill(first, last, value, 0, 0, 0, 0, 0);
}

ame_to_chars_result_t ame_tc_e_fmt(char *first, char *last, double value, unsigned fmt)
    __asm__("__ZNSt3__18to_charsEPcS0_eNS_12chars_formatE");
ame_to_chars_result_t ame_tc_e_fmt(char *first, char *last, double value, unsigned fmt) {
    AME_TC_TRY_NATIVE("__ZNSt3__18to_charsEPcS0_eNS_12chars_formatE",
                      (char *, char *, double, unsigned), (first, last, value, fmt));
    return ame_polyfill(first, last, value, 0, 1, fmt, 0, 0);
}

ame_to_chars_result_t ame_tc_e_fmt_p(char *first, char *last, double value, unsigned fmt, int precision)
    __asm__("__ZNSt3__18to_charsEPcS0_eNS_12chars_formatEi");
ame_to_chars_result_t ame_tc_e_fmt_p(char *first, char *last, double value, unsigned fmt, int precision) {
    AME_TC_TRY_NATIVE("__ZNSt3__18to_charsEPcS0_eNS_12chars_formatEi",
                      (char *, char *, double, unsigned, int),
                      (first, last, value, fmt, precision));
    return ame_polyfill(first, last, value, 0, 1, fmt, 1, precision);
}

/* float ('f') */
ame_to_chars_result_t ame_tc_f(char *first, char *last, float value)
    __asm__("__ZNSt3__18to_charsEPcS0_f");
ame_to_chars_result_t ame_tc_f(char *first, char *last, float value) {
    AME_TC_TRY_NATIVE("__ZNSt3__18to_charsEPcS0_f",
                      (char *, char *, float), (first, last, value));
    return ame_polyfill(first, last, (double)value, 1, 0, 0, 0, 0);
}

ame_to_chars_result_t ame_tc_f_fmt(char *first, char *last, float value, unsigned fmt)
    __asm__("__ZNSt3__18to_charsEPcS0_fNS_12chars_formatE");
ame_to_chars_result_t ame_tc_f_fmt(char *first, char *last, float value, unsigned fmt) {
    AME_TC_TRY_NATIVE("__ZNSt3__18to_charsEPcS0_fNS_12chars_formatE",
                      (char *, char *, float, unsigned), (first, last, value, fmt));
    return ame_polyfill(first, last, (double)value, 1, 1, fmt, 0, 0);
}

ame_to_chars_result_t ame_tc_f_fmt_p(char *first, char *last, float value, unsigned fmt, int precision)
    __asm__("__ZNSt3__18to_charsEPcS0_fNS_12chars_formatEi");
ame_to_chars_result_t ame_tc_f_fmt_p(char *first, char *last, float value, unsigned fmt, int precision) {
    AME_TC_TRY_NATIVE("__ZNSt3__18to_charsEPcS0_fNS_12chars_formatEi",
                      (char *, char *, float, unsigned, int),
                      (first, last, value, fmt, precision));
    return ame_polyfill(first, last, (double)value, 1, 1, fmt, 1, precision);
}

/* 供构建期/运行期确认兼容层确实编进镜像（可选，不参与符号补全） */
int AME_MOBILEGL_IOS_COMPAT_VERSION(void) { return 1; }
