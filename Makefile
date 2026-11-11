SHELL := /bin/bash
.SHELLFLAGS = -ec
# Use `make VERBOSE=1` to print commands.
$(VERBOSE).SILENT:

# Prerequisite variables
SOURCEDIR   := $(shell printf "%q\n" "$(shell pwd)")
OUTPUTDIR   := $(SOURCEDIR)/artifacts
WORKINGDIR  := $(SOURCEDIR)/Natives/build
DETECTPLAT  := $(shell uname -s)
DETECTARCH  := $(shell uname -m)
VERSION     := 6.0.0
BRANCH      := $(shell git branch --show-current)
COMMIT      := $(shell git log --oneline | sed '2,10000000d' | cut -b 1-7)
PLATFORM    ?= 2

# Release vs Debug
RELEASE ?= 0

# Check if running on github runner
RUNNER ?= 0

# Check if slimmed should be built
SLIMMED ?= 0

# Check if slimmed should be built, and additionally skip normal build
SLIMMED_ONLY ?= 0

# If not in a GitHub repository, default to these
# so that compiling doesn't fail
BRANCH ?= "unknown"
COMMIT ?= "unknown"

# Team IDs and provisioning profile for the codesign function
# Default to -1 for check
# Currently requires a paid Apple Developer account, will fix later
SIGNING_TEAMID ?= -1
TEAMID ?= -1
PROVISIONING ?= -1

ifeq (1,$(RELEASE))
CMAKE_BUILD_TYPE := Release
else
CMAKE_BUILD_TYPE := Debug
endif

# ★ [RENDERER-GAP] 新增渲染器（VGPU / GL4ESZL2 / NG-GL4ES / VirGL）。
# 默认 0：VGPU 不参与构建、GL4ESZL2 / VirGL 不进 payload 依赖图
#          （这几个是可选/实验性的，默认 IPA 与既有渲染器行为零变化）。
# 置 1 后：native 透传 -DAME_RENDERER_GAP_VGPU=ON（构建 libvgpu.dylib），
#          且 payload 追加 dep_gl4eszl2 dep_virgl 两个目标。
# 用法：make RENDERER_GAP_EXTRAS=1 payload
#
# ⚠ NG-GL4ES（"Krypton Wrapper"）【不】受此开关控制：它是用户可见的一等渲染器
#   （对应原 f907a3f180 的无条件 payload 依赖），dep_nggl4es 直接挂在 payload 上，
#   CI 的 `gmake dsym package` 每次都会构建 libnggl4es.dylib。
# [fix16] 默认 0 是有意为之：VGPU / GL4ESZL2 / VirGL 属可选实验渲染器，
# 它们的 dylib 是构建产物（非提交二进制），默认不进 IPA；UI 候选会被
# availableRendererCandidates() 的存在性过滤隐藏。启用需显式
# make RENDERER_GAP_EXTRAS=1 payload。CI 断言会锁住这个默认值。
RENDERER_GAP_EXTRAS ?= 0
# ★ [RENDERER-GAP] 由上面的开关派生：默认空 → payload 依赖图与既有完全一致。
ifeq (1,$(RENDERER_GAP_EXTRAS))
RENDERER_GAP_PAYLOAD_DEPS := dep_gl4eszl2 dep_virgl
else
RENDERER_GAP_PAYLOAD_DEPS :=
endif


# Distinguish iOS from macOS, and *OS from others
ifeq ($(DETECTPLAT),Darwin)
OSVER       := $(shell sw_vers -productVersion | cut -b 1-2)
ifeq ($(shell sw_vers -productName),macOS)
IOS         := 0
SDKPATH     ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
BOOTJDK     ?= $(shell /usr/libexec/java_home -v 1.8)/bin
$(warning Building on macOS.)
else
IOS         := 1
SDKPATH     ?= /usr/share/SDKs/iPhoneOS.sdk
BOOTJDK     ?= /usr/lib/jvm/java-8-openjdk/bin
ifeq ($(shell test "$(OSVER)" -gt 14; echo $$?),0)
# ★ [ROOTHIDE] 在 iOS 上就地构建时的安装前缀。
#   · 普通 rootless：固定 /var/jb/（上一版行为，保持不变）。
#   · RootHide（Dopamine-roothide/palera1n-roothide）：越狱根【随机化】到
#     /var/containers/Bundle/Application/.jbroot-<16hex>/，不存在 /var/jb
#     ⇒ 旧默认会把 App 装到空路径。这里自动探测随机 jbroot（优先）并加尾斜杠
#     （deploy 用 $(PREFIX)Applications/... 拼接）。显式传 PREFIX=... 仍覆盖（?=）。
#   注：.ipa/.tipa 打包路径（package target）不使用 PREFIX，不受影响。
PREFIX      ?= $(shell d=$$(ls -d /var/containers/Bundle/Application/.jbroot-*/ 2>/dev/null | head -1); if [ -n "$$d" ]; then printf '%s' "$$d"; else echo "/var/jb/"; fi)
else
PREFIX      ?= /
endif
$(warning Building on iOS. Note that all targets may not compile or require external components.)
endif
else ifeq ($(DETECTPLAT),Linux)
IOS         := 0
# SDKPATH presence is checked later
BOOTJDK     ?= /usr/bin
$(warning Building on Linux. Note that all targets may not compile or require external components.)
else
$(error This platform is not currently supported for building Angel Aura Amethyst.)
endif

# ============================================================================
# ★ [SWIFT-BAR] SwiftUI 底部标签栏(Natives/AmeTabBar.swift)编译变量
# ----------------------------------------------------------------------------
#  与 C 侧同样按平台判定 target:设备 arm64-apple-ios14.0,
#  模拟器 <arch>-apple-ios14.0-simulator(看 SDKPATH 指向 iPhoneSimulator 与否)。
#  swiftc 产出 $(WORKINGDIR)/AmeTabBar.o,路径再经 -DAME_TABBAR_OBJ=... 交给 CMake;
#  CMakeLists.txt 里留着同一条 swiftc 规则,直接跑 cmake 时兜底。
# ============================================================================
SWIFTC        ?= $(shell xcrun -f swiftc 2>/dev/null || command -v swiftc 2>/dev/null || echo swiftc)
SWIFT_SRC     ?= $(SOURCEDIR)/Natives/AmeTabBar.swift
SWIFT_OBJ     ?= $(WORKINGDIR)/AmeTabBar.o
SWIFT_ARCH    ?= arm64
SWIFT_MIN_IOS ?= 14.0
ifeq ($(findstring Simulator,$(SDKPATH)),Simulator)
SWIFT_TARGET  ?= $(SWIFT_ARCH)-apple-ios$(SWIFT_MIN_IOS)-simulator
else
SWIFT_TARGET  ?= $(SWIFT_ARCH)-apple-ios$(SWIFT_MIN_IOS)
endif

# ★ [SWIFT-BAR] 编译 SwiftUI 底部标签栏(必须先于 native 的 cmake 链接)
swift:
	echo '[Amethyst v$(VERSION)] swift - start'
	mkdir -p $(WORKINGDIR)
	$(SWIFTC) -parse-as-library -emit-object \
		-target $(SWIFT_TARGET) \
		-sdk "$(SDKPATH)" \
		$(if $(filter 1,$(RELEASE)),-O,) \
		-o $(SWIFT_OBJ) $(SWIFT_SRC)
	echo '[Amethyst v$(VERSION)] swift - end'

# Define PLATFORM_NAME from PLATFORM
ifeq ($(PLATFORM),2)
PLATFORM_NAME := ios
$(warning Set PLATFORM to 2, which is equal to iOS.)
else ifeq ($(PLATFORM),3)
PLATFORM_NAME := tvos
$(warning Set PLATFORM to 3, which is equal to tvOS.)
else ifeq ($(PLATFORM),6)
PLATFORM_NAME := maccatalyst
$(warning Set PLATFORM to 6, which is equal to Mac Catalyst.)
else ifeq ($(PLATFORM),7)
PLATFORM_NAME := iossimulator
$(warning Set PLATFORM to 7, which is equal to iOS Simulator.)
else ifeq ($(PLATFORM),8)
PLATFORM_NAME := tvossimulator
$(warning Set PLATFORM to 8, which is equal to tvOS Simulator.)
else ifeq ($(PLATFORM),11)
PLATFORM_NAME := xros
$(warning Set PLATFORM to 11, which is equal to visionOS.)
else ifeq ($(PLATFORM),12)
PLATFORM_NAME := xrsimulator
$(warning Set PLATFORM to 12, which is equal to visionOS Simulator.)
else
$(error PLATFORM is not valid.)
endif

POJAV_BUNDLE_DIR      ?= $(OUTPUTDIR)/AngelAuraAmethyst.app
POJAV_JRE8_DIR        ?= $(SOURCEDIR)/depends/java-8-openjdk
POJAV_JRE17_DIR       ?= $(SOURCEDIR)/depends/java-17-openjdk
POJAV_JRE21_DIR       ?= $(SOURCEDIR)/depends/java-21-openjdk
POJAV_JRE25_DIR       ?= $(SOURCEDIR)/depends/java-25-openjdk
MOLTENVK_LIBRARY      ?= $(SOURCEDIR)/Natives/resources/Frameworks/libMoltenVK.dylib
MOBILEGL_SOURCE_DIR   ?= $(SOURCEDIR)/Natives/external/MobileGL
# MobileGL 源码已 vendoring 在 Natives/external/MobileGL（与 MobileGlues 一样是普通
# 源码目录，不再是 gitlink），可以直接改源码调 iOS 构建。
# 上游不发布 iOS 预编译产物。2026-08-31 首次编译成功（提交 55256e33），
# 两个后端 dylib 已提交在 Natives/resources/Frameworks/ 下，日常构建直接用它，
# 不必重编（编 glslang + SPIRV-Cross 约 30 分钟，Actions 对 macOS 按 10 倍计费）。
# 2026-11-07：加入 iOSLowVersionCompat.c 兼容层（补 iOS 16.3 之前系统 libc++
# 缺失的 9 个浮点 std::__1::to_chars 符号），必须重编两个 dylib 才生效，故默认值
# 改为 1。CI 普通 IPA 步骤显式设 1 触发重编；TrollStore 步骤设 0 复用同一次产物
# （两个步骤在同一 job / 同一工作目录），避免重复 30 分钟交叉编译。
# 更新源码：直接用 git 把 MobileGL-Dev/MobileGL 的 dev 分支（子模块取各自默认
# 分支）同步进 Natives/external/MobileGL，并保持既有剔除规则（SPIRV-Cross/test、
# glslang/Test、Vulkan-Headers/tests、DiligentCore/Samples|Tutorials、
# trace_replay/fixtures、android-plugin）。不依赖任何 workflow。
BUILD_MOBILEGL        ?= 1
MOBILEGL_DYLIB        ?= $(SOURCEDIR)/Natives/resources/Frameworks/libMobileGL.dylib
MOBILEGL_GLES_DYLIB   ?= $(SOURCEDIR)/Natives/resources/Frameworks/libMobileGL-gles.dylib
MITHRIL_PREBUILT_DIR  ?= $(SOURCEDIR)/prebuilt

# Function to use later for checking dependencies
METHOD_DEPCHECK   = $(shell $(1) >/dev/null 2>&1 && echo 1)

# Function to modify Info.plist files
METHOD_INFOPLIST  =  \
	if [ '$(4)' = '0' ]; then \
		plutil -replace $(1) -string $(2) $(3); \
	else \
		plutil -value $(2) -key $(1) $(3); \
	fi

# Function to check directories
METHOD_DIRCHECK   = \
	if [ ! -d '$(1)' ]; then \
		mkdir -p $(1); \
	else \
		rm -rf $(1)/*; \
	fi
	
# Function to change the platform on Mach-O files.
# iOS = 2, tvOS = 3, iOS Simulator = 7, tvOS Simulator = 8, visionOS = 11, visionOS Simulator = 12
# https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h
# TODO: Change Info.plist for visionOS 1.0
METHOD_CHANGE_PLAT = \
	if [ '$(1)' != '11' ] && [ '$(1)' != '12' ]; then \
		vtool -arch arm64 -set-build-version $(1) 14.0 26.2 -replace -output $(2) $(2); \
		ldid -S -M $(2); \
	else \
		vtool -arch arm64 -set-build-version $(1) 1.0 1.0 -replace -output $(2) $(2); \
	fi \
	
# Function to package the application
# 修复：使用统一的命名格式 amethystremastered
METHOD_PACKAGE = \
	if [ '$(TROLLSTORE_JIT_ENT)' == '1' ]; then \
		IPA_SUFFIX="-trollstore.tipa"; \
	else \
		IPA_SUFFIX=".ipa"; \
	fi; \
	rm -f $(OUTPUTDIR)/com.airalternate.amethyst-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX; \
	rm -f $(OUTPUTDIR)/com.airalternate.amethyst.slimmed-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX; \
	if [ '$(SLIMMED_ONLY)' = '0' ]; then \
		zip --symlinks -r $(OUTPUTDIR)/com.airalternate.amethyst-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX Payload; \
	fi; \
	if [ '$(SLIMMED)' = '1' ] || [ '$(SLIMMED_ONLY)' = '1' ]; then \
		zip --symlinks -r $(OUTPUTDIR)/com.airalternate.amethyst.slimmed-$(VERSION)-$(PLATFORM_NAME)$$IPA_SUFFIX Payload --exclude='Payload/AngelAuraAmethyst.app/java_runtimes/*'; \
	fi

# Function to download and unpack Java runtimes.
# ★ [JRE-NEST] 原条件把「缺 release」与「无归档」用 && 串起来 ⇒ 只有当两者同时成立才解包：
#   当 depends/ 里已存在 jreN-*.tar.xz(归档在)而 java-N-openjdk/ 缺失时整块被跳过 ⇒ 运行期读不到 JRE。
#   现改为：缺 release 就解包；归档不存在才下载；解包后探测并纠正“多套一层”；产物做非空/可运行校验。
#   注意：本变量在 Makefile 里是单条逻辑行，绝不能塞 `#` 注释(会吃掉其后整行) —— 故提示一律走 echo。
METHOD_JAVA_UNPACK = \
	cd $(SOURCEDIR)/depends; \
	if [ ! -f "java-$(1)-openjdk/release" ]; then \
		_arc=$$(ls jre$(1)-*.tar.xz 2>/dev/null | head -n1); \
		if [ -z "$$_arc" ]; then \
			if [ "$(RUNNER)" != "1" ]; then \
				wget '$(2)' -q --show-progress; \
				unzip jre*-ios-aarch64.zip && rm jre*-ios-aarch64.zip; \
			fi; \
			_arc=$$(ls jre$(1)-*.tar.xz 2>/dev/null | head -n1); \
		fi; \
		if [ -n "$$_arc" ]; then \
			rm -rf "java-$(1)-openjdk"; mkdir -p "java-$(1)-openjdk"; \
			tar xf "$$_arc" -C "java-$(1)-openjdk"; \
			if [ ! -f "java-$(1)-openjdk/release" ]; then \
				for d in java-$(1)-openjdk/*/; do \
					if [ -f "$$d/release" ] && [ -f "$$d/lib/server/libjvm.dylib" ]; then \
						echo "★ [JRE-NEST] 检测到多套一层，展开: $$d"; mv "$$d"/* "java-$(1)-openjdk/"; rmdir "$$d"; break; \
					fi; \
				done; \
			fi; \
			if [ ! -f "java-$(1)-openjdk/release" ] || [ ! -f "java-$(1)-openjdk/lib/server/libjvm.dylib" ]; then \
				echo "★ [JRE-NEST] ERROR: java-$(1)-openjdk 解包后缺 release / lib/server/libjvm.dylib"; ls -la "java-$(1)-openjdk"; exit 1; \
			fi; \
			echo "★ [JRE-NEST] java-$(1)-openjdk OK (release + lib/server/libjvm.dylib)"; \
		else \
			echo "★ [JRE-NEST] ERROR: 缺 java-$(1)-openjdk 且无归档可下载: $(2)"; exit 1; \
		fi; \
	fi

# Function to codesign binaries.
METHOD_CODESIGN = \
	codesign --remove-signature $(2); \
	codesign -f -s $(1) --generate-entitlement-der --entitlements entitlements.codesign.xml $(2); \
	printf 'File: '; printf $(2); printf ', Codesigned with team: '; printf $(1); printf '\n'

# Function to run code when finding Mach-O files.
METHOD_MACHO = \
	for file in $$(find $(1)); do \
		if [[ "$$(file $$file)" == *"Mach-O"* ]]; then \
			$(2); \
		fi; \
	done

# Make sure everything is already available for use. Error if they require something
ifneq ($(call METHOD_DEPCHECK,cmake --version),1)
$(error You need to install cmake)
endif

ifneq ($(call METHOD_DEPCHECK,$(BOOTJDK)/javac -version),1)
$(error You need to install JDK 8)
endif

ifeq ($(IOS),0)
ifeq ($(filter 1.8.0,$(shell $(BOOTJDK)/javac -version &> javaver.txt && cat javaver.txt | cut -b 7-11 && rm -rf javaver.txt)),)
$(error You need to install JDK 8)
endif
endif

ifneq ($(call METHOD_DEPCHECK,ldid),1)
$(error You need to install ldid)
endif

ifneq ($(call METHOD_DEPCHECK,wget --version),1)
$(error You need to install wget)
endif

ifeq ($(DETECTPLAT),Linux)
ifneq ($(call METHOD_DEPCHECK,lld),1)
$(error You need to install lld)
endif
endif

ifneq ($(filter sysctl,$(shell sysctl -n hw.logicalcpu)),)
ifneq ($(call METHOD_DEPCHECK,nproc --version),1)
ifneq ($(call METHOD_DEPCHECK,gnproc --version),1)
$(warning Unable to determine number of threads, defaulting to 2.)
JOBS   ?= 2
else
JOBS   ?= $(shell gnproc)
endif
else
JOBS   ?= $(shell nproc)
endif
else
JOBS   ?= $(shell sysctl -n hw.logicalcpu)
endif

ifndef SDKPATH
$(error You need to specify SDKPATH to the path of iPhoneOS.sdk. The SDK version should be 14.0 or newer.)
endif

all: clean native java jre assets payload package dsym

help:
	echo 'Makefile to compile Angel Aura Amethyst'
	echo ''
	echo 'Usage:'
	echo '    make                                Makes everything under all'
	echo '    make help                           Displays this message'
	echo '    make all                            Builds the entire app'
	echo '    make native                         Builds the native app'
	echo '    make swift                          Builds the SwiftUI tab bar (Natives/AmeTabBar.swift)'
	echo '    make java                           Builds the Java app'
	echo '    make jre                            Downloads/unpacks the iOS JREs'
	echo '    make assets                         Compiles Assets.xcassets'
	echo '    make payload                        Makes Payload/AngelAuraAmethyst.app'
	echo '    make package                        Builds ipa of Angel Aura Amethyst'
	echo '    make deploy                         Copies files to local iDevice'
	echo '    make dsym                           Generate debug symbol files'
	echo '    make clean                          Cleans build directories'
	echo '    make check                          Dump all variables for checking'
	echo '    make iris-bridge-on                 ★ 26.2 Iris<->Metal 桥 开 (默认; 见 Natives/shader_iris_bridge.sh)'
	echo '    make iris-bridge-off                ★ 26.2 Iris<->Metal 桥 关 (回退到旧 classes262/ 类集)'
	echo '    make shader-glslang-pack            ★ 影光 glslang native 缺口打包 (含 classes262iris 补类)'
	echo '    make shader-glslang-check           ★ 检查 glslang native 是否已入包'
	echo '    make verify-iris-integrate          ★ [IRIS-INTEGRATE] 校验 91符号 native 接线 + 类集未回退 r10'
	echo '    make shader-iris-integrate          ★ [IRIS-INTEGRATE] 接线 26.2-iris → 91符号 libmetallum_iris.dylib'

# ★ [SHADER-FAST] 26.2 Iris↔Metal 桥 开关（只改 agent jar 内的标记资源 metallum_iris.mode）。
#   运行期也可覆盖(优先于标记): -Dmetallum.iris.bridge=0|1 / AMETHYST_METALLUM_IRIS=0|1
#   类集 classes262iris/ + natives/ir1/ 常驻在 jar 内, 关掉只是不再被 routing 选中 ⇒ 零副作用。
#   ★ 一键回退: `make iris-bridge-off`；整包回退 cp D:/CTF/_510src/_bak_/shaderfast_*/metallum_agent.jar.orig
iris-bridge-on:
	sh Natives/shader_iris_bridge.sh on

iris-bridge-off:
	sh Natives/shader_iris_bridge.sh off

iris-bridge-status:
	sh Natives/shader_iris_bridge.sh status

# ★ [SHADER-GLSLANG] 影光最后一跳 native 缺口打包（幂等）。
#   ★ [SHADER-SIGBUS] 本目标现在的语义 = **glslang 只走 Frameworks，jar 里必须没有它**：
#   · libglslang.dylib(带 17 个 glslang C API 符号) 只放在
#       Natives/resources/Frameworks/libglslang.dylib（+ .16 / .16.4.0 两个同字节别名），
#     由 GlslangBridge.createIOSGlslangLookup() 的 System.loadLibrary("glslang") 加载
#     （java.library.path = <app>/Frameworks；payload 的 cp -R Natives/resources/* 自动进包）。
#     随 app 一起被 ad-hoc 签名的副本 ⇒ dyld 能做成文件后备 RX 映射 ⇒ 不会 SIGBUS。
#   · 【不再】往 agent jar / MetalUniversal jar 塞 natives/ios|ir1/libglslang.dylib，
#     并在打包时把已有条目【移除】。原因：MetalNativeBridge.configureBundledGlslangLibrary()
#     会把 jar 内资源解包到 <home>/libglslang_metallum.dylib 再 System.load ——
#     那是【没有随包签名】的副本，dyld bypass 对它只能走
#     "匿名映射 + PrepareRegion + 镜像 memcpy" 兜底路径，首次执行即 SIGBUS
#     （真机实证：SIGBUS at [libglslang_metallum.dylib+0xccbc4] _GLOBAL__sub_I_Scan.cpp，
#      且紧邻日志的 PrepareRegion len==2392064==该 dylib __TEXT.vmsize；
#      历史档案 VERSION_HISTORY.md v378 `noglslanginjar.ipa` 同结论）。
#   · classes262iris/ + classes262/ 两个类集前缀补 com/mojang/blaze3d【整组】（缺口 B）
#     ★ [BLAZE3D-ROOT-SHADOW] 【不再】镜像到 jar 根 —— "-javaagent" 的 jar 在 app/system
#       classpath 上, 根副本会让 app loader 影子化游戏自己的类 (26.4 真机:
#       RenderSystem$AutoStorageIndexBuffer$IndexGenerator 被 app 装载 ⇒ 同名包不同
#       runtime package ⇒ IllegalAccessError ⇒ Could not initialize class RenderSystem)。
#     ★ [SHADER-BLAZE3D-GROUP] 不再是"三个固定名字"：组 = Natives/shader_glslang/blaze3d/**
#       （清单 blaze3d_group.txt），由 Natives/extract_blaze3d_group.py 从 client-26.2.jar
#       算出 = agent 真正 define 的 com/metallum/client/** + 3 接口的【链接面闭包】
#       （超类/接口/字段方法 descriptor/泛型 Signature/throws）。上一轮只补 3 个固定名字，
#       真机 latestlog-40 立刻在下一层炸：
#           NoClassDefFoundError: com/mojang/blaze3d/systems/GpuSurface$PresentMode  ← 内部类($)
#       根那份 com/metallum/** 副本(逐字节 == classes262/) implements/引用它们，根里却没有
#       com/mojang/blaze3d/ ⇒ "只看得到 jar 根"的 loader 一读就 NoClassDefFoundError。
#       ★ 组内【不含】mixin 目标本体(opengl/GlStateManager、systems/RenderSystem)：agent 用
#         原始 defineClass 把它们 define 进 Knot 会绕过 Fabric/Iris mixin。
#   ★ 重新求组(仅在有 client-26.2.jar 的机器上跑；Mac 出包线【不】跑):
#       python Natives/extract_blaze3d_group.py --check      # 只核对清单/源目录/闭包
#       python Natives/extract_blaze3d_group.py              # 重算并落源目录+清单
#   真机缺口见 latestlog-38.txt：Symbol not found: glslang_initialize_process
shader-glslang-pack:
	python3 Natives/pack_shader_glslang.py

shader-glslang-check:
	python3 Natives/pack_shader_glslang.py --check
	python3 Natives/verify_iris_integrate.py          # ★ [IRIS-INTEGRATE]
	python3 Natives/check_spvc_provenance.py          # ★ [26.4-SPVC]

# ★ [26.4-SPVC] spvc native 出处校验（防"搬家漏带"）。
#   真机 26.4 首次 UI 管线 minecraft:pipeline/gui 崩在
#   "SPIRV-Cross error at spvc_context_parse_spirv: -1"（-1 = INVALID_SPIRV）。
#   ★ 关键事实：设备上真正做 SPIR-V→MSL 的 libspvc 不是 Frameworks 里那份 ——
#   metallum 的 MetalNativeBridge.configureBundledSpvcLibrary() 会从 jar 抽
#   natives/ios/libspvc.dylib 到 $POJAV_HOME 并 System.load + 设
#   Configuration.SPVC_LIBRARY_NAME ⇒ LWJGL 的 Spvc 加载的是 jar 里那份，
#   我们的 spvc 串行化垫片被整体绕过（真机 26.4 日志里 [spvc-shim] 一行都没有，
#   只有 main_hook 的 "[spvc] dlsym intercepted"）。
#   ⇒ jar 里的 natives 一旦在搬家/换底时没带对（mlrepo buildIOSSpvc 还有
#   "libspvc.dylib already exists, skipping build" 的静默跳过 + vendor/SPIRV-Cross
#   是未初始化的 submodule），构建仍全绿而整个 SPIR-V→MSL 后端已被换掉。
#   本目标把 jar 内 natives/ios|ir1 的 libspvc.dylib 与树内 canonical 逐字节对齐。
#   SPVC_PROVENANCE=warn 可降级为告警。
check-spvc-provenance:
	python3 Natives/check_spvc_provenance.py

# ★ [SHADER-BLAZE3D-GROUP] blaze3d 整组自检（清单 vs 源目录 vs 闭包）——
#   只能在有 D:\CTF\client-26.2.jar 的机器上跑（Mac 出包线不需要它）。
blaze3d-group-check:
	python3 Natives/extract_blaze3d_group.py --check

# ★ [IRIS-INTEGRATE] 让 26.2-iris 吃 91 符号的 libmetallum_iris.dylib，而 26.3/26.1 继续吃
#   Frameworks/libmetallum.dylib（75 符号，含 getError/getStatus/get_last_error）—— 同一个包两条路线。
#   做法: 只把两条通道 MetalNativeBridge 的 System.loadLibrary("metallum") 改成 "metallum_iris"
#         （§6.7「共用文件名」的取舍用**改名接线**解，不覆盖、不重编 native）。
#   ★ 为什么**不**把 r10 类集搬进来: 本仓库 agent 的 classes262iris 比 r10 **更新** ——
#     逐类 javap 对比: 21 类不同(9 类只差调试信息)，其余 12 类全部是 agent 侧更大/更多
#     （SHADER-CAP GL_EXTENSIONS / shadowColorFormatsFrom / sodium(...GpuFormat[]) /
#       MetalNativeBridge 解包路径 /natives/ir1 vs r10 /natives/ios）。覆盖 = 功能回退。
#     详见 Natives/pack_iris_integrate.py 头部注释与 Natives/verify_iris_integrate.py。
#   ★ 幂等；校验用 make verify-iris-integrate（同一份断言也被 shader-glslang-check 调用）
shader-iris-integrate:
	python3 Natives/pack_iris_integrate.py

verify-iris-integrate:
	python3 Natives/verify_iris_integrate.py

check:
	$(foreach v, \
		$(shell echo "$(filter-out METHOD_% .% MAKEFILE_LIST MAKEFLAGS CURDIR,$(.VARIABLES))" | tr ' ' '\n' | sort), \
		$(if $(filter file,$(origin $(v))), \
		$(info $(shell printf "%-20s" "$(v)") = $(value $(v)))) \
	)

native: dep_mg swift
	echo '[Amethyst v$(VERSION)] native - start'
	mkdir -p $(WORKINGDIR)
	cd $(WORKINGDIR) && cmake \
		-DCMAKE_BUILD_TYPE=$(CMAKE_BUILD_TYPE) \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DAME_TABBAR_OBJ="$(SWIFT_OBJ)" \
		-DCONFIG_BRANCH="$(BRANCH)" \
		-DCONFIG_COMMIT="$(COMMIT)" \
		-DCONFIG_RELEASE=$(RELEASE) \
		-DAME_RENDERER_GAP_VGPU=$(RENDERER_GAP_EXTRAS) \
		..

	cmake --build $(WORKINGDIR) --config $(CMAKE_BUILD_TYPE) -j$(JOBS)
	#	--target awt_headless awt_xawt libOSMesaOverride.dylib tinygl4angle AngelAuraAmethyst
	rm $(WORKINGDIR)/libawt_headless.dylib
	echo '[Amethyst v$(VERSION)] native - end'

java:
	echo '[Amethyst v$(VERSION)] java - start'
	# 从 lwjgl-lib/ 源码构建 LWJGL jar（3.3.3 与 3.4.1）。
	# 默认跳过：预编译 jar 已在 git 中，普通构建与 CI 都不需要 Ant / JDK 8 /
	# 网络。只有 BUILD_LWJGL=1 时才真正从源码构建（本地改 LWJGL 时用）：
	#     BUILD_LWJGL=1 make java
	bash $(SOURCEDIR)/scripts/build_lwjgl.sh
	$(MAKE) -C JavaApp -j$(JOBS) BOOTJDK=$(BOOTJDK)
	echo '[Amethyst v$(VERSION)] java - end'

jre: native
	echo '[Amethyst v$(VERSION)] jre - start'
	mkdir -p $(SOURCEDIR)/depends
	cd $(SOURCEDIR)/depends; \
	$(call METHOD_JAVA_UNPACK,8,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre8-ios-aarch64.zip'); \
	$(call METHOD_JAVA_UNPACK,17,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre17-ios-aarch64.zip'); \
	$(call METHOD_JAVA_UNPACK,21,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre21-ios-aarch64.zip'); \
	$(call METHOD_JAVA_UNPACK,25,'https://assets.angelauramc.dev/openjdk/ios-arm64/jre25-ios-aarch64.zip'); \
	if [ -f "$(ls jre*.tar.xz)" ]; then rm $(SOURCEDIR)/depends/jre*.tar.xz; fi; \
	cd $(SOURCEDIR); \
	rm -rf $(SOURCEDIR)/depends/java-{8,17,21,25}-openjdk/{ASSEMBLY_EXCEPTION,bin,include,jre,legal,LICENSE,man,THIRD_PARTY_README,lib/{ct.sym,jspawnhelper,libjsig.dylib,src.zip,tools.jar}}; \
	$(call METHOD_DIRCHECK,$(OUTPUTDIR)/java_runtimes); \
	cp -R $(POJAV_JRE8_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp -R $(POJAV_JRE17_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp -R $(POJAV_JRE21_DIR) $(OUTPUTDIR)/java_runtimes; \
	cp -R $(POJAV_JRE25_DIR) $(OUTPUTDIR)/java_runtimes; \
	for _v in 8 17 21 25; do \
		if [ ! -f "$(OUTPUTDIR)/java_runtimes/java-$$_v-openjdk/lib/server/libjvm.dylib" ]; then \
			echo "★ [JRE-NEST] ERROR: 产物 java_runtimes/java-$$_v-openjdk 缺 lib/server/libjvm.dylib(层级不对或复制失败)"; ls -la "$(OUTPUTDIR)/java_runtimes/java-$$_v-openjdk" 2>/dev/null | head -20; exit 1; \
		fi; \
		echo "★ [JRE-NEST] java_runtimes/java-$$_v-openjdk OK"; \
	done; \
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-8-openjdk/lib; \
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-17-openjdk/lib;
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-21-openjdk/lib
	cp $(WORKINGDIR)/libawt_xawt.dylib $(OUTPUTDIR)/java_runtimes/java-25-openjdk/lib
	echo '[Amethyst v$(VERSION)] jre - end'

dep_mg:
	echo '[Amethyst v$(VERSION)] dep_mg - start'
	# ---------------------------------------------------------------------------
	# 3rdparty 版本对齐 —— 对齐参考仓库 Air 的 .gitmodules pin
	#
	# Air 的 Makefile 原文警告：
	#   "The shader conversion pipeline (desktop GLSL -> ESSL) is only validated
	#    against the submodule commits pinned in .gitmodules. A 3rdparty/ tree
	#    populated from arbitrary master snapshots produced ESSL that ANGLE-Metal
	#    rejects as empty (ERROR 1:1 syntax error on every shader, MC 26.x black
	#    screen). Force the pinned versions before configuring cmake, and fail
	#    loudly if they are still missing afterwards."
	#
	# 本仓库该目录是 vendored 而非 submodule，且 blob SHA 逐文件比对证明与 pin
	# 版本不同源：SPIRV-Cross 的 spirv_cross.cpp / spirv_cross.hpp /
	# spirv_glsl.cpp / spirv_glsl.hpp / spirv_cfg.cpp 全部不同；glslang 的
	# CHANGES.md / localintermediate.h / Versions.cpp / InfoSink.h /
	# CMakeLists.txt 也不同；xxhash 已一致故跳过。这是 MG + 26.3 黑屏与静默
	# 闪退的根因（转换产物 ESSL 不被 ANGLE-Metal 接受）。
	#
	# 与 Air 的 git submodule update --init 等价：构建期把这两个目录整体替换为
	# pin 快照（tar 直接解压到目标目录，规避 BSD cp -R 的目录覆盖陷阱）。哨兵
	# 文件 .air_pin_<sha> 避免重复下载；glslang 目录内的两个 .patch 先备份、替换
	# 后放回，交由紧随其后的补丁块应用（pin 版本本身不带防护补丁）。
	# 逃生阀：AMETHYST_MG_PIN_ALIGN=0 可跳过（离线调试用，产物未经验证）。
	# ---------------------------------------------------------------------------
	@mg3=$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty; \
	if [ "$${AMETHYST_MG_PIN_ALIGN:-1}" = "0" ]; then \
		echo '[dep_mg] WARNING: 3rdparty pin alignment skipped (AMETHYST_MG_PIN_ALIGN=0) -- MG build NOT validated'; \
	else \
		mkdir -p /tmp/mgpin_patches; \
		cp "$$mg3"/*.patch /tmp/mgpin_patches/ 2>/dev/null || true; \
		align3rd() { \
			mg_name=$$1; mg_url=$$2; mg_sha=$$3; \
			if [ -f "$$mg3/$$mg_name/.air_pin_$$mg_sha" ]; then \
				echo "[dep_mg] $$mg_name already pinned to $$mg_sha"; return 0; \
			fi; \
			echo "[dep_mg] $$mg_name: replacing vendored tree with pinned snapshot $$mg_sha"; \
			rm -rf "$$mg3/$$mg_name"; \
			mkdir -p "$$mg3/$$mg_name" || return 1; \
			curl -fsSL -o "/tmp/mgpin_$$mg_name.tgz" "$$mg_url" || { echo "ERROR: [dep_mg] $$mg_name pinned tarball download failed"; return 1; }; \
			tar -xzf "/tmp/mgpin_$$mg_name.tgz" -C "$$mg3/$$mg_name" --strip-components=1 || return 1; \
			touch "$$mg3/$$mg_name/.air_pin_$$mg_sha"; \
			echo "[dep_mg] $$mg_name pinned OK"; \
		}; \
		align3rd SPIRV-Cross https://codeload.github.com/KhronosGroup/SPIRV-Cross/tar.gz/a0fba56c34a6700f1724bf9b751da5b488a3775c a0fba56 || { echo 'ERROR: [dep_mg] 3rdparty pin alignment failed - cannot build a validated MobileGlues'; exit 1; }; \
		align3rd glslang https://codeload.github.com/KhronosGroup/glslang/tar.gz/f5f664dee8146676b04a332a7233959fc3ce9681 f5f664d || { echo 'ERROR: [dep_mg] 3rdparty pin alignment failed - cannot build a validated MobileGlues'; exit 1; }; \
		cp /tmp/mgpin_patches/*.patch "$$mg3/" 2>/dev/null || true; \
		echo '[dep_mg] 3rdparty pinned: SPIRV-Cross=a0fba56 glslang=f5f664d (xxhash already matches c2866db)'; \
	fi
	mkdir -p $(WORKINGDIR)/mobileglues
	# MG 自带 3rdparty/glslang（CMakeLists 里 add_subdirectory 从源码构建）。参考仓库在 cmake
	# 配置前对这份 glslang 打两个防护补丁（本仓库该目录是 vendored 而非 submodule，故用
	# --directory 定位）：
	#   * glslang-lvalue-nullguard.patch —— TParseContext::lValueErrorCheck 取 swizzle
	#     选择器聚合前不判空；iOS/arm64 上解析 MC 26.x 的 position_color 顶点着色器时该链
	#     SIGSEGV，启动/资源重载阶段直接杀进程（无 .ips、无 hs_err，表现为静默闪退）。
	#   * glslang-pool-zero-and-size-guards.patch —— GlslangToSpv::convertSwizzle 的
	#     constArray 尺寸判，必须打在 nullguard 之上。
	# Task 170 —— 补丁必须打在 src/main/cpp 这条真实路径上，不能走 MobileGlues-cpp。
	# MobileGlues-cpp 是 symlink -> src/main/cpp（本仓库 vendored 布局；参考仓库 Air 该处
	# 是实体目录）。git apply 拒绝穿过符号链接：
	#   error: affected file '.../MobileGlues-cpp/3rdparty/glslang/...' is beyond a symbolic link
	# 于是正向 --check 与反向 --check 双双失败，两个 MC 26.x position_color SIGSEGV 防护
	# 补丁被静默跳过 —— 构建日志里的
	#   "[dep_mg] WARNING: ... neither applies nor is applied -- MG glslang left UNPATCHED"
	# 正是它。pin 对齐又把已内置防护的 vendored 树整体换成上游 f5f664d（无防护），
	# 于是 libmobileglues 长期是在"零防护"状态下编出来的：26.3 资源重载期解析
	# position_color 顶点着色器时 SIGSEGV，无 hs_err、无 .ips、表现为静默闪退；
	# 26.2 不走这条链故不受影响。参考仓库 Air 因是实体目录，补丁正常落地，故其
	# MG + 26.3 全程可玩。
	# 顺序有依赖：nullguard 必须先于 pool-zero/size-guard（后者基于前者）。
	# 现在任一环失败即 exit 1 —— 绝不再静默产出无防护的 MG。
	@mg_3prel=Natives/external/MobileGlues/src/main/cpp/3rdparty; \
	mg_glrel=$$mg_3prel/glslang; \
	mg_pdir=$(SOURCEDIR)/$$mg_3prel; \
	mg_guard_src=$(SOURCEDIR)/$$mg_glrel/glslang/MachineIndependent/ParseHelper.cpp; \
	if grep -q "Defensive null guards" "$$mg_guard_src" 2>/dev/null; then \
		echo "[dep_mg] glslang guards already baked into the tree -- skip patches"; \
	else \
	for p in glslang-lvalue-nullguard.patch glslang-pool-zero-and-size-guards.patch; do \
		if [ ! -f "$$mg_pdir/$$p" ]; then echo "[dep_mg] ERROR: glslang patch $$p MISSING under $$mg_3prel -- MG would be built WITHOUT the MC 26.x position_color SIGSEGV guards"; exit 1; fi; \
		if git -C $(SOURCEDIR) apply --check -p1 --directory=$$mg_glrel "$$mg_pdir/$$p" >/dev/null 2>&1; then \
			git -C $(SOURCEDIR) apply -p1 --directory=$$mg_glrel "$$mg_pdir/$$p" && echo "[dep_mg] glslang patch $$p APPLIED" || { echo "[dep_mg] ERROR: $$p apply failed after a successful --check"; exit 1; }; \
		elif git -C $(SOURCEDIR) apply --check -R -p1 --directory=$$mg_glrel "$$mg_pdir/$$p" >/dev/null 2>&1; then \
			echo "[dep_mg] glslang patch $$p already applied"; \
		else \
			echo "[dep_mg] ERROR: glslang patch $$p neither applies nor is applied -- MG glslang would be left UNPATCHED (MC 26.x position_color SIGSEGV guards missing)"; exit 1; \
		fi; \
	done; \
	fi
	# CMAKE_BUILD_TYPE 必须显式给出：--config 对单配置生成器无效。缺失时 CMake 不追加
	# -O2/-DNDEBUG，整库 -O0 且 glslang/SPIRV-Cross/MG 的 assert() 全部激活 —— assert
	# 触发即 __assert_rtn->abort()，表现为直接进启动器错误界面且无 .ips/hs_err。
	cd $(WORKINGDIR)/mobileglues && cmake \
		-DMACOS="1" \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/

	# 额外显式构建 SPIRV / glslang-default-resource-limits 两个静态库：
	# dep_shader_shims 从源码链接 libshaderc_impl.dylib 时需要它们，
	# 而 mobileglues 自身只链接 glslang::glslang，不会带出这两个目标。
	cmake --build $(WORKINGDIR)/mobileglues --config RelWithDebInfo -j$(JOBS) --target mobileglues SPIRV glslang-default-resource-limits
	@mg_bindir=$(WORKINGDIR)/mobileglues/3rdparty/glslang; \
	mg_spirv_a=$$mg_bindir/SPIRV/libSPIRV.a; \
	[ -f "$$mg_spirv_a" ] || mg_spirv_a=$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/libraries/ios/libSPIRV.a; \
	mg_glslang_a=$$mg_bindir/glslang/libglslang.a; \
	[ -f "$$mg_glslang_a" ] || mg_glslang_a=$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/libraries/ios/libglslang.a; \
	mg_rl_a=$$mg_bindir/glslang/libglslang-default-resource-limits.a; \
	[ -f "$$mg_rl_a" ] || mg_rl_a=$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/libraries/ios/libglslang-default-resource-limits.a; \
	if [ -z "$$mg_spirv_a" ] || [ ! -f "$$mg_spirv_a" ] || [ -z "$$mg_glslang_a" ] || [ ! -f "$$mg_glslang_a" ] || [ -z "$$mg_rl_a" ] || [ ! -f "$$mg_rl_a" ]; then \
		echo "ERROR: glslang static libs unresolved (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a)"; \
		find $(WORKINGDIR)/mobileglues -type f -name "lib*.a" 2>/dev/null | head -20; \
		exit 1; \
	fi; \
	echo "[shaderc-impl] glslang static libs OK (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a)"
	cp $(WORKINGDIR)/mobileglues/libmobileglues*.dylib $(WORKINGDIR)/
	echo '[Amethyst v$(VERSION)] dep_mg - end'
# ---------------------------------------------------------------------------
# shaderc / spirv-cross 串行化垫片（对齐 Air Task 39/42/47/54）
#
# MG + MC 26.3 崩溃家族：资源重载阶段多个 32MB 栈 JVM 线程并发执行 glslang
# 编译，且 compiler_release 与 in-flight 编译竞态 —— 旧 RenderPearl 管线释放
# 时拆全局符号表/释放 glslang 池，编译中的 AST 内存被随后的字符串分配复用，
# ASCII 字节落进 SWIZZLE 节点 constArray 指针字段（偏移 +0xd8），最终在
# glslang::TParseContext::lValueErrorCheck+0x204 SIGSEGV 拖垮整个进程。
#
# 修复：真实库以 *_impl.dylib 落地，本垫片顶替原名并以 -reexport_library
# 透传全部符号；编译入口与 compiler/options 生命周期入口统一收进一把进程级
# 递归互斥锁，编译期接管 SIGSEGV/SIGBUS 做一次重试（崩溃网），从而把
# “进程死亡”降级为“单个 shader 编译失败 + 取证日志”。
#
# 本仓库 Natives/resources/Frameworks 下为预提交二进制，故在 WORKINGDIR 里
# 复制出 impl 名字并改写 LC_ID（reexport 记录的是 impl 的 install name，
# 否则会把构建期绝对路径烧进产物）。
# ---------------------------------------------------------------------------
# --- libshaderc_impl.dylib 的来源开关（A/B 用）-------------------------------
# SHADERC_IMPL_FROM_SOURCE=1 : Air Task 45 路径 —— Natives/shaderc_impl_glue.c
#                              覆在 dep_mg 刚编出的、已打 nullguard +
#                              pool-zero/size-guard 补丁的 glslang 静态库上。
# SHADERC_IMPL_FROM_SOURCE=0 : 垫片引入时的原始行为（3bed818be0）—— 直接用
#                              Natives/resources/Frameworks/ 下预提交二进制。
#                              默认 1：两份 hs_err（pid11633 / pid23353）证明两条
#                              路都崩，且是同一个病 —— 见下方符号围栏注释。围栏
#                              只能作用于我们自己链接的 impl，预编译二进制改不动，
#                              故默认走 from-source。变量仍可置 0 做整包 A/B。
SHADERC_IMPL_FROM_SOURCE ?= 1

ifeq ($(SHADERC_IMPL_FROM_SOURCE),1)
dep_shaderc_impl: dep_mg
	echo '[shaderc-impl] mode=from-source (Air Task 45) - start'
	# libshaderc_impl.dylib 从源码构建：Natives/shaderc_impl_glue.c 直接覆在
	# glslang C 接口上，链接 dep_mg 刚构建的（已打 nullguard + pool-zero/size-guard
	# 补丁的）静态库。预编译的 libshaderc.dylib 内含未打补丁的 glslang，其
	# TParseContext::lValueErrorCheck / convertSwizzle 会解引用被堆回收字节污染的
	# swizzle 选择器 constArray（+0xd8）而 SIGSEGV —— 正是 MC 26.3 崩溃家族的成因。
	mg_bindir=$(WORKINGDIR)/mobileglues/3rdparty/glslang; \
	mg_spirv_a=$$mg_bindir/SPIRV/libSPIRV.a; \
	[ -f "$$mg_spirv_a" ] || mg_spirv_a=$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/libraries/ios/libSPIRV.a; \
	mg_glslang_a=$$mg_bindir/glslang/libglslang.a; \
	[ -f "$$mg_glslang_a" ] || mg_glslang_a=$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/libraries/ios/libglslang.a; \
	mg_rl_a=$$mg_bindir/glslang/libglslang-default-resource-limits.a; \
	[ -f "$$mg_rl_a" ] || mg_rl_a=$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/libraries/ios/libglslang-default-resource-limits.a; \
	if [ -z "$$mg_spirv_a" ] || [ ! -f "$$mg_spirv_a" ] || [ -z "$$mg_glslang_a" ] || [ ! -f "$$mg_glslang_a" ] || [ -z "$$mg_rl_a" ] || [ ! -f "$$mg_rl_a" ]; then \
		echo "ERROR: glslang static libs unresolved - from-source shaderc impl cannot link"; \
		exit 1; \
	fi; \
	extra_glslang_libs=""; \
	for l in libOGLCompiler.a libOSDependent.a; do \
		if [ -f "$$mg_bindir/glslang/$$l" ]; then \
			extra_glslang_libs="$$extra_glslang_libs $$mg_bindir/glslang/$$l"; \
		fi; \
	done; \
	echo "[shaderc-impl] linking from-source impl (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a extra libs:$$extra_glslang_libs)"; \
	printf '_shaderc_*\n' > $(WORKINGDIR)/shaderc_impl.exports; \
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libshaderc_impl.dylib \
		$(FENCE_IMPL) \
		-I$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang \
		-o $(WORKINGDIR)/libshaderc_impl.dylib \
		$(SOURCEDIR)/Natives/shaderc_impl_glue.c \
		"$$mg_spirv_a" \
		"$$mg_glslang_a" \
		"$$mg_rl_a" \
		$$extra_glslang_libs \
		-lc++ || exit 1
	install_name_tool -id @rpath/libshaderc_impl.dylib $(WORKINGDIR)/libshaderc_impl.dylib || exit 1
	echo '[shaderc-impl] mode=from-source - end'
else
dep_shaderc_impl:
	echo '[shaderc-impl] mode=prebuilt (Natives/resources/Frameworks/libshaderc.dylib) - start'
	# $(WORKINGDIR) 由 dep_mg 内的 cmake 步骤创建；本分支不再依赖 dep_mg，
	# 故显式建目录（dep_openal_shim 同款处理），无副作用。
	mkdir -p $(WORKINGDIR)
	cp $(SOURCEDIR)/Natives/resources/Frameworks/libshaderc.dylib $(WORKINGDIR)/libshaderc_impl.dylib || exit 1
	install_name_tool -id @rpath/libshaderc_impl.dylib $(WORKINGDIR)/libshaderc_impl.dylib || exit 1
	echo '[shaderc-impl] mode=prebuilt - end'
endif

# --- 导出符号围栏（26.3 + MobileGL/MobileGlues SIGSEGV 根因）----------------
# 两份真机 hs_err 的崩溃栈都跨了两个镜像：
#   pid11633  C [libshaderc.dylib+0x3adafc]      spvtools::opt::Module::ForEachInst
#             C [libMobileGL-gles.dylib+0xfd3014] spvtools::Optimizer::Run
#   pid23353  C [libMobileGL-gles.dylib+0xaaff64] TGlslangToSpvTraverser::visitAggregate
#             C [libshaderc_impl.dylib+0x75230]   glslang::TIntermAggregate::traverse
# 渲染器镜像内嵌一份 glslang / SPIRV-Tools，shaderc 垫片内嵌另一份。两者都是
# C++ 头文件内联产生的 weak 符号，在 flat namespace 下被 dyld 合并成同一份：
# MobileGL 用自己那套 AST 建的节点，却跳进 shaderc 镜像里的 traverse/ForEachInst
# 去遍历 —— 布局与虚表不匹配，随即 SIGSEGV。
# 这与 impl 是预编译还是 from-source 无关（两份报告各占一条路），只取决于
# 这些符号有没有被导出进全局空间。
# shaderc_impl_glue.c 的公开面只有 shaderc_*（其余全 static），spvc_shim.c 只有
# spvc_*；glslang / spvtools / spirv-cross 的符号纯粹是静态库顺带泄漏出来的。
# 因此用 -exported_symbols_list 做白名单即可彻底切断串台，不影响垫片功能。
SHADER_SHIM_SYMBOL_FENCE ?= 1

ifeq ($(SHADER_SHIM_SYMBOL_FENCE),1)
FENCE_IMPL    := -Wl,-exported_symbols_list,$(WORKINGDIR)/shaderc_impl.exports
FENCE_SHADERC := -Wl,-exported_symbols_list,$(WORKINGDIR)/shaderc.exports
FENCE_SPVC    := -Wl,-exported_symbols_list,$(WORKINGDIR)/spvc.exports
else
FENCE_IMPL    :=
FENCE_SHADERC :=
FENCE_SPVC    :=
endif

# --- 垫片总开关 -------------------------------------------------------------
# SHADER_SHIMS=0 : dep_shader_shims 整体停用，Frameworks 下直接随包携带
#                  Natives/resources/Frameworks/ 里的原始预提交二进制 —— 即
#                  3bed818be0 引入垫片之前的状态（26.3 + MG 黑屏但不闪退）。
#                  payload 的 "cp -R Natives/resources/*" 负责把它们放进 app，
#                  本目标不产出任何同名 dylib，故不会发生覆盖。
SHADER_SHIMS ?= 1

ifeq ($(SHADER_SHIMS),1)
dep_shader_shims: dep_shaderc_impl dep_mg
	echo '[Amethyst v$(VERSION)] dep_shader_shims - start'
	cp $(SOURCEDIR)/Natives/resources/Frameworks/libspirv-cross-c-shared.0.dylib $(WORKINGDIR)/libspirv-cross-c-shared.0.impl.dylib || exit 1
	install_name_tool -id @rpath/libspirv-cross-c-shared.0.impl.dylib $(WORKINGDIR)/libspirv-cross-c-shared.0.impl.dylib || exit 1
	printf '_shaderc_*\n_ame_*\n' > $(WORKINGDIR)/shaderc.exports; \
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libshaderc.dylib \
		$(FENCE_SHADERC) \
		-Wl,-reexport_library,$(WORKINGDIR)/libshaderc_impl.dylib \
		-o $(WORKINGDIR)/libshaderc.dylib \
		$(SOURCEDIR)/Natives/shaderc_shim.c \
		$(SOURCEDIR)/Natives/shaderc_include.c \
		$(SOURCEDIR)/Natives/shaderc_sandbox.m || exit 1
	printf '_spvc_*\n_ame_*\n' > $(WORKINGDIR)/spvc.exports; \
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libspirv-cross-c-shared.0.dylib \
		$(FENCE_SPVC) \
		-Wl,-reexport_library,$(WORKINGDIR)/libspirv-cross-c-shared.0.impl.dylib \
		-o $(WORKINGDIR)/libspirv-cross-c-shared.0.dylib \
		$(SOURCEDIR)/Natives/spvc_shim.c || exit 1
	# -------------------------------------------------------------------
	# MobileGlues 的 SPIRV-Cross 与上面的 LWJGL spvc 垫片解耦
	#
	# MG 在 CMakeLists 里链接 libraries/ios/ 下预编译的 libspirv-cross-c-shared.dylib，
	# 其 LC_ID_DYLIB 与上面产出的 spvc 垫片同名。于是运行时 dyld 把 MG 的每一次
	# spvc_* 调用都解析进垫片 —— 即 32MB 栈派发线程 + 进程级主编译锁（日志里
	# "[spvc-shim] ... MG serialization ON" 就是它）。MC 26.3 的 shader 转换量远大于
	# 26.2，这条共享路径被压满后进程被拖死：静默闪退、无 hs_err、无崩溃报告；
	# 26.2 量小所以不受影响。（MG 自身跑得完转换 —— 垫片之前 26.3 + MG 是有声音的，
	# 只是黑屏。）
	#
	# 参考仓库 Air 的 MG 走 add_subdirectory(3rdparty/SPIRV-Cross) 并静态链接
	# spirv-cross-c，根本不存在这份共享库，因此不受影响。本仓库未纳入 SPIRV-Cross
	# submodule，故不改 MG 的链接方式，只在打包前把 libmobileglues 对 spirv-cross
	# 的依赖重定向到一份独立命名的真库；LWJGL 侧仍按原名加载垫片，32MB 栈与
	# 串行锁保护原样保留，行为完全不变。
	#
	# 依赖名由 otool 现场探测、不写死；源库按两条候选路径查找。任一环节缺失都只
	# 打印 WARN 并跳过，不会让构建失败。
	# -------------------------------------------------------------------
	for mg in $(WORKINGDIR)/libmobileglues*.dylib; do \
		[ -f "$$mg" ] || continue; \
		mg_dep=$$(otool -L "$$mg" | awk '/spirv-cross/ { print $$1; exit }'); \
		if [ -z "$$mg_dep" ]; then \
			echo "[dep_shader_shims] $$(basename "$$mg"): no spirv-cross dylib dependency (statically linked) -- skip"; \
			continue; \
		fi; \
		if [ ! -f "$(WORKINGDIR)/libspirv-cross-mg.dylib" ]; then \
			mg_src="$(SOURCEDIR)/Natives/external/MobileGlues/src/main/cpp/libraries/ios/libspirv-cross-c-shared.dylib"; \
			[ -f "$$mg_src" ] || mg_src="$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/libraries/ios/libspirv-cross-c-shared.dylib"; \
			if [ ! -f "$$mg_src" ]; then \
				echo "[dep_shader_shims] WARN: MG spirv-cross prebuilt not found -- skip decoupling"; \
				continue; \
			fi; \
			cp "$$mg_src" "$(WORKINGDIR)/libspirv-cross-mg.dylib" || exit 1; \
			install_name_tool -id @rpath/libspirv-cross-mg.dylib "$(WORKINGDIR)/libspirv-cross-mg.dylib" || exit 1; \
		fi; \
		install_name_tool -change "$$mg_dep" @rpath/libspirv-cross-mg.dylib "$$mg" || exit 1; \
		echo "[dep_shader_shims] MG spvc decoupled: $$mg_dep -> @rpath/libspirv-cross-mg.dylib"; \
	done
	echo '[Amethyst v$(VERSION)] dep_shader_shims - end'
else
dep_shader_shims:
	echo '[Amethyst v$(VERSION)] dep_shader_shims - DISABLED (SHADER_SHIMS=0): shipping prebuilt libshaderc.dylib + libspirv-cross-c-shared.0.dylib verbatim (pre-3bed818be0 state)'
endif



dep_openal_shim:
	# Task 129：OpenAL ALC_SOFT_system_events 兼容垫片（26.1.2 整合包崩溃修复）。
	# - 真库已 git mv 为 libopenal_impl.dylib（openal-soft 1.20.1 iOS 构建，无
	#   ALC_SOFT_system_events 扩展）；本目标构建同名垫片 libopenal.dylib：
	#   re-export impl 全部符号 + 覆盖 alcGetString/alcIsExtensionPresent 宣称扩展
	#   + 提供 alcEventIsSupportedSOFT/alcEventControlSOFT/alcEventCallbackSOFT 桩。
	# - 根因：MC 26.1.2 CallbackDeviceTracker.isSupported 无扩展守卫，直接调
	#   LWJGL 绑定 -> ICD 槽位 0 -> NPE 崩溃（26.3 有守卫故存活）。
	#   桩返回 ALC_FALSE 使 MC 干净回退 PollingDeviceTracker。
	# - 与 dep_shader_shims 同款模式：re-export 必须指向 impl 名（LC_ID 先修正），
	#   否则加载递归；本地函数定义优先于 re-export 符号（shaderc 先例）。
	echo '[Amethyst v$(VERSION)] dep_openal_shim - start'
	# Task 170：dep_openal_shim 与 dep_mg 同为 payload 前置、并行执行（gmake -j），
	# 而 $(WORKINGDIR) 由 dep_mg 内的 cmake 步骤创建 —— 本目标先跑到时该目录还不存在，
	# cp 直接失败（ci: "cp: directory .../Natives/build does not exist"）。
	# dep_shader_shims 有 dep_mg 依赖故不受影响；这里显式建目录即可，无副作用。
	mkdir -p $(WORKINGDIR)
	cp $(SOURCEDIR)/Natives/resources/Frameworks/libopenal_impl.dylib $(WORKINGDIR)/ || exit 1
	install_name_tool -id @rpath/libopenal_impl.dylib $(WORKINGDIR)/libopenal_impl.dylib || exit 1
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libopenal.dylib \
		-Wl,-reexport_library,$(WORKINGDIR)/libopenal_impl.dylib \
		-o $(WORKINGDIR)/libopenal.dylib \
		$(SOURCEDIR)/Natives/openal_shim.c || exit 1
	echo '[Amethyst v$(VERSION)] dep_openal_shim - end'

dep_angle_freeze:
	echo '[Amethyst v$(VERSION)] dep_angle_freeze - start'
	# Task 57 (画面分裂根治): 8-byte machine-code patch -- ANGLE Metal
	# WindowSurfaceMtl::checkIfLayerResized: expected size source switched from
	# bounds*contentsScale (poisoned by windowed-mode background-thread portrait
	# geometry, CALayer cross-thread split-brain) to the surface's own latched
	# mWidth/mHeight ([x19,#0x430/0x438]) -- surface size frozen at creation
	# geometry (creation reads always clean); transposition becomes physically
	# impossible; on drawableSize drift the enforcement branch re-writes the
	# frozen value back onto the layer. Idempotent; loud failure on byte
	# mismatch (ANGLE version drift guard); full root-cause chain in script
	# header comments (scripts/patch_angle_surface_freeze.py).
	# 补丁改写源文件后签名哈希失效 —— 打包时 ldid -S 全 app 递归重签覆盖。
	python3 $(SOURCEDIR)/scripts/patch_angle_surface_freeze.py \
		$(SOURCEDIR)/Natives/resources/Frameworks/libGLESv2.framework/libGLESv2 || exit 1
	echo '[Amethyst v$(VERSION)] dep_angle_freeze - end'

dep_sdl3_guard:
	echo '[Amethyst v$(VERSION)] dep_sdl3_guard - start'
	# Task 135 (controlify/JNA closure SIGBUS 源头根治): libSDL3.dylib
	# 入口机器码守卫 -- SDL_SetEventFilter / SDL_AddEventWatch 的非空回调指针
	# 一律置空/拒绝注册。controlify 经 JNA 回退加载本 Frameworks 的 iOS 版 SDL3
	# 后, 把 JNA/libffi closure (RW 不可执行 trampoline 页) 注册进 SDL 事件过滤
	# 器, SDL 调用即 SIGBUS。dlsym 层守卫对 LWJGL/FFM 解析路径有效, 但 JNA 解析
	# 路径仍可绕行; 本补丁把守卫下沉到 SDL 二进制自身, 与符号解析链路完全无关。
	# 启动器自身与 MC/LWJGL 均不使用 SDL 事件过滤器 (全仓 grep 验证), 零误伤;
	# 签名由打包时 ldid -S 全 app 重签覆盖 (dep_angle_freeze 同款流程)。
	# 幂等; 字节不匹配 (SDL3 版本漂移) 响亮失败。
	python3 $(SOURCEDIR)/scripts/patch_sdl3_eventfilter_guard.py \
		$(SOURCEDIR)/Natives/resources/Frameworks/libSDL3.dylib || exit 1
	echo '[Amethyst v$(VERSION)] dep_sdl3_guard - end'

# ---------------------------------------------------------------------------
# dep_sfpew —— SimpleFPEWrapper（MobileGL-Dev，LGPL-3.0）
#
# 与安卓 AngelAuraMC/Amethyst-Android @ feat/sfpew_angle 同款接入：SFPEW 位于
# 渲染器之上，为固定管线（GL 1.x）提供仿真，并把 GL 调用转发给真正的后端。
# 安卓侧＝Tools.useSFPEW 开关 + SFPEW_EGL 指向后端 EGL + 把 LWJGL 实际加载的库
# 换成 libSimpleFPEWrapper.so；iOS 侧渲染器列表里多一项 libSimpleFPEWrapper.dylib，
# JavaLauncher 把 SFPEW_EGL 设为被包裹的真后端（默认 libmobileglues.dylib）。
#
# 依赖 dep_mg：glslang / SPIRV-Cross / glm 直接复用 MobileGlues 的 vendored
# 3rdparty 树，而 dep_mg 会在同一棵树上做 pin 对齐并打两个防护补丁 —— 串行化
# 保证 SFPEW 编到的是同一份源码。
# ---------------------------------------------------------------------------
dep_sfpew: dep_mg
	echo '[Amethyst v$(VERSION)] dep_sfpew - start'
	# iOS 适配补丁（AppleClang 15 + deployment target 14.0 下才暴露的两个问题，
	# Linux/GCC 与 Android NDK 都不触发，故上游源码里没有处理）：
	#   1. fpe/types.h: glstate_t 的默认构造函数被隐式删除（匿名 union 内含
	#      带 NSDMI 的匿名 struct），fpe.cpp 的 no_context_state / make_unique 会炸
	#   2. fpe/fpe_shadergen.cpp: std::format 依赖 std::to_chars(float)，该重载在
	#      SDK 里标了 introduced=iOS 16.3，deployment target 14.0 下 "unavailable"。
	#      两层修复缺一不可：
	#        a) 编译期 —— 补丁第 3 步把全树 std::format 换成自研的
	#           fpefmt::format（写 fpe/fpe_format_compat.h，纯 ostringstream，
	#           不引用 <format> / to_chars）。必须整个换掉而不是只改浮点说明符：
	#           std::format 的模板展开**无条件**拉进 formatter_floating_point.h，
	#           实测 fpe_shadergen.cpp 的 std::format<unsigned,string,string>
	#           照样 error。CI 实测 -Wno-unguarded-availability{,-new} 压不住它
	#           （那两个旗标只管 warn 级，这条是 err 级），仅作顺手保留。
	#        b) 运行期 —— 补丁把唯一的 {:.1f} 换成 snprintf。保持 deployment
	#           target 14.0 使 to_chars 引用成为**弱**引用，旧系统解析为 NULL；
	#           不走到该路径就不会 NULL 解引用。（反过来把 target 抬到 16.3
	#           会变成强引用，iOS 14~16.2 真机 dyld 找不到符号直接启动崩。）
	# 与 patch_mobilegl_ios.py 同款约定：幂等 + 锚点校验，锚点不匹配即 exit 1，
	# 绝不静默打歪补丁编出坏库。必须在 cmake 之前跑（cmake 直接编译树内源码）。
	python3 $(SOURCEDIR)/Natives/patch_sfpew_ios.py $(SOURCEDIR)/Natives/external/SimpleFPEWrapper || exit 1
	mkdir -p $(WORKINGDIR)/sfpew
	cd $(WORKINGDIR)/sfpew && cmake \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCMAKE_CXX_FLAGS="-arch arm64" \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DSFPEW_MG_3RDPARTY="$(SOURCEDIR)/Natives/external/MobileGlues/src/main/cpp/3rdparty" \
		$(SOURCEDIR)/Natives/external/SimpleFPEWrapper/ > $(WORKINGDIR)/sfpew_build.log 2>&1 \
		|| { echo '[dep_sfpew] cmake configure FAILED -- tail:'; tail -n 120 $(WORKINGDIR)/sfpew_build.log; exit 1; }
	cmake --build $(WORKINGDIR)/sfpew --config RelWithDebInfo -j$(JOBS) --target SimpleFPEWrapper >> $(WORKINGDIR)/sfpew_build.log 2>&1 \
		|| { echo '[dep_sfpew] build FAILED -- tail:'; tail -n 200 $(WORKINGDIR)/sfpew_build.log; exit 1; }
	cp $(WORKINGDIR)/sfpew/libSimpleFPEWrapper.dylib $(WORKINGDIR)/ || exit 1
	echo '[Amethyst v$(VERSION)] dep_sfpew - end'

dep_mobilegl:
	@{ echo '== MobileGL build diagnostics =='; \
	  echo "  BUILD_MOBILEGL      = $(BUILD_MOBILEGL)"; \
	  echo "  MOBILEGL_SOURCE_DIR = $(MOBILEGL_SOURCE_DIR)"; \
	  echo "  source exists       = `test -d '$(MOBILEGL_SOURCE_DIR)' && echo yes || echo no`"; \
	  echo "  cmake               = `cmake --version 2>&1 | head -1`"; \
	  echo "  moltenvk            = `test -f '$(MOLTENVK_LIBRARY)' && echo yes || echo no` ($(MOLTENVK_LIBRARY))"; \
	  echo "  glslang dir         = `test -d '$(MOBILEGL_SOURCE_DIR)'/3rdparty/glslang && echo yes || echo no`"; \
	  echo "  spirv-tools dir     = `test -d '$(MOBILEGL_SOURCE_DIR)'/3rdparty/DiligentCore/ThirdParty/SPIRV-Tools && echo yes || echo no`"; \
	} 2>&1 | tee $(SOURCEDIR)/mobilegl-build.log
	@if [ '$(BUILD_MOBILEGL)' != '1' ]; then \
		if [ -f "$(MOBILEGL_DYLIB)" ] && [ -f "$(MOBILEGL_GLES_DYLIB)" ]; then \
			echo '[Amethyst v$(VERSION)] dep_mobilegl - using prebuilt dylibs in Natives/resources/Frameworks/'; \
			echo '[Amethyst v$(VERSION)] dep_mobilegl - (set BUILD_MOBILEGL=1 to rebuild from vendored source)'; \
		else \
			echo '[Amethyst v$(VERSION)] dep_mobilegl - skipped (set BUILD_MOBILEGL=1 to build from vendored source)'; \
		fi; \
	elif [ ! -d "$(MOBILEGL_SOURCE_DIR)" ]; then \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - skipped (source not found: $(MOBILEGL_SOURCE_DIR))'; \
	else \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - start'; \
		rm -f $(SOURCEDIR)/mobilegl-build.status; \
		{ echo '== build output =='; \
		} 2>&1 | tee -a $(SOURCEDIR)/mobilegl-build.log; \
		{ { $(MAKE) -f $(abspath $(lastword $(MAKEFILE_LIST))) dep_mobilegl_build; \
		    echo $$? > $(SOURCEDIR)/mobilegl-build.status; \
		  } 2>&1 | tee -a $(SOURCEDIR)/mobilegl-build.log; \
		}; \
		echo "== exit status = `cat $(SOURCEDIR)/mobilegl-build.status 2>/dev/null` ==" | tee -a $(SOURCEDIR)/mobilegl-build.log; \
		status=`cat $(SOURCEDIR)/mobilegl-build.status 2>/dev/null`; \
		if [ "$$status" != "0" ]; then \
			echo "[Amethyst v$(VERSION)] dep_mobilegl - BUILD FAILED (status=$$status), see $(SOURCEDIR)/mobilegl-build.log"; \
			exit 1; \
		fi; \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - end (log: $(SOURCEDIR)/mobilegl-build.log)'; \
	fi

# MobileGL（MobileGL-Dev，LGPL-3.0）：
# 2026-08-31 首次编译成功（libMobileGL.dylib / libMobileGL-gles.dylib），
# 产物已提交进仓库（55256e33）并关掉 BUILD_MOBILEGL，改源码时才重开。
# MobileGL 是桌面 OpenGL 实现，两个后端各一个二进制：
#   libMobileGL.dylib      -> DirectVulkan (GL -> Vulkan -> MoltenVK -> Metal)
#   libMobileGL-gles.dylib -> DirectGLES   (GL -> OpenGL ES)
# 运行时由环境变量 MOBILEGL_BACKEND_TYPE 选择（见 Natives/JavaLauncher.m）。
#
# 参考实现：Swung0x48/Amethyst-iOS 提交 dc57bfd3d2 "feat: add MobileGL renderer support"。
# 下面所有 perl 补丁都用 grep -q 做幂等守卫：上游若已自行修复则整条跳过，
# 不会因为源码变动而重复插入或报错。
dep_mobilegl_build:
	# asio 是 MobileGL 的 header-only 依赖，但 vendoring 它要额外 636 个文件
	#（约 5MB），而它只被 MG_Util/Async/ShaderCompilePool.cpp 用到，且 asio
	# 是极稳定的库 —— 故按 tag 在构建时拉取，不进仓库。
	# 用 tag（asio-1-38-2）而非分支：tag 不会被 force push，避免上游变动导致
	# 构建突然中断。以 post.hpp 是否存在为判据（而非目录），残缺目录也能补齐。
	if [ ! -f "$(MOBILEGL_SOURCE_DIR)/3rdparty/asio/include/asio/post.hpp" ]; then \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - fetching asio (asio-1-38-2)'; \
		rm -rf $(MOBILEGL_SOURCE_DIR)/3rdparty/asio; \
		git clone --depth 1 --branch asio-1-38-2 https://github.com/chriskohlhoff/asio.git \
			$(MOBILEGL_SOURCE_DIR)/3rdparty/asio || \
			echo '[Amethyst v$(VERSION)] dep_mobilegl - WARNING: asio fetch failed, build will likely fail'; \
	fi
	mkdir -p $(MOBILEGL_SOURCE_DIR)/3rdparty/glslang/External
	ln -sfn $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Tools $(MOBILEGL_SOURCE_DIR)/3rdparty/glslang/External/spirv-tools
	ln -sfn $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Headers $(MOBILEGL_SOURCE_DIR)/3rdparty/glslang/External/spirv-headers
	mkdir -p $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Tools/external
	ln -sfn $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Headers $(MOBILEGL_SOURCE_DIR)/3rdparty/DiligentCore/ThirdParty/SPIRV-Tools/external/spirv-headers
	grep -q 'Range1D() = default' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h || perl -i -pe 'if (/struct Range1D {/) { $$_ .= "        Range1D() = default; Range1D(SizeT s, SizeT e) : start(s), end(e) {}\n" }' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h
	grep -q '#include <type_traits>' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h || perl -i -pe 'if (index($$_, "#include <Includes.h>") == 0) { $$_ .= "#include <type_traits>\n" }' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h
	grep -q 'std::is_aggregate_v<T>' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h || perl -i -pe 's/        return std::make_unique\x3CT\x3E\(std::forward\x3CArgs\x3E\(args\)\.\.\.\);/        if constexpr (std::is_aggregate_v<T>) {\n            return std::unique_ptr<T>(new T{std::forward<Args>(args)...});\n        } else {\n            return std::make_unique<T>(std::forward<Args>(args)...);\n        }/' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_Util/Types.h
	grep -q 'BufferChange() = default' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_State/GLState/BufferState/BufferObject.h || perl -i -pe 'if (/struct BufferChange {/) { $$_ .= "        BufferChange() = default; BufferChange(Flags<BufferChangeBits> bits) : Bits(bits) {}\n" }' $(MOBILEGL_SOURCE_DIR)/MobileGL/MG_State/GLState/BufferState/BufferObject.h
	# AppleClang 15（Xcode 15.4）对 P0960（C++20 聚合体圆括号初始化）支持不完整，
	# 聚合体（DefaultFramebufferInfo/Error/Range1D/BufferChange）用 std::make_unique 圆括号
	# new T(args) 初始化会失败；但非聚合体（如 spirvtools Instruction 有 uint32_t 构造函数，
	# 调用方传 int）用 brace-init new T{args} 会 int->uint32_t narrowing。两者矛盾。
	# 方案：用 if constexpr + std::is_aggregate_v<T> 分派——
	#   聚合体  -> brace-init new T{args}（DefaultFramebufferInfo/Error 安全，不 narrowing）
	#   非聚合体-> make_unique 圆括号（调用构造函数，int->uint32_t 普通隐式转换不 narrowing）
	# Range1D/BufferChange 加了显式构造函数补丁后不再是聚合体（is_aggregate_v=false），
	# 走 make_unique 圆括号调用构造函数 Range1D(SizeT,SizeT)（int->size_t 普通转换）。
	# Range1D/BufferChange 构造函数补丁必须保留：GL_Buffer.cpp 等仍用 Range1D(x,y) 圆括号
	# 直接构造临时对象（不经 MakeUnique），若无构造函数则 C++17 聚合体圆括号语法不可用。
	# DirectGLES 后端在 iOS 上的启动崩溃：
	# ProbeTexture 无条件调用 glTexStorage*Multisample，
	# 而“指针非空”不等于上下文支持
	#（GLES 3.1+/3.2+），ANGLE/Metal 下会段错误。
	# 脚本带幂等与校验，源码变动时会明确报错而非错打。
	python3 $(SOURCEDIR)/Natives/patch_mobilegl_ios.py $(MOBILEGL_SOURCE_DIR)
	python3 $(SOURCEDIR)/Natives/patch_mobilegl_glslang.py $(MOBILEGL_SOURCE_DIR)
	mkdir -p $(WORKINGDIR)/mobilegl
	cd $(WORKINGDIR)/mobilegl && cmake \
		-DCMAKE_BUILD_TYPE=$(CMAKE_BUILD_TYPE) \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCMAKE_CXX_FLAGS="-arch arm64" \
		-DMOBILEGL_IOS=ON \
		-DMOBILEGL_BUILD_TEST=OFF \
		-DMOBILEGL_BUILD_BENCHMARK=OFF \
		-DMOBILEGL_BUILD_TRACE_REPLAY=OFF \
		-DMOBILEGL_VULKAN_LIBRARY="$(MOLTENVK_LIBRARY)" \
		$(MOBILEGL_SOURCE_DIR)
	cmake --build $(WORKINGDIR)/mobilegl --config $(CMAKE_BUILD_TYPE) -j$(JOBS) --target MobileGL
	# Natives/resources/Frameworks/libMoltenVK.dylib 取自 KhronosGroup/MoltenVK
	# v1.4.2 的 **iOS** 发布包（MoltenVK-ios.tar 内
	# dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK），
	# 仅按本仓库惯例把二进制重命名为 libMoltenVK.dylib，未改其 LC_ID_DYLIB。
	# 官方 iOS 动态库（1.2.x / 1.4.2 皆然）的 install name 仍是
	# @rpath/MoltenVK.framework/MoltenVK；而 libvulkan.1.dylib / libMobileGL.dylib
	# 记录的依赖是 @rpath/libMoltenVK.dylib，故重编 MobileGL 时必须把链接时
	# 记录的旧 install name -change 过来，否则设备上的 dyld 会去找并不存在的
	# MoltenVK.framework。升级方式见 scripts/update_moltenvk.sh。
	# 先探测再改：install_name_tool -change 找不到目标时会中断构建，不能无条件执行。
	if otool -l $(WORKINGDIR)/mobilegl/libMobileGL.dylib | grep -q 'MoltenVK.framework/MoltenVK'; then \
		install_name_tool -change @rpath/MoltenVK.framework/MoltenVK @rpath/libMoltenVK.dylib $(WORKINGDIR)/mobilegl/libMobileGL.dylib; \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - rewrote MoltenVK install name (legacy layout)'; \
	else \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - dependency already @rpath/libMoltenVK.dylib, no rewrite needed'; \
	fi
	if otool -l $(WORKINGDIR)/mobilegl/libMobileGL.dylib | grep -q 'path $(SOURCEDIR)/Natives/resources/Frameworks '; then \
		install_name_tool -delete_rpath $(SOURCEDIR)/Natives/resources/Frameworks $(WORKINGDIR)/mobilegl/libMobileGL.dylib; \
	fi
	if otool -l $(WORKINGDIR)/mobilegl/libMobileGL.dylib | grep -q 'path @loader_path '; then \
		install_name_tool -delete_rpath @loader_path $(WORKINGDIR)/mobilegl/libMobileGL.dylib; \
	fi
	install_name_tool -add_rpath @loader_path $(WORKINGDIR)/mobilegl/libMobileGL.dylib
	cp $(WORKINGDIR)/mobilegl/libMobileGL.dylib $(WORKINGDIR)/libMobileGL.dylib
	# GLES 变体是同一个二进制的副本，install_name 改掉以便两个 dylib 能同时加载
	cp $(WORKINGDIR)/mobilegl/libMobileGL.dylib $(WORKINGDIR)/libMobileGL-gles.dylib
	install_name_tool -id @rpath/libMobileGL-gles.dylib $(WORKINGDIR)/libMobileGL-gles.dylib
	# [Air Alternate / latestlog6+7] 恢复 libc++ 的 availability 语义。
	# MobileGL/CMakeLists.txt 的 iOS 分支为在 deployment target 14.0 下编过
	# C++23 <format>/<expected> 而定义了 _LIBCPP_DISABLE_AVAILABILITY，代价是
	# 把本该 weak import 的 libc++ 符号全部变成 **强引用**。重编产物因此强引用
	# iOS 16.3+ 才有的 std::__1::bad_expected_access<void> vtable 等符号，
	# iOS 14~16.2 的 dyld 在 dlopen 阶段直接拒绝加载：
	#   Symbol not found: __ZTVNSt3__119bad_expected_accessIvEE
	#     Expected in: /usr/lib/libc++.1.dylib
	# 逐个补符号是打地鼠（补完 9 个 to_chars 又冒出 vtable/RTTI）。这里做
	# 集合级后处理：把两个 dylib 对 libc++ 的 undefined 引用统一标记 weak
	# import，dyld 找不到就置 NULL 而不是拒绝加载 —— 与 libc++ availability
	# 的原生语义一致。兼容层提供的 9 个 defined to_chars 不受影响。
	# [v2 / latestlog8-10] v1 只改 LC_SYMTAB 的 N_WEAK_REF，但 ld64 生成的
	# LC_DYLD_CHAINED_FIXUPS 里 weak 由 import table 的独立位决定，dyld 根本
	# 不读 symtab -> 实测重编产物 226 个 libc++ 引用（含 3 个
	# bad_expected_access vtable/RTTI/what）仍是强引用，dlopen 直接失败。
	# v2 同时改写 fixup import table 与 symtab；payload 末尾还会对 app 内
	# 全部 Frameworks dylib 再跑一次 --all（幂等），这里只作早检。
	python3 $(SOURCEDIR)/scripts/weaken_libcxx_imports.py --self-test
	python3 $(SOURCEDIR)/scripts/weaken_libcxx_imports.py \
		$(WORKINGDIR)/libMobileGL.dylib $(WORKINGDIR)/libMobileGL-gles.dylib
	# [Air Alternate] 校验 iOS 低版本兼容层确实编进镜像：9 个浮点 to_chars
	# 必须已由 undefined 变成 defined，否则 iOS 15/16.2 仍会在 dlopen 阶段
	# 报 "Symbol not found: __ZNSt3__18to_charsEPcS0_d"。
	@if ! command -v nm >/dev/null; then \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - ERROR: nm unavailable'; exit 1; \
	fi; \
	if nm -u $(WORKINGDIR)/libMobileGL.dylib | grep -q 'to_chars'; then \
		echo '[Amethyst v$(VERSION)] dep_mobilegl - ERROR: floating to_chars still undefined'; \
		nm -u $(WORKINGDIR)/libMobileGL.dylib | grep 'to_chars'; \
		exit 1; \
	fi
	# 只读复核：两个产物里不能残留任何对 libc++ 的强引用。
	python3 $(SOURCEDIR)/scripts/weaken_libcxx_imports.py --verify \
		$(WORKINGDIR)/libMobileGL.dylib $(WORKINGDIR)/libMobileGL-gles.dylib
	# payload 的 "cp -R Natives/resources/*" 也会把 Frameworks 拷进 app，
	# 同步覆盖树内 vendored 二进制，保证两处一致、旧的坏二进制不会被装入。
	cp $(WORKINGDIR)/libMobileGL.dylib $(SOURCEDIR)/Natives/resources/Frameworks/libMobileGL.dylib
	cp $(WORKINGDIR)/libMobileGL-gles.dylib $(SOURCEDIR)/Natives/resources/Frameworks/libMobileGL-gles.dylib
	echo '[Amethyst v$(VERSION)] dep_mobilegl - iOS low-version compat VERIFIED'
	echo '[Amethyst v$(VERSION)] dep_mobilegl - end'

# Mithril（Uniaball/Mithril-Wrapper）：OpenGL 3.3 Core -> Vulkan -> MoltenVK -> Metal。
# 与 MobileGL 不同，Mithril 只发布预编译 dylib，本仓库不从源码编译。
# libmithril.dylib 已提交在 Natives/resources/Frameworks/ 下，payload 的
# `cp -R Natives/resources/*` 会自动把它打进 app 的 Frameworks 目录。
# 本目标只做存在性检查并给出提示；缺失时只告警不失败 —— Mithril 是可选渲染器，
# 且 LauncherPreferences.m 已按 dylib 是否存在决定是否显示该选项。
dep_mithril:
	if [ -f "$(MITHRIL_PREBUILT_DIR)/libmithril.dylib" ]; then \
		cp "$(MITHRIL_PREBUILT_DIR)/libmithril.dylib" $(SOURCEDIR)/Natives/resources/Frameworks/libmithril.dylib; \
		echo '[Amethyst v$(VERSION)] dep_mithril - installed from prebuilt/'; \
	elif [ -f "$(SOURCEDIR)/Natives/resources/Frameworks/libmithril.dylib" ]; then \
		echo '[Amethyst v$(VERSION)] dep_mithril - using existing Natives/resources/Frameworks/libmithril.dylib'; \
	else \
		echo '[Amethyst v$(VERSION)] dep_mithril - libmithril.dylib not found, Mithril renderer will be hidden'; \
		echo '[Amethyst v$(VERSION)] dep_mithril - run scripts/fetch_mithril.sh to download it'; \
	fi

assets:
	echo '[Amethyst v$(VERSION)] assets - start'
	if [ '$(IOS)' = '0' ] && [ '$(DETECTPLAT)' = 'Darwin' ]; then \
		mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/Base.lproj; \
		xcrun actool $(SOURCEDIR)/Natives/Assets.xcassets \
			--compile $(SOURCEDIR)/Natives/resources \
			--platform iphoneos \
			--minimum-deployment-target 14.0 \
			--app-icon AppIcon-Light \
			--output-partial-info-plist /dev/null || exit 1; \
	else \
		echo 'Due to the required tools not being available, you cannot compile the extras for Angel Aura Amethyst with an iOS device.'; \
	fi
	echo '[Amethyst v$(VERSION)] assets - end'

payload: native dep_mg dep_shader_shims dep_openal_shim dep_angle_freeze dep_sdl3_guard dep_nggl4es java jre assets shader-glslang-pack $(RENDERER_GAP_PAYLOAD_DEPS)
	echo '[Amethyst v$(VERSION)] payload - start'
	# ★ [26.4-SPVC] 打包前对账 jar 内 natives/ios|ir1 的 libspvc.dylib 与树内
	#   canonical（设备上真正生效的是 jar 里那份，见 check_spvc_provenance.py）。
	#   这里刻意**不阻断**主构建（改包链风险大），只把差异写进构建日志；
	#   要硬门禁用 make check-spvc-provenance / make shader-glslang-check。
	-python3 Natives/check_spvc_provenance.py || echo '[26.4-SPVC] WARNING: spvc native provenance mismatch -- see above (make check-spvc-provenance for the hard gate)'
	# Mithril / MobileGL 都是可选渲染器：这里用 - 前缀，任一失败都不阻断主构建。
	# 缺库时对应渲染器会在设置里自动隐藏（见 LauncherPreferences.m 的存在性过滤）。
	-$(MAKE) dep_mithril
	# 可选渲染器目标：BUILD_MOBILEGL=1 时重编失败必须让构建变红（兼容层是启动必需），
	# 其余情况沿用原来的"可选"语义，缺库只隐藏渲染器选项。
	@if [ '$(BUILD_MOBILEGL)' = '1' ]; then \
		$(MAKE) dep_mobilegl || exit 1; \
	else \
		$(MAKE) dep_mobilegl || true; \
	fi
	# SimpleFPEWrapper：不再用 - 前缀吞失败。之前"可选"开关把编译错误静默成
	# 绿色，产出的 IPA 里根本没有 libSimpleFPEWrapper.dylib（假绿）。现在 iOS
	# 适配补丁 + 编译旗标都已就位，构建失败必须响亮红 —— 与 dep_mg 同款约定。
	# dep_sfpew 内部会把 cmake/编译输出落盘并在失败时 tail 出来，方便定位。
	$(MAKE) dep_sfpew
	$(call METHOD_DIRCHECK,$(WORKINGDIR)/AngelAuraAmethyst.app/libs)
	$(call METHOD_DIRCHECK,$(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo)
	$(call METHOD_DIRCHECK,$(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo17)
	cp -R $(SOURCEDIR)/Natives/resources/en.lproj/LaunchScreen.storyboardc $(WORKINGDIR)/AngelAuraAmethyst.app/Base.lproj/ || exit 1
	cp -R $(SOURCEDIR)/Natives/resources/* $(WORKINGDIR)/AngelAuraAmethyst.app/ || exit 1
	cp $(WORKINGDIR)/*.dylib $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/ || exit 1
	# spirv-cross 软链接（防御性兜底）：若 MobileGlues 构建产出 libspirv-cross-c-shared.0.dylib，
	# 创建 libspirv-cross.dylib 软链接，兼容按 macOS 默认名加载的 native 代码。
	if [ -f "$(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/libspirv-cross-c-shared.0.dylib" ] && [ ! -f "$(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/libspirv-cross.dylib" ]; then \
		ln -sf libspirv-cross-c-shared.0.dylib $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/libspirv-cross.dylib; \
	fi

	# [fix/shim-overwrite-v2] 收尾: resources 里那几份"真库"必须在 shim 之后【再覆盖一次】。
	# 原因: WORKINGDIR/*.dylib 里有同名 shim(libshaderc.dylib 111KB / libspirv-cross-c-shared.0.dylib 52KB),
	# 会覆盖先拷进去的真库, 导致 SPIRV-Cross 拒绝 MSL 后端("Invalid backend", create_compiler backend=3 rc=-4)。
	# 同时断言: 若覆盖后这三份仍 < 1MB, 直接失败(避免再次静默出货)。
	# 注意: 只覆盖 spirv-cross 两份。libshaderc.dylib 必须保持 WORKINGDIR 产出的"垫片"版本——
	# 它导出 ame_master_compile_lock, spvc_shim/shaderc_shim 靠 dlopen+dlsym 拿这个符号做跨库编译总锁;
	# 换成真库会拿不到锁 -> MG/shaderc 并发进 glslang -> SIGSEGV(glslang::TParseContext::lValueErrorCheck)。
	# 真实现放在 libshaderc_impl.dylib(垫片按 @loader_path 解析), 不受影响。
	for f in libspirv-cross-c-shared.0.dylib libspirv-cross.dylib; do 		if [ -f "$(SOURCEDIR)/Natives/resources/Frameworks/$$f" ]; then 			cp -f "$(SOURCEDIR)/Natives/resources/Frameworks/$$f" "$(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/$$f" || exit 1; 		fi; 		sz=$$(stat -f%z "$(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/$$f" 2>/dev/null || echo 0); 		if [ "$$sz" -lt 1048576 ]; then echo "ERROR: $$f is only $$sz bytes after restore"; exit 1; fi; 	done
		cp -R $(SOURCEDIR)/JavaApp/libs/others/* $(WORKINGDIR)/AngelAuraAmethyst.app/libs/ || exit 1
	cp $(SOURCEDIR)/JavaApp/build/launcher.jar $(SOURCEDIR)/JavaApp/build/patchjna_agent.jar $(SOURCEDIR)/JavaApp/build/patchsvc.jar $(SOURCEDIR)/JavaApp/build/mojang-stubs.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/ || exit 1
	# LWJGL 以双版本 jar 发布，由启动器按 MC 版本在运行时选择其一。
	# 必须放进各自的 libs/lwjgl-<ver>/ 子目录：若平铺进 libs/，会被 classpath 中
	# 的 libs/* 一并加载，使 3.3.3 与 3.4.1 的同名类同时进入 classpath 造成冲突。
	mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-333 $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-341; \
	cp $(SOURCEDIR)/JavaApp/build/lwjgl-333.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-333/lwjgl.jar || exit 1
	cp $(SOURCEDIR)/JavaApp/build/lwjgl-341.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/lwjgl-341/lwjgl.jar || exit 1
	cp -R $(SOURCEDIR)/JavaApp/libs/caciocavallo/* $(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo || exit 1
	cp -R $(SOURCEDIR)/JavaApp/libs/caciocavallo17/* $(WORKINGDIR)/AngelAuraAmethyst.app/libs_caciocavallo17 || exit 1
	# Copy TouchController static library if available
	if [ -f "$(SOURCEDIR)/TouchController/libproxy_server_ios.a" ]; then \
		mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks; \
		cp $(SOURCEDIR)/TouchController/libproxy_server_ios.a $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/ || exit 1; \
		echo '[Amethyst v$(VERSION)] Copied TouchController device library'; \
	elif [ -f "$(SOURCEDIR)/TouchController/libproxy_server_ios_simulator.a" ]; then \
		mkdir -p $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks; \
		cp $(SOURCEDIR)/TouchController/libproxy_server_ios_simulator.a $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks/ || exit 1; \
		echo '[Amethyst v$(VERSION)] Copied TouchController simulator library'; \
	else \
		echo '[Amethyst v$(VERSION)] TouchController library not found, skipping'; \
	fi
	# [iOS15-COMPAT / latestlog8-10] 全量后处理（在 ldid 重签之前，签名会覆盖改写）。
	# 上面的 cp -R Natives/resources/*、cp WORKINGDIR/*.dylib 与 shim-overwrite
	# 收尾都已跑完，此刻 app/Frameworks 内就是最终进包的所有 dylib：既有
	# vendored 预编译库（MoltenVK / mithril / glslang / shaderc / spirv-cross /
	# OSMesa / lwjgl_vma / metallum …），也有本次重编的 MobileGL×2、
	# mobileglues、SimpleFPEWrapper。实测 30 个 vendored 库里 24 个含 chained
	# fixups、libc++ undefined 合计 1514 个且全为强引用 —— 只处理 MobileGL
	# 或只改 LC_SYMTAB 都会漏。这里按 dyld 真正读取的 fixup import table
	# 集合级统一 weak 化，并把异常高的 minos 降到 deployment target。
	python3 $(SOURCEDIR)/scripts/weaken_libcxx_imports.py --self-test || exit 1
	python3 $(SOURCEDIR)/scripts/weaken_libcxx_imports.py --all $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks || exit 1
	python3 $(SOURCEDIR)/scripts/weaken_libcxx_imports.py --verify --all $(WORKINGDIR)/AngelAuraAmethyst.app/Frameworks || exit 1
	$(call METHOD_DIRCHECK,$(OUTPUTDIR)/Payload)
	cp -R $(WORKINGDIR)/AngelAuraAmethyst.app $(OUTPUTDIR)/Payload
	if [ '$(SLIMMED_ONLY)' != '1' ]; then \
		cp -R $(OUTPUTDIR)/java_runtimes $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app; \
	fi
	ldid -S $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app; \
	if [ '$(TROLLSTORE_JIT_ENT)' == '1' ]; then \
		ldid -S$(SOURCEDIR)/entitlements.trollstore.xml $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	elif [ '$(PLATFORM)' == '6' ]; then \
		ldid -S$(SOURCEDIR)/entitlements.codesign.xml $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	else \
		ldid -S$(SOURCEDIR)/entitlements.sideload.xml $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	fi
	chmod -R 755 $(OUTPUTDIR)/Payload
	# 总是运行平台重打标（对齐 Ynnyny 仓库）—— 对已 iOS 标记的 Mach-O 是幂等的，
	# 但能捕获从 Maven 直接拉取的新 dylib（如 3.3.5 lwjgl-stb），它们 ship 时
	# platform=macos，iOS dyld 会静默拒绝加载，导致 LWJGL 抛 UnsatisfiedLinkError。
	# 原本用 [ PLATFORM != 2 ] 守卫的假设是所有 commit 的 dylib 都已 iOS 标记，
	# 这个假设在同步 Ynnyny 顶层 dylib 时被打破。
	$(call METHOD_MACHO,$(OUTPUTDIR)/Payload/AngelAuraAmethyst.app,$(call METHOD_CHANGE_PLAT,$(PLATFORM),$$file)); \
	$(call METHOD_MACHO,$(OUTPUTDIR)/java_runtimes,$(call METHOD_CHANGE_PLAT,$(PLATFORM),$$file));
	echo '[Amethyst v$(VERSION)] payload - end'

deploy:
	echo '[Amethyst v$(VERSION)] deploy - start'
	cd $(OUTPUTDIR); \
	if [ '$(IOS)' = '1' ]; then \
		ldid -S $(WORKINGDIR)/AngelAuraAmethyst.app || exit 1; \
		ldid -S$(SOURCEDIR)/entitlements.trollstore.xml $(WORKINGDIR)/AngelAuraAmethyst.app/AngelAuraAmethyst || exit 1; \
		sudo mv $(WORKINGDIR)/*.dylib $(PREFIX)Applications/AngelAuraAmethyst.app/Frameworks/ || exit 1; \
		sudo mv $(WORKINGDIR)/AngelAuraAmethyst.app/AngelAuraAmethyst $(PREFIX)Applications/AngelAuraAmethyst.app/AngelAuraAmethyst || exit 1; \
		sudo mv $(SOURCEDIR)/JavaApp/build/launcher.jar $(SOURCEDIR)/JavaApp/build/patchjna_agent.jar $(SOURCEDIR)/JavaApp/build/patchsvc.jar $(PREFIX)Applications/AngelAuraAmethyst.app/libs/ || exit 1; \
		sudo mkdir -p $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-333 $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-341 || exit 1; \
		sudo mv $(SOURCEDIR)/JavaApp/build/lwjgl-333.jar $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-333/lwjgl.jar || exit 1; \
		sudo mv $(SOURCEDIR)/JavaApp/build/lwjgl-341.jar $(PREFIX)Applications/AngelAuraAmethyst.app/libs/lwjgl-341/lwjgl.jar || exit 1; \
		cd $(PREFIX)Applications/AngelAuraAmethyst.app/Frameworks || exit 1; \
		sudo chown -R 501:501 $(PREFIX)Applications/AngelAuraAmethyst.app/* || exit 1; \
	elif [ '$(IOS)' = '0' ] && [ '$(DETECTPLAT)' = 'Darwin' ]; then \
		if [ '$(PLATFORM)' != '2' ] || [ '$(TEAMID)' = '-1' ] || [ '$(SIGNING_TEAMID)' = '-1' ] || [ '$(PROVISIONING)' = '-1' ]; then \
			echo 'Configuration not supported for deploy recipe.'; \
		else \
			$(call METHOD_PACKAGE); \
			if [ '$(SLIMMED_ONLY)' = '0' ]; then \
				open $(OUTPUTDIR)/com.airalternate.amethyst-$(VERSION)-$(PLATFORM_NAME).ipa; \
			else \
				open $(OUTPUTDIR)/com.airalternate.amethyst.slimmed-$(VERSION)-$(PLATFORM_NAME).ipa; \
			fi; \
		fi; \
	else \
		echo 'Device not supported for deploy recipe.'; \
	fi
	echo '[Amethyst v$(VERSION)] deploy - end'

package: payload
	echo '[Amethyst v$(VERSION)] package - start'
	if [ '$(TEAMID)' != '-1' ] && [ '$(SIGNING_TEAMID)' != '-1' ] && [ -f '$(PROVISIONING)' ] && [ '$(DETECTPLAT)' = 'Darwin' ]; then \
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n	<key>application-identifier</key>\n	<string>$(TEAMID).com.airalternate.amethyst</string>\n	<key>com.apple.developer.team-identifier</key>\n	<string>$(TEAMID)</string>\n	<key>get-task-allow</key>\n	<true/>\n	<key>keychain-access-groups</key>\n	<array>\n	<string>$(TEAMID).*</string>\n	<string>com.apple.token</string>\n	</array>\n	<key>com.apple.developer.kernel.extended-virtual-addressing</key>\n	<true/>\n	<key>com.apple.developer.kernel.increased-memory-limit</key>\n	<true/>\n</dict>\n</plist>' > entitlements.codesign.xml; \
		$(MAKE) codesign; \
		rm -rf entitlements.codesign.xml; \
	else \
		echo 'Skipped codesigning. If not intentional, check your variables.'; \
	fi
	cd $(OUTPUTDIR); \
	$(call METHOD_PACKAGE); \
	zip --symlinks -r $(OUTPUTDIR)/java_runtimes.zip java_runtimes; \
	echo '[Amethyst v$(VERSION)] package - end'

dsym: payload
	echo '[Amethyst v$(VERSION)] dsym - start'
	dsymutil --arch arm64 $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst; \
	rm -rf $(OUTPUTDIR)/AngelAuraAmethyst.dSYM; \
	mv $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/AngelAuraAmethyst.dSYM $(OUTPUTDIR)/AngelAuraAmethyst.dSYM
	echo '[Amethyst v$(VERSION)] dsym - end'
	
codesign:
	echo '[Amethyst v$(VERSION)] codesign - start'
	cp '$(PROVISIONING)' $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/embedded.mobileprovision
	$(call METHOD_MACHO,$(OUTPUTDIR)/Payload/AngelAuraAmethyst.app,$(call METHOD_CODESIGN,$(SIGNING_TEAMID),$$file))
	$(call METHOD_MACHO,$(OUTPUTDIR)/java_runtimes,$(call METHOD_CODESIGN,$(SIGNING_TEAMID),$$file))
	echo '[Amethyst v$(VERSION)] codesign - end'

clean:
	echo '[Amethyst v$(VERSION)] clean - start'
	rm -rf $(WORKINGDIR)
	rm -rf JavaApp/build
	rm -rf $(OUTPUTDIR)
	echo '[Amethyst v$(VERSION)] clean - end'

.PHONY: all clean check native java jre package dsym deploy help swift shader-glslang-pack shader-glslang-check shader-iris-integrate verify-iris-integrate check-spvc-provenance


# ============================================================================
# ★ [RENDERER-GAP] 新增渲染器构建目标（来自 Gsjsjzhznsz/Air-Minecraft-iOS-Launcher）。
#   dep_gl4eszl2 / dep_virgl 默认不参与 `all`/`payload` 依赖图；只有
#   RENDERER_GAP_EXTRAS=1 时 payload 才追加它们（见文件顶部 RENDERER_GAP_PAYLOAD_DEPS）。
#   dep_nggl4es（"Krypton Wrapper"）例外：无条件挂在 payload 上，每次都构建。
#   亦可单独调用：
#     make dep_nggl4es
#     make RENDERER_GAP_EXTRAS=1 dep_gl4eszl2 dep_virgl
#   产出的 *.dylib 落在 $(WORKINGDIR)/，由 payload 的 "cp $(WORKINGDIR)/*.dylib"
#   自动带进 app 的 Frameworks；LauncherPreferences 的存在性过滤随后才会显示选项。
# ============================================================================

# --- dep_nggl4es：NG-GL4ES（"Krypton Wrapper"，BZLZHH/NG-GL4ES，MIT）-----------
# ZalithLauncher 2 用的 gl4es 分支：能处理更高级的着色器、几乎全 MC 版本可跑。
# vendored 源码在 ThirdParty/NG-GL4ES（见其 CMakeLists 的 PROVENANCE 头）。
# 作为独立 cmake 树构建，链接 dep_mg 出来的 glslang 静态库（pin f5f664d 15.0.0 +
# lvalue-nullguard + pool-zero/size-guards 双崩溃补丁，继承崩溃家族修复；NG 自带的
# 15.4 头已从树中移除，防头/库漂移）与预编译的 SPIRV-Cross C API impl dylib。
# 产出 libnggl4es.dylib，由 payload 的 "cp $(WORKINGDIR)/*.dylib" 随包带走。
# 依赖 dep_mg：glslang 静态库必须先就位（-j 并行下无序，需目标级先决条件）。
# ★ 无条件挂在 payload 上（用户可见的一等渲染器，不受 RENDERER_GAP_EXTRAS 控制）。
dep_nggl4es: dep_mg
	echo '[Amethyst v$(VERSION)] dep_nggl4es - start'
	mg_bindir=$(WORKINGDIR)/mobileglues/3rdparty/glslang; \
	mg_spirv_a=$$mg_bindir/SPIRV/libSPIRV.a; \
	[ -f "$$mg_spirv_a" ] || mg_spirv_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libSPIRV.a -print -quit 2>/dev/null); \
	mg_glslang_a=$$mg_bindir/glslang/libglslang.a; \
	[ -f "$$mg_glslang_a" ] || mg_glslang_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang.a -print -quit 2>/dev/null); \
	mg_rl_a=$$mg_bindir/glslang/libglslang-default-resource-limits.a; \
	[ -f "$$mg_rl_a" ] || mg_rl_a=$$(find $(WORKINGDIR)/mobileglues -type f -name libglslang-default-resource-limits.a -print -quit 2>/dev/null); \
	if [ -z "$$mg_spirv_a" ] || [ ! -f "$$mg_spirv_a" ] || [ -z "$$mg_glslang_a" ] || [ ! -f "$$mg_glslang_a" ] || [ -z "$$mg_rl_a" ] || [ ! -f "$$mg_rl_a" ]; then \
		echo "ERROR: [nggl4es] glslang static libs unresolved (spirv=$$mg_spirv_a glslang=$$mg_glslang_a rl=$$mg_rl_a) - dep_mg must run first"; \
		exit 1; \
	fi; \
	extra_glslang_libs=""; \
	for l in libOGLCompiler.a libOSDependent.a; do \
		if [ -f "$$mg_bindir/glslang/$$l" ]; then \
			extra_glslang_libs="$$extra_glslang_libs;$$mg_bindir/glslang/$$l"; \
		fi; \
	done; \
	ngg_libs="$$mg_spirv_a;$$mg_glslang_a;$$mg_rl_a$$extra_glslang_libs"; \
	echo "[nggl4es] linking against glslang statics: $$ngg_libs"; \
	mkdir -p $(WORKINGDIR)/nggl4es; \
	cd $(WORKINGDIR)/nggl4es && cmake \
		-DMACOS="1" \
		-DCMAKE_CROSSCOMPILING=true \
		-DCMAKE_SYSTEM_NAME=Darwin \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DCMAKE_C_FLAGS="-arch arm64" \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DNGGL4ES_GLSLANG_INCLUDE="$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty;$(SOURCEDIR)/Natives/external/MobileGlues/MobileGlues-cpp/3rdparty/glslang" \
		-DNGGL4ES_GLSLANG_LIBS="$$ngg_libs" \
		-DNGGL4ES_SPVC_IMPL="$(SOURCEDIR)/Natives/resources/Frameworks/libspirv-cross-c-shared.0.impl.dylib" \
		-DNGGL4ES_FRAMEWORK_DIR="$(SOURCEDIR)/Natives/resources/Frameworks" \
		$(SOURCEDIR)/ThirdParty/NG-GL4ES/ || exit 1
	cmake --build $(WORKINGDIR)/nggl4es --config RelWithDebInfo -j$(JOBS) --target nggl4es || exit 1
	cp $(WORKINGDIR)/nggl4es/libnggl4es.dylib $(WORKINGDIR)/ || exit 1
	echo '[Amethyst v$(VERSION)] dep_nggl4es - end'

dep_gl4eszl2:
	@echo '[Amethyst v$(VERSION)] [RENDERER-GAP] dep_gl4eszl2 - start'
	# GL4ESZL2（PojavLauncherTeam/gl4es_extra_extra）—— ZL2 经典版 "gl4es"。
	# 纯 C 字符串改写式 GLSL→ESSL（shaderconv.c），无 glslang/SPIRV-Cross 依赖，
	# 故为独立目标（不依赖 dep_mg，不会与 glslang 静态库竞争）。
	mkdir -p $(WORKINGDIR)/gl4eszl2; \
	cd $(WORKINGDIR)/gl4eszl2 && cmake \
	-DMACOS="1" \
	-DCMAKE_CROSSCOMPILING=true \
	-DCMAKE_SYSTEM_NAME=Darwin \
	-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
	-DCMAKE_OSX_SYSROOT="$(SDKPATH)" \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
	-DCMAKE_C_FLAGS="-arch arm64" \
	-DCMAKE_BUILD_TYPE=RelWithDebInfo \
	-DGL4ESZL2_FRAMEWORK_DIR="$(SOURCEDIR)/Natives/resources/Frameworks" \
	$(SOURCEDIR)/ThirdParty/gl4es_extra_extra/ || exit 1
	cmake --build $(WORKINGDIR)/gl4eszl2 --config RelWithDebInfo -j$(JOBS) --target gl4eszl2 || exit 1
	cp $(WORKINGDIR)/gl4eszl2/libgl4eszl2.dylib $(WORKINGDIR)/ || exit 1
	@echo '[Amethyst v$(VERSION)] [RENDERER-GAP] dep_gl4eszl2 - end'

# VirGLRenderer(<=26.2)（ZL2 移植）三件套：
#  1. libepoxy            —— vendored Natives/external/libepoxy（iOS 补丁：dlopen 指向 ANGLE 框架）
#  2. libvtestserver.dylib—— vendored virglrenderer 1.3.0（静态链 epoxy）
#  3. libOSMesaVirgl.dylib—— Mesa 25.0.7（下载 tar.xz + patches/mesa-215-osmesa-virgl.patch）
# 快路径：三件套已存在于 Frameworks 时直接跳过整链构建。
VIRGL_MESA_VERSION ?= 25.0.7
dep_virgl:
	@if [ -f "$(SOURCEDIR)/Natives/resources/Frameworks/libOSMesaVirgl.dylib" ] && \
	    [ -f "$(SOURCEDIR)/Natives/resources/Frameworks/libvtestserver.dylib" ] && \
	    [ -f "$(SOURCEDIR)/Natives/resources/Frameworks/libepoxy.dylib" ]; then \
		echo '[Amethyst v$(VERSION)] [RENDERER-GAP] dep_virgl - cached (Frameworks prebuilts present)'; \
		cp $(SOURCEDIR)/Natives/resources/Frameworks/libOSMesaVirgl.dylib \
		   $(SOURCEDIR)/Natives/resources/Frameworks/libvtestserver.dylib \
		   $(SOURCEDIR)/Natives/resources/Frameworks/libepoxy.dylib $(WORKINGDIR)/; \
		exit 0; \
	fi
	@echo '[Amethyst v$(VERSION)] [RENDERER-GAP] dep_virgl - start'
	printf '%s\n' \
		'[binaries]' \
		"c = 'clang'" \
		"cpp = 'clang++'" \
		"ar = 'ar'" \
		"strip = 'strip'" \
		'[properties]' \
		"c_args = ['-arch','arm64','-miphoneos-version-min=14.0','-fno-common','-isysroot','$(SDKPATH)','-I$(SOURCEDIR)/Natives/external/mesa']" \
		"cpp_args = ['-arch','arm64','-miphoneos-version-min=14.0','-fno-common','-isysroot','$(SDKPATH)','-I$(SOURCEDIR)/Natives/external/mesa']" \
		"c_link_args = ['-arch','arm64','-miphoneos-version-min=14.0','-isysroot','$(SDKPATH)']" \
		"cpp_link_args = ['-arch','arm64','-miphoneos-version-min=14.0','-isysroot','$(SDKPATH)']" \
		'[host_machine]' \
		"system = 'darwin'" \
		"cpu_family = 'aarch64'" \
		"cpu = 'aarch64'" \
		"endian = 'little'" \
		> $(WORKINGDIR)/virgl-cross.txt
	rm -rf $(WORKINGDIR)/virgl-epoxy $(WORKINGDIR)/virgl-prefix
	meson setup $(WORKINGDIR)/virgl-epoxy $(SOURCEDIR)/Natives/external/libepoxy \
		--cross-file $(WORKINGDIR)/virgl-cross.txt \
		-Dglx=no -Degl=yes -Dx11=false -Dtests=false \
		-Ddefault_library=static --prefix=$(WORKINGDIR)/virgl-prefix || exit 1
	ninja -C $(WORKINGDIR)/virgl-epoxy install || exit 1
	test -f $(WORKINGDIR)/virgl-prefix/lib/libepoxy.a || { echo 'ERROR: libepoxy.a missing'; exit 1; }
	rm -rf $(WORKINGDIR)/virgl-renderer
	PKG_CONFIG_PATH=$(WORKINGDIR)/virgl-prefix/lib/pkgconfig \
	meson setup $(WORKINGDIR)/virgl-renderer $(SOURCEDIR)/Natives/external/virglrenderer \
		--cross-file $(WORKINGDIR)/virgl-cross.txt \
		-Dplatforms=egl -Dvenus=false -Dvulkan-dload=false -Dtests=false \
		-Ddefault_library=static || exit 1
	ninja -C $(WORKINGDIR)/virgl-renderer || exit 1
	test -f $(WORKINGDIR)/virgl-renderer/vtest/libvtest.a || { echo 'ERROR: libvtest.a missing'; exit 1; }
	test -f $(WORKINGDIR)/virgl-renderer/libvirglrenderer.a || { echo 'ERROR: libvirglrenderer.a missing'; exit 1; }
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-install_name @rpath/libvtestserver.dylib \
		-o $(WORKINGDIR)/libvtestserver.dylib \
		-Wl,-force_load,$(WORKINGDIR)/virgl-renderer/vtest/libvtest.a \
		-Wl,-force_load,$(WORKINGDIR)/virgl-renderer/libvirglrenderer.a \
		$(WORKINGDIR)/virgl-prefix/lib/libepoxy.a \
		-lc++ || exit 1
	install_name_tool -id @rpath/libvtestserver.dylib $(WORKINGDIR)/libvtestserver.dylib || exit 1
	mkdir -p $(SOURCEDIR)/depends/virgl
	cd $(SOURCEDIR)/depends/virgl; \
		if [ ! -f mesa-$(VIRGL_MESA_VERSION)/src/gallium/targets/osmesa/.task215_patched ]; then \
			wget_ok=0; \
			for attempt in 1 2 3 4 5; do \
				if wget "https://archive.mesa3d.org/mesa-$(VIRGL_MESA_VERSION).tar.xz" --timeout=90 --tries=2 --retry-connrefused -O mesa-$(VIRGL_MESA_VERSION).tar.xz; then wget_ok=1; break; fi; \
				echo '[virgl] mesa download failed (attempt '$$attempt'/5), retry in 15s'; sleep 15; \
			done; \
			[ "$$wget_ok" = "1" ] || { echo '[virgl] FATAL: mesa download failed'; exit 1; }; \
			rm -rf mesa-$(VIRGL_MESA_VERSION) && tar xf mesa-$(VIRGL_MESA_VERSION).tar.xz; \
			( cd mesa-$(VIRGL_MESA_VERSION) && patch -p1 < $(SOURCEDIR)/patches/mesa-215-osmesa-virgl.patch \
			  && touch src/gallium/targets/osmesa/.task215_patched ) || exit 1; \
		fi
	test -f $(SOURCEDIR)/depends/virgl/mesa-$(VIRGL_MESA_VERSION)/src/gallium/targets/osmesa/.task215_patched || { echo 'ERROR: mesa patch not applied'; exit 1; }
	rm -rf $(WORKINGDIR)/virgl-mesa
	cd $(SOURCEDIR)/depends/virgl/mesa-$(VIRGL_MESA_VERSION) && meson setup $(WORKINGDIR)/virgl-mesa \
		--cross-file $(WORKINGDIR)/virgl-cross.txt \
		-Dgallium-drivers=virgl,softpipe -Dvulkan-drivers=[] \
		-Dosmesa=true -Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled \
		-Dplatforms=[] -Dshared-glapi=disabled -Dvideo-codecs=[] \
		-Dbuild-tests=false -Dtools=[] || exit 1
	ninja -C $(WORKINGDIR)/virgl-mesa || exit 1
	test -f $(WORKINGDIR)/virgl-mesa/src/gallium/targets/osmesa/libOSMesa.8.dylib || { echo 'ERROR: libOSMesa.8.dylib (virgl guest) missing'; exit 1; }
	cp $(WORKINGDIR)/virgl-mesa/src/gallium/targets/osmesa/libOSMesa.8.dylib $(WORKINGDIR)/libOSMesaVirgl.dylib
	install_name_tool -id @rpath/libOSMesaVirgl.dylib $(WORKINGDIR)/libOSMesaVirgl.dylib || exit 1
	@echo '[Amethyst v$(VERSION)] [RENDERER-GAP] dep_virgl - end'
