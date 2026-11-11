#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "bridge_tbl.h"
#include "vk_bridge.h"
#include "utils.h"

// Vulkan 基础类型定义（参照 vulkan_core.h）
// 为避免引入完整的 vulkan_core.h 依赖链，在此处自行定义所需的最小类型集合。
// 这些类型与 Vulkan/MoltenVK 头文件中的定义完全一致。
typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef int32_t VkResult;
typedef uintptr_t VkInstance;

#define VK_SUCCESS 0
#define VK_INCOMPLETE 5
#define VK_NULL_HANDLE 0

// MoltenVK 配置 API 类型定义（参照 vk_mvk_moltenvk.h）
// vkGetMoltenVKConfigurationMVK 和 vkSetMoltenVKConfigurationMVK 可以在 VkInstance 创建之前
// 调用（传入 VK_NULL_HANDLE），用于读取/修改 MoltenVK 的运行时配置。
// 这两个 API 是 MoltenVK 的扩展函数（VK_MVK_moltenvk），不是标准 Vulkan 函数，
// 需要通过 dlsym 从 libMoltenVK.dylib 中直接获取符号。
//
// 注意：仓库中 Natives/external/mesa/MoltenVK/vk_mvk_moltenvk.h 是 Mesa 自带的
// 旧版本头文件（1.1.2, spec 30），不要拿它推断运行时版本。
// 实际运行的 libMoltenVK.dylib 为 v1.4.2（iOS arm64，从二进制 strings 确认；
// 升级前为 1.2.9）。1.2.9 与 1.4.2 的 MVK_CONFIG_* 列表里都**没有**
// MVK_CONFIG_SWAPCHAIN_PRESENT_MODE —— JavaLauncher.m 里那行 setenv 仅为前瞻
// 保留，不会改变 present mode；真正的帧率解锁走 eglSwapInterval(0) → zink
// 选择 IMMEDIATE present mode（详见 JavaLauncher.m 的核实结论）。
//
// 以下成员顺序严格参照 vk_mvk_moltenvk.h 中的 MVKConfiguration 结构体定义。
// 即使结构体大小与 MoltenVK 实际版本不完全匹配，vkGetMoltenVKConfigurationMVK
// 会通过 configSize 参数限制写入大小，不会导致越界访问。
typedef struct {
    VkBool32 debugMode;                              // 行 112
    VkBool32 shaderConversionFlipVertexY;            // 行 132
    VkBool32 synchronousQueueSubmits;                // 行 151
    VkBool32 prefillMetalCommandBuffers;             // 行 198
    uint32_t maxActiveMetalCommandBuffersPerQueue;   // 行 216
    VkBool32 supportLargeQueryPools;                 // 行 236
    VkBool32 presentWithCommandBuffer;               // 行 239 (已废弃)
    VkBool32 swapchainMagFilterUseNearest;           // 行 257
    uint64_t metalCompileTimeout;                    // 行 273 (uint64_t!)
    VkBool32 performanceTracking;                    // 行 290
    uint32_t performanceLoggingFrameCount;           // 行 306
    VkBool32 displayWatermark;                       // 行 320
    VkBool32 specializedQueueFamilies;               // 行 347
    VkBool32 switchSystemGPU;                        // 行 379
    VkBool32 fullImageViewSwizzle;                   // 行 432
    uint32_t defaultGPUCaptureScopeQueueFamilyIndex; // 行 446
    uint32_t defaultGPUCaptureScopeQueueIndex;       // 行 461
    VkBool32 fastMathEnabled;                        // 行 475
    uint32_t logLevel;                               // 行 491
    uint32_t traceVulkanCalls;                       // 行 512
    VkBool32 forceLowPowerGPU;                       // 行 526
    VkBool32 semaphoreUseMTLFence;                   // 行 549
    VkBool32 semaphoreUseMTLEvent;                   // 行 572
    uint32_t autoGPUCaptureScope;                    // 行 596
    char* autoGPUCaptureOutputFilepath;              // 行 616
    VkBool32 texture1DAs2D;                          // 行 632
    VkBool32 preallocateDescriptors;                 // 行 652
    VkBool32 useCommandPooling;                      // 行 671
    VkBool32 useMTLHeap;                             // 行 694
    VkBool32 logActivityPerformanceInline;           // 行 711
} MVKConfigurationLocal;

typedef VkResult (*PFN_vkGetMoltenVKConfigurationMVKLocal)(VkInstance ignored, MVKConfigurationLocal* pConfiguration, size_t* pConfigurationSize);
typedef VkResult (*PFN_vkSetMoltenVKConfigurationMVKLocal)(VkInstance ignored, MVKConfigurationLocal* pConfiguration, size_t* pConfigurationSize);

// Vulkan 渲染绕过桥接层：Minecraft 自管 swapchain 和 queue，直接通过 libMoltenVK 提交。
// 这些 stub 存在是为了让 pojavInitOpenGL() 能安装一个非 NULL 的桥接表，
// 避免任何 GL 形状的 GLFW 调用在 Vulkan 路径接管前/后到达 dispatcher 时崩溃。

static vk_render_window_t g_dummy;

// MoltenVK 配置 API 函数指针（在 vk_init 中通过 dlsym 加载）
static PFN_vkGetMoltenVKConfigurationMVKLocal s_vkGetMoltenVKConfigurationMVK = NULL;
static PFN_vkSetMoltenVKConfigurationMVKLocal s_vkSetMoltenVKConfigurationMVK = NULL;

// VSync 状态：记录当前是否禁用了垂直同步
static BOOL s_vsyncDisabled = NO;

/// 从 libMoltenVK.dylib 中加载 MoltenVK 配置 API
/// 这两个 API 可以在 VkInstance 创建之前调用，用于读取和修改 MoltenVK 运行时配置。
static void loadMoltenVKConfigAPIs(void* dl_handle) {
    if (!dl_handle) {
        NSLog(@"[VKBridge] loadMoltenVKConfigAPIs: dl_handle is NULL, skipping");
        return;
    }

    // 清除之前的错误状态
    dlerror();

    // 加载 vkGetMoltenVKConfigurationMVK
    s_vkGetMoltenVKConfigurationMVK = (PFN_vkGetMoltenVKConfigurationMVKLocal)dlsym(dl_handle, "vkGetMoltenVKConfigurationMVK");
    const char* getError = dlerror();
    if (getError || !s_vkGetMoltenVKConfigurationMVK) {
        NSLog(@"[VKBridge] Failed to load vkGetMoltenVKConfigurationMVK: %s", getError ?: "symbol not found");
        s_vkGetMoltenVKConfigurationMVK = NULL;
    } else {
        NSLog(@"[VKBridge] Successfully loaded vkGetMoltenVKConfigurationMVK");
    }

    // 加载 vkSetMoltenVKConfigurationMVK
    dlerror();
    s_vkSetMoltenVKConfigurationMVK = (PFN_vkSetMoltenVKConfigurationMVKLocal)dlsym(dl_handle, "vkSetMoltenVKConfigurationMVK");
    const char* setError = dlerror();
    if (setError || !s_vkSetMoltenVKConfigurationMVK) {
        NSLog(@"[VKBridge] Failed to load vkSetMoltenVKConfigurationMVK: %s", setError ?: "symbol not found");
        s_vkSetMoltenVKConfigurationMVK = NULL;
    } else {
        NSLog(@"[VKBridge] Successfully loaded vkSetMoltenVKConfigurationMVK");
    }
}

/// 读取并记录当前 MoltenVK 配置
/// 通过 vkGetMoltenVKConfigurationMVK 获取配置并打印关键参数，
/// 帮助诊断 Vulkan 渲染器的帧率限制问题。
static void logMoltenVKConfiguration() {
    if (!s_vkGetMoltenVKConfigurationMVK) {
        NSLog(@"[VKBridge] vkGetMoltenVKConfigurationMVK not available, skipping config logging");
        return;
    }

    MVKConfigurationLocal config;
    memset(&config, 0, sizeof(config));
    size_t configSize = sizeof(config);

    // 传入 VK_NULL_HANDLE（第一个参数被忽略），可以在 VkInstance 创建之前调用
    VkResult result = s_vkGetMoltenVKConfigurationMVK(VK_NULL_HANDLE, &config, &configSize);
    if (result == VK_SUCCESS || result == VK_INCOMPLETE) {
        NSLog(@"[VKBridge] MoltenVK Configuration (configSize=%zu, result=%d):", configSize, result);
        NSLog(@"[VKBridge]   debugMode=%u", config.debugMode);
        NSLog(@"[VKBridge]   synchronousQueueSubmits=%u", config.synchronousQueueSubmits);
        NSLog(@"[VKBridge]   prefillMetalCommandBuffers=%u", config.prefillMetalCommandBuffers);
        NSLog(@"[VKBridge]   maxActiveMetalCommandBuffersPerQueue=%u", config.maxActiveMetalCommandBuffersPerQueue);
        NSLog(@"[VKBridge]   swapchainMagFilterUseNearest=%u", config.swapchainMagFilterUseNearest);
        NSLog(@"[VKBridge]   metalCompileTimeout=%llu", config.metalCompileTimeout);
        NSLog(@"[VKBridge]   performanceTracking=%u", config.performanceTracking);
        NSLog(@"[VKBridge]   performanceLoggingFrameCount=%u", config.performanceLoggingFrameCount);
        NSLog(@"[VKBridge]   forceLowPowerGPU=%u", config.forceLowPowerGPU);
        NSLog(@"[VKBridge]   fastMathEnabled=%u", config.fastMathEnabled);
        NSLog(@"[VKBridge]   logLevel=%u", config.logLevel);
        NSLog(@"[VKBridge]   useCommandPooling=%u", config.useCommandPooling);
        NSLog(@"[VKBridge]   useMTLHeap=%u", config.useMTLHeap);
    } else {
        NSLog(@"[VKBridge] vkGetMoltenVKConfigurationMVK failed with result=%d", result);
    }
}

/// 检查并记录 VSync 相关环境变量状态
/// 这些环境变量影响 Vulkan 渲染器的帧率限制行为：
/// - POJAV_DISABLE_VSYNC: 启动器偏好，控制是否禁用垂直同步
/// - MVK_CONFIG_SWAPCHAIN_PRESENT_MODE: 历史诊断变量，MoltenVK（1.2.9 / 1.4.2）
///   均未实现，设置后不会改变 present mode；仅保留前向兼容
///
/// 实际运行的 MoltenVK 版本为 1.4.2（iOS arm64，从 libMoltenVK.dylib 二进制确认）。
/// 1.2.9 / 1.4.2 都**没有**实现 MVK_CONFIG_SWAPCHAIN_PRESENT_MODE，设置它不会
/// 覆盖 vkCreateSwapchainKHR 的 presentMode（与 JavaLauncher.m 的核实结论一致）。
/// 设备是否支持 IMMEDIATE present mode 由 MVKPhysicalDeviceMetalFeatures.presentModeImmediate
/// 自动检测（大多数 iOS 设备支持），实际帧率解锁由 eglSwapInterval(0) → zink 完成。
static void logVSyncEnvironment() {
    const char* pojavDisableVsync = getenv("POJAV_DISABLE_VSYNC");
    const char* renderer = getenv("AMETHYST_RENDERER");
    const char* mvkPresentMode = getenv("MVK_CONFIG_SWAPCHAIN_PRESENT_MODE");

    NSLog(@"[VKBridge] VSync Environment Check:");
    NSLog(@"[VKBridge]   AMETHYST_RENDERER=%s", renderer ?: "<unset>");
    NSLog(@"[VKBridge]   POJAV_DISABLE_VSYNC=%s", pojavDisableVsync ?: "<unset>");
    NSLog(@"[VKBridge]   MVK_CONFIG_SWAPCHAIN_PRESENT_MODE=%s", mvkPresentMode ?: "<unset>");

    // 判断 VSync 是否应该被禁用
    if (pojavDisableVsync && strcmp(pojavDisableVsync, "1") == 0) {
        s_vsyncDisabled = YES;
        NSLog(@"[VKBridge]   -> VSync is DISABLED (POJAV_DISABLE_VSYNC=1)");
        if (mvkPresentMode && strcmp(mvkPresentMode, "0") == 0) {
            NSLog(@"[VKBridge]   -> MoltenVK present mode forced to IMMEDIATE (MVK_CONFIG_SWAPCHAIN_PRESENT_MODE=0)");
        }
    } else {
        s_vsyncDisabled = NO;
        NSLog(@"[VKBridge]   -> VSync is ENABLED (POJAV_DISABLE_VSYNC!=1)");
    }
}

static bool vk_init(void) {
    NSLog(@"[VKBridge] vk_init: loading libMoltenVK.dylib");

    void* h = dlopen("@rpath/" RENDERER_NAME_VULKAN, RTLD_GLOBAL);
    if (!h) {
        NSLog(@"[VKBridge] dlopen %s failed: %s", RENDERER_NAME_VULKAN, dlerror());
        return false;
    }

    NSLog(@"[VKBridge] Successfully loaded %s", RENDERER_NAME_VULKAN);

    // 加载 MoltenVK 配置 API
    loadMoltenVKConfigAPIs(h);

    // 记录 VSync 环境变量状态
    logVSyncEnvironment();

    // 读取并记录当前 MoltenVK 配置
    logMoltenVKConfiguration();

    return true;
}

static vk_render_window_t* vk_init_context(vk_render_window_t* share) {
    return &g_dummy;
}

static void vk_make_current(vk_render_window_t* bundle) {
    // Vulkan 渲染器由 Minecraft/LWJGL 直接管理 Vulkan context，
    // 桥接层无需做任何事。
}

static void vk_swap_buffers(void) {
    // Vulkan 渲染器由 Minecraft/LWJGL 直接调用 vkQueuePresentKHR，
    // 桥接层的 swap_buffers 不会被调用（除非有 GL 形状的残留调用）。
    // 如果被调用，记录日志帮助诊断。
    static int s_swapBufferWarnCount = 0;
    if (s_swapBufferWarnCount < 3) {
        s_swapBufferWarnCount++;
        NSLog(@"[VKBridge] vk_swap_buffers called (unexpected for Vulkan renderer, count=%d)", s_swapBufferWarnCount);
    }
}

static void vk_swap_interval(int interval) {
    // Vulkan 渲染器由 Minecraft/LWJGL 直接管理 swapchain 的 present mode，
    // 桥接层的 swap_interval 不会直接影响 Vulkan 的 VSync 行为。
    //
    // 但我们在此处记录日志，帮助诊断 VSync 请求：
    // - interval=0 表示请求禁用 VSync（解锁帧率）
    // - interval=1 表示请求启用 VSync（锁屏刷新率）
    //
    // 对于 Vulkan 渲染器，VSync 控制通过以下机制实现：
    // 1. PojavLauncher.java 写 enableVsync=false 到 options.txt（让 MC 不请求 VSync）
    // 2. LWJGL 在 vkCreateSwapchainKHR 时选择 VK_PRESENT_MODE_IMMEDIATE_KHR
    // （设备是否支持 IMMEDIATE 由 MoltenVK 自动检测，无需环境变量声明）

    // 拦截 VSync 请求：当 POJAV_DISABLE_VSYNC=1 时，强制 interval=0
    // 虽然这对 Vulkan 渲染器没有直接效果（Minecraft 自管 swapchain），
    // 但记录此拦截行为有助于诊断问题。
    if (getenv("POJAV_DISABLE_VSYNC") && strcmp(getenv("POJAV_DISABLE_VSYNC"), "1") == 0) {
        if (interval != 0) {
            NSLog(@"[VKBridge] vk_swap_interval: intercepted VSync request interval=%d -> 0 (POJAV_DISABLE_VSYNC=1)", interval);
        }
        interval = 0;
        s_vsyncDisabled = YES;
    } else {
        s_vsyncDisabled = NO;
    }

    // 记录前几次的 swap_interval 调用，帮助诊断
    static int s_swapIntervalLogCount = 0;
    if (s_swapIntervalLogCount < 5) {
        s_swapIntervalLogCount++;
        NSLog(@"[VKBridge] vk_swap_interval(%d) called (count=%d, vsyncDisabled=%d)", interval, s_swapIntervalLogCount, s_vsyncDisabled);
    }
}

static void vk_terminate(void) {
    NSLog(@"[VKBridge] vk_terminate: cleaning up Vulkan bridge");
    // 清理配置 API 函数指针
    s_vkGetMoltenVKConfigurationMVK = NULL;
    s_vkSetMoltenVKConfigurationMVK = NULL;
    s_vsyncDisabled = NO;
}

// [fix16][DEAD-CODE] 整条 Vulkan 独立桥当前零调用点，请勿接线。
// 历史：VULKAN 渲染器曾单向调用 set_vk_bridge_tbl()，导致所有 GL 调用落到
// vk_bridge 的 stub（vk_init_context 返回 dummy），MC 26.2+ prefer_opengl
// 时黑屏；egl_bridge.m 已改为 set_gl_bridge_tbl() + dlopen(libMoltenVK)。
// 刻意【不删除】本函数：vk_bridge.m 内 13 个 static 函数仅由它引用，删除会
// 触发 -Wunused-function。CI 的 Verify source state 断言会阻止误接线。
void set_vk_bridge_tbl(void) {
    br_init = vk_init;
    br_init_context = (br_init_context_t) vk_init_context;
    br_make_current = (br_make_current_t) vk_make_current;
    br_swap_buffers = vk_swap_buffers;
    br_swap_interval = vk_swap_interval;
    br_terminate = vk_terminate;
}
