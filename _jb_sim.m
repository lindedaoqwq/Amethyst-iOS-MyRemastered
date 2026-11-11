// ★ [JB-ADAPT] extraction test: drives the REAL ameJBDetectEnvironmentOnce() from
// Natives/utils.m with injected evidence (dyld images / files / csops flags / jbroot dirs).
#import <Foundation/Foundation.h>
#undef dispatch_once
#define dispatch_once(tok,blk) do { (void)(tok); (blk)(); } while(0)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/types.h>
#include <unistd.h>

// ---- injectable evidence ----
static const char *gImg[64]; static int gImgN = 0;
static const char *gFiles[64]; static int gFileN = 0;
static const char *gDirEntries[64]; static int gDirN = -1;   // -1 => opendir fails
static int gDirIdx = 0;
static uint32_t gCSFlags = 0;
static pid_t gPidArg = 0; static unsigned gOpsArg = 0;

static uint32_t _dyld_image_count(void) { return (uint32_t)gImgN; }
static const char *_dyld_get_image_name(uint32_t i) { return (i < (uint32_t)gImgN) ? gImg[i] : NULL; }

#define access sim_access
static int sim_access(const char *p, int mode) {
    (void)mode;
    for (int i = 0; i < gFileN; i++) if (p && strcmp(p, gFiles[i]) == 0) return 0;
    return -1;
}

#define opendir sim_opendir
#define readdir sim_readdir
#define closedir sim_closedir
static struct dirent gDE;
static DIR *sim_opendir(const char *p) { (void)p; if (gDirN < 0) return NULL; gDirIdx = 0; return (DIR *)&gDE; }
static struct dirent *sim_readdir(DIR *d) {
    (void)d;
    if (gDirN < 0 || gDirIdx >= gDirN) return NULL;
    memset(&gDE, 0, sizeof(gDE));
    snprintf(gDE.d_name, sizeof(gDE.d_name), "%s", gDirEntries[gDirIdx]);
    gDirIdx++;
    return &gDE;
}
static int sim_closedir(DIR *d) { (void)d; return 0; }

int csops(pid_t pid, unsigned int ops, void *addr, size_t size) {
    gPidArg = pid; gOpsArg = ops;
    if (addr && size >= sizeof(uint32_t)) *(uint32_t *)addr = gCSFlags;
    return 0;
}

// ---- enum copied from Natives/utils.h ----
typedef NS_ENUM(NSInteger, AMEJBEnvironment) {
    AMEJBEnvironmentUnknown = 0,
    AMEJBEnvironmentNone,
    AMEJBEnvironmentRootful,
    AMEJBEnvironmentRootless,
    AMEJBEnvironmentRootHide,
};

// ---- REAL code extracted verbatim from Natives/utils.m ----
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_PLATFORM_BINARY
#define CS_PLATFORM_BINARY 0x4000000
#endif

static AMEJBEnvironment gAmeJBEnvironment = AMEJBEnvironmentUnknown;
static NSString *gAmeJBRootTag = nil;       // rootful / rootless / roothide
static NSString *gAmeJBFrameworkTag = nil;  // ElleKit / libhooker / Substitute / CydiaSubstrate
static NSString *gAmeJBFamilyTag = nil;     // Dopamine / palera1n / unc0ver / checkra1n / …
static NSString *gAmeJBSummary = nil;
static dispatch_once_t gAmeJBDetectOnce = 0;

// dyld 已加载镜像名（小写全路径）是否包含任一 needle。镜像注入是沙盒下最可靠的越狱证据：
// 越狱的 tweak 注入库一定出现在本进程镜像表里（RootHide 隐藏名单里的 App 除外）。
static BOOL ameJBAnyLoadedImageContains(NSArray<NSString *> *needles) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *ip = _dyld_get_image_name(i);
        if (ip == NULL) continue;
        NSString *full = [@(ip) lowercaseString];
        for (NSString *nd in needles) {
            if ([full containsString:nd]) return YES;
        }
    }
    return NO;
}

static BOOL ameJBFileExists(NSString *path) {
    return path.length > 0 && access(path.fileSystemRepresentation, F_OK) == 0;
}

// RootHide 随机 jbroot 目录扫描（.jbroot-<hex>）。仅无沙盒进程可列，列不到不算失败
// （dyld 证据已足以判定）。同时扫 /var（IOSSecuritySuite 记录过的落点）。
static BOOL ameJBFindRandomJBROOT(void) {
    const char *parents[] = { "/var/containers/Bundle/Application", "/var" };
    for (size_t p = 0; p < sizeof(parents) / sizeof(parents[0]); p++) {
        DIR *d = opendir(parents[p]);
        if (d == NULL) continue;
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            if (strncmp(ent->d_name, ".jbroot-", 8) == 0) { closedir(d); return YES; }
        }
        closedir(d);
    }
    return NO;
}

static void ameJBDetectEnvironmentOnce(void) {
    // ① RootHide：随机 jbroot 注入库 / 环境库（roothide 系）。名字被随机化的
    //    systemhook.dylib 不作判据，改认 .jbroot- 路径段与 roothideinit/libroothide/libvroot。
    if (ameJBAnyLoadedImageContains(@[@".jbroot-", @"roothideinit.dylib", @"libroothide", @"libvroot"])) {
        gAmeJBRootTag = @"roothide";
    }

    // ② 注入框架（四类）：ElleKit（Dopamine/palera1n/roothide 现代默认）/
    //    libhooker（Taurine/Odyssey）/ Substitute / CydiaSubstrate（unc0ver/checkra1n）。
    if (ameJBAnyLoadedImageContains(@[@"libellekit.dylib", @"/ellekit/"])) {
        gAmeJBFrameworkTag = @"ElleKit";
    } else if (ameJBAnyLoadedImageContains(@[@"libhooker.dylib"])) {
        gAmeJBFrameworkTag = @"libhooker";
    } else if (ameJBAnyLoadedImageContains(@[@"libsubstitute", @"substitute-inserter",
                                             @"substitute-loader"])) {
        gAmeJBFrameworkTag = @"Substitute";
    } else if (ameJBAnyLoadedImageContains(@[@"mobilesubstrate", @"cydiasubstrate", @"libsubstrate",
                                             @"substrateinserter", @"substrateloader",
                                             @"substratebootstrap", @"substrate-inserter"])) {
        gAmeJBFrameworkTag = @"CydiaSubstrate";
    } else if (ameJBAnyLoadedImageContains(@[@"systemhook.dylib", @"libblackjack.dylib"])) {
        // Dopamine 自有注入（某些机型/配置下 ElleKit 不可见时兜底；非 Substrate 系）。
        gAmeJBFrameworkTag = @"Dopamine(systemhook)";
    }

    // ③ 磁盘证据（沙盒下可能 EPERM/ENOENT，命中即用，未命中不否决）。
    BOOL diskRootless =
        ameJBFileExists(@"/var/jb") || ameJBFileExists(@"/var/jb/usr/bin") ||
        ameJBFileExists(@"/var/jb/usr/lib/libellekit.dylib") ||
        ameJBFileExists(@"/var/jb/Library/LaunchDaemons");
    BOOL diskRootHide =
        ameJBFileExists(@"/var/mobile/Library/Preferences/com.roothide.pref.plist") ||
        ameJBFindRandomJBROOT();
    BOOL diskRootful =
        ameJBFileExists(@"/Library/MobileSubstrate/MobileSubstrate.dylib") ||
        ameJBFileExists(@"/Applications/Cydia.app") ||
        ameJBFileExists(@"/Applications/Sileo.app") ||
        ameJBFileExists(@"/Applications/Zebra.app") ||
        ameJBFileExists(@"/var/binpack") ||
        ameJBFileExists(@"/.installed_unc0ver") ||
        ameJBFileExists(@"/.bootstrapped_electra");
    BOOL platformBit = NO;
    uint32_t csFlags = 0;
    if (csops(0, CS_OPS_STATUS, &csFlags, sizeof(csFlags)) == 0) {
        platformBit = (csFlags & CS_PLATFORM_BINARY) != 0;
    }

    // ④ 越狱根形态归类。
    if (gAmeJBRootTag == nil) {
        if (diskRootHide) {
            gAmeJBRootTag = @"roothide";
        } else if (diskRootless || (gAmeJBFrameworkTag != nil && !diskRootful)) {
            // 有注入框架但无固定 /var/jb 也归 rootless（现代越狱注入即越狱）。
            gAmeJBRootTag = @"rootless";
        } else if (diskRootful || platformBit) {
            gAmeJBRootTag = @"rootful";
        }
    }

    // ⑤ 越狱家族（尽力而为，仅用于日志/诊断）。
    if (ameJBFileExists(@"/Applications/Dopamine.app") ||
        ameJBFileExists(@"/var/mobile/Library/Preferences/com.opa334.Dopamine.plist") ||
        ameJBAnyLoadedImageContains(@[@"libblackjack.dylib", @"systemhook.dylib"])) {
        gAmeJBFamilyTag = @"Dopamine";
    } else if (ameJBFileExists(@"/Applications/palera1nLoader.app") ||
               ameJBFileExists(@"/usr/bin/palera1n-helper") ||
               ameJBFileExists(@"/cores/payload")) {
        gAmeJBFamilyTag = @"palera1n";
    } else if (ameJBFileExists(@"/.installed_unc0ver")) {
        gAmeJBFamilyTag = @"unc0ver";
    } else if (ameJBFileExists(@"/var/binpack")) {
        gAmeJBFamilyTag = @"checkra1n";
    } else if (ameJBFileExists(@"/.bootstrapped_electra")) {
        gAmeJBFamilyTag = @"Electra";
    } else if ([gAmeJBFrameworkTag isEqualToString:@"libhooker"]) {
        gAmeJBFamilyTag = @"Taurine/Odyssey";
    }

    if ([gAmeJBRootTag isEqualToString:@"roothide"]) {
        gAmeJBEnvironment = AMEJBEnvironmentRootHide;
    } else if ([gAmeJBRootTag isEqualToString:@"rootless"]) {
        gAmeJBEnvironment = AMEJBEnvironmentRootless;
    } else if ([gAmeJBRootTag isEqualToString:@"rootful"]) {
        gAmeJBEnvironment = AMEJBEnvironmentRootful;
    } else {
        gAmeJBEnvironment = AMEJBEnvironmentNone;
    }

    if (gAmeJBEnvironment == AMEJBEnvironmentNone) {
        gAmeJBSummary = @"None";
    } else {
        NSString *rootDesc =
            [gAmeJBRootTag isEqualToString:@"roothide"] ? @"RootHide(random jbroot)"
          : [gAmeJBRootTag isEqualToString:@"rootless"] ? @"rootless(/var/jb)"
          : @"rootful";
        NSMutableString *s = [NSMutableString stringWithString:rootDesc];
        if (gAmeJBFrameworkTag) [s appendFormat:@" + %@", gAmeJBFrameworkTag];
        if (gAmeJBFamilyTag)     [s appendFormat:@" (%@)", gAmeJBFamilyTag];
        gAmeJBSummary = s.copy;
    }
    // 可辨识日志：越狱环境分类（env=1 None / 2 Rootful / 3 Rootless / 4 RootHide）。
    NSLog(@"[JB-ADAPT] jailbreak env detect: env=%ld root=%@ framework=%@ family=%@ -> %@",
          (long)gAmeJBEnvironment, gAmeJBRootTag ?: @"none",
          gAmeJBFrameworkTag ?: @"none", gAmeJBFamilyTag ?: @"none", gAmeJBSummary);
}

AMEJBEnvironment AMEJailbreakEnvironment(void) {
    dispatch_once(&gAmeJBDetectOnce, ^{ ameJBDetectEnvironmentOnce(); });
    return gAmeJBEnvironment;
}

NSString *AMEJailbreakEnvSummary(void) {
    dispatch_once(&gAmeJBDetectOnce, ^{ ameJBDetectEnvironmentOnce(); });
    return gAmeJBSummary ?: @"None";
}

// re-runnable: neutralize dispatch_once caching for the test
static void simReset(void) {
    gAmeJBEnvironment = AMEJBEnvironmentUnknown;
    gAmeJBRootTag = nil; gAmeJBFrameworkTag = nil; gAmeJBFamilyTag = nil; gAmeJBSummary = nil;
}

static void case_(const char *name, const char **img, int nimg, const char **fl, int nfl,
                  const char **dirs, int ndirs, uint32_t cs) {
    gImgN = nimg; for (int i=0;i<nimg;i++) gImg[i]=img[i];
    gFileN = nfl; for (int i=0;i<nfl;i++) gFiles[i]=fl[i];
    gDirN = ndirs; for (int i=0;i<ndirs;i++) gDirEntries[i]=dirs[i];
    gCSFlags = cs;
    simReset();
    AMEJBEnvironment e = AMEJailbreakEnvironment();
    NSString *sum = AMEJailbreakEnvSummary();
    AMEJBEnvironment e2 = AMEJailbreakEnvironment(); // cached path
    printf("%-34s env=%ld cached=%ld  %s\n", name, (long)e, (long)e2, sum.UTF8String);
}

#define ARR(...) (const char *[]){__VA_ARGS__}, (int)(sizeof((const char*[]){__VA_ARGS__})/sizeof(const char*))
int main(void) {
    printf("case                               result\n");
    printf("---------------------------------------------------------------\n");
    case_("stock / unjailbroken",        NULL,0, NULL,0, NULL,-1, 0);
    case_("unc0ver (rootful+Substrate)", ARR("/Library/MobileSubstrate/MobileSubstrate.dylib"),
                                          ARR("/Library/MobileSubstrate/MobileSubstrate.dylib","/Applications/Cydia.app"),
                                          NULL,-1, 0);
    case_("checkra1n (rootful+binpack)", ARR("/usr/lib/substrate/SubstrateInserter.dylib"),
                                          ARR("/var/binpack"),
                                          NULL,-1, 0);
    case_("Taurine/Odyssey (libhooker)", ARR("/usr/lib/libhooker.dylib"), NULL,0, NULL,-1, 0);
    case_("Dopamine (rootless+ElleKit)", ARR("/var/jb/usr/lib/libellekit.dylib","/var/jb/usr/lib/libblackjack.dylib"),
                                          ARR("/var/jb"),
                                          NULL,-1, 0);
    case_("palera1n rootless",           ARR("/var/jb/usr/lib/libellekit.dylib"),
                                          ARR("/var/jb","/Applications/palera1nLoader.app"),
                                          NULL,-1, 0);
    case_("RootHide (dyld .jbroot-*)",   ARR("/var/containers/Bundle/Application/.jbroot-1a2b/usr/lib/roothideinit.dylib"),
                                          NULL,0, NULL,-1, 0);
    case_("RootHide (dir scan only)",    NULL,0, NULL,0, ARR(".jbroot-deadbeef"), 0);
    case_("RootHide+ElleKit",            ARR("/var/containers/Bundle/Application/.jbroot-ff/usr/lib/libellekit.dylib",
                                             "/var/containers/Bundle/Application/.jbroot-ff/usr/lib/roothideinit.dylib"),
                                          NULL,0, NULL,-1, 0);
    case_("XinaA15 (Substitute)",        ARR("/usr/lib/libsubstitute.dylib","/usr/lib/substitute-inserter.dylib"),
                                          NULL,0, NULL,-1, 0);
    case_("platform-bit only (rootful)", NULL,0, NULL,0, NULL,-1, 0x4000000);
    case_("Dopamine systemhook only",    ARR("/usr/lib/systemhook.dylib"), NULL,0, NULL,-1, 0);
    return 0;
}
