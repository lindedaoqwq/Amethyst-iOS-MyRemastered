# 26.4 SPIR-V use-after-free —— 真修(class-set 源侧)+ 交付

> 对象:iPhone 17 Pro / iOS 27.2 / 实例 26.4-snapshot-2 / Metal 后端。
> 症状:首次 UI 管线 `minecraft:pipeline/gui` 编译时
> `com.mojang.renderpearl.util.ShaderCompileException: SPIRV-Cross error at spvc_context_parse_spirv: -1`。
> 上一轮(tree510@7a6b5129b `★ [SPVC-PATH]`)只在 native 侧做了「快照环 + 就地恢复」兜底;**本轮在 Java/类集源侧做真修**。
> 交付:`tree510` 的 `JavaApp/libs/others/metallum_agent.jar`(只换 `classes264/**` 里 9 个条目,其余逐字节不变)。

## 1. 根因(生命周期时间线,含坐标)

调用链(26.4 renderpearl 前端 → Metal 后端):

```
PipelineBuilder.compilePipeline(RenderPipeline, ShaderSource)            (com.mojang.blaze3d.pipeline)
  1) generateBackendCreateInfo(...)
       · compiler.compileToSpv(...)              → memAlloc'd ByteBuffer (GLSL→SPIR-V, glslang)
       · device.createSpvModule(name, spv, type, "main")  → new SPIRVModule(name, spv, ...)
         （MetalDevice.createSpvModule 直接委托给 SPIRVModule）
       · module.reflect()  ← 第 1、2 次 spvc_context_parse_spirv(反射解析,缓冲【仍存活】)
       · 装进 CreateInfo(List<SpvModule>)
  2) device.compilePipeline(createInfo)          → FrontendGpuDevice → MetalDevice.compilePipeline
       · MetalDevice 返回一个【延迟】的 Pending(真正的解析在 finishCompile() 里)
  3) createInfo.shaders().forEach(SpvModule::close)   ← ★★ Free 点
       · SPIRVModule.close() = { MemoryUtil.memFree(this.spv); spvc_context_destroy(...); }
  ...
  4) 稍后 frontend 调 Pending.finishCompile()
       · MetalDevice$2.finishCompile → MetalCrossShaderCompiler.compile(device, info)
       · spirvToMsl(vertexSpirv.spv(), …)  ← 第 3 次 spvc_context_parse_spirv
         ⇒ 读【第 3 步已 free】的堆内存 = use-after-free
```

真机证据:`parse#3` 与 `parse#1` 同长(503 words)、自第 6 字起逐字相同,仅**前 16 字节**变
(`66297a96 e3a84b13 00000180 …`) = **libmalloc 空闲块链表头** ⇒ 缓冲已被 free、尚未被复用。
(上一轮的 `_SPVC_PATH_FIX.md` 把释放点归到 `IntermediaryShaderModule`/`MetalDevice.shaderCache` —— 那是
**26.2/26.3 的代码路径**,26.4 已换成 `CreateInfo`/`SpvModule`,该归因不适用;见 §5。)

关键坐标:
- Free 点:`com/mojang/blaze3d/pipeline/PipelineBuilder.compilePipeline` 第 3 步(在 `device.compilePipeline` 返回后)。
- 读已释放点:`MetalCrossShaderCompiler.spirvToMsl(vertexSpirv.spv(), …)`(`_mc264src` 第 83/99 行)。
- 责任边界:**后端只能在 `compilePipeline(info)` 调用期间使用 `CreateInfo.shaders()`**。

## 2. 修法(选 (c):拷贝 + 生命周期契约)

改动落在 **26.4 类集源 `D:\CTF\_mc264src\java`**(= `metaluni/mu263` 的副本 + `// ★ [MC264]` 8 处端口补丁;
`classes264` 就是由它编出),`// ★ [SPVC-UAF-FIX]` 标记:

1. `MetalDevice.compilePipeline(CreateInfo)`(在 module **仍存活**时):
   - `SpvSnapshot.take(info)` —— 对每个 `SpvModule` 做 `spv()` 的**逐字拷贝**
     (`MemoryUtil.memAlloc(n)` + `dup.order()` + `put` + `flip`,保留 `[position,limit)` 与字节序);
   - 拷贝所有权归 `MetalDevice`,在 `finishCompile()` 结束时**释放一次**(幂等);
   - `close()` 里 `releaseAllSpvSnapshots()` 兜底排空「Pending 从未 finishCompile」的残留;集合天然有界。
2. `MetalCrossShaderCompiler.compile(MetalDevice, CreateInfo, Map<ShaderType,ByteBuffer> ownedSpirv)`:
   - `ownedSpirv != null` 时**绝不**再读 `SpvModule.spv()`(契约写进签名 + 注释);
   - 缺 entry 视为「该 stage 真的没有」→ 返回 null(=旧行为),不回落读已释放的 module。
3. 逐字拷贝,内容不变;生命周期只变长(到 finishCompile 结束),不引入泄漏。

为什么不选纯 (a)/(b):
- 纯 (a)「在 `MetalCrossShaderCompiler.compile` 里拷贝」**太晚** —— 那时 `finishCompile` 已经读了释放后的内存,
  拷到的也是坏字节(前 16B 已是 free-list 元数据)。拷贝必须发生在 `compilePipeline`(module 存活期)。
- 纯 (b)「把生命周期变长」= 后端长期持有/读前端缓冲,等于假设前端不 close —— 前端**必然** close
  (它把 `SpvModule` 当方法级资源),契约无法在不改前端的前提下成立。
- (c) 两者都做:拷贝(真实修复)+ 签名/契约(防止回归)。

## 3. 重编 + 解包复核(本机真跑)

源:`D:\CTF\_mc264src\java`(156 源)→ JDK25 `javac`(`client-26.4.jar` + `_b261_stub` + `_mc211/libs`)
→ `classes264` = 185 自有 + 55 slf4j = **240** 类(原 239;新增 `MetalDevice$SpvSnapshot`)。
拼装脚本 `D:\CTF\_uafwork\{build_classes264.py,assemble264fix.py}`;合并脚本 `merge_spvcuaf.py`。

| 检查 | 结果 |
|---|---|
| 基线复现(改前源 → 184 类) | 与 `_mc264out/build` **184/184 逐字节相同**(证明构建可复现) |
| 改后编译 | 185 类,0 error |
| 相对旧 `classes264` 的差异 | **8 changed + 1 added**,其余 231 条逐字节不变 |
| 常量池残留(7 个 26.4 已删/迁包类型) | **0** |
| `Harness264`(真 26.4 client 父加载器 load+link) | **89/89 LOADED_OK,FAILED=0** |
| agent jar 合并 | `entries 1541 → 1542`;**除 `classes264/**` 外 0 条目变动**;`testzip() OK` |
| 根 `com/mojang/blaze3d/` = 0 / `classes264/com/mojang/` = 0 | 保持 |
| `MetallumAgent.class` 路由标记(`classes264`/`is264`/`classSetPresent`/`FIX263-ROUTE`)与 `TapUniversal` | 保持不变(agent 类未重编) |
| `Natives/check_spvc_provenance.py` | **EXIT=0** |
| 新 jar | md5 `215a521c34552dd987f51ebbf0152604` / 5,661,113 B(**原** `bd6f7a647cf12654c188077d4ac7ac2d` / 5,659,509 B) |

解包复核(从**装好后的** jar 重新解出):`classes264` = 240;`javap` 确认
`MetalDevice.compilePipeline(CreateInfo)` 里 `SpvSnapshot.take` → `new MetalDevice$2(device,snapshot,info)`,
`copySpv` 走 `memAlloc/order/put/flip`,`MetalDevice$2.finishCompile` 调
`MetalCrossShaderCompiler.compile(MetalDevice,CreateInfo,Map)` 并在 finally 调 `releaseSpvSnapshot`。

**其它类集不受影响**:`classes263`/`classes262` 的 `MetalDevice` 走 `ShaderSource` + 自己的 `shaderCache`
(常量池无 `CreateInfo`/`SpvModule`),缓冲所有权在后端自身 ⇒ 无此 UAF,无需重编。

## 4. 真机判据(下一次 26.4 启动)

1. **不再出现** `★ [SPVC-PATH] … FREED/CLOBBERED in place … RESTORED from snapshot`
   (若还出现 = 兜底仍在救,说明 native 加载的不是新 jar)。
2. 三次 `[spvc][26.4-SPVC] parse_spirv input: … head8=[…]` 的 `head8` **全部**以 `07230203` 开头,
   且 `rc=0`。
3. 26.4 能过 `preloadUiShader` / `loadCriticalShaders`,不再抛 `ShaderCompileException`
   (或至少不再有 `spvc_context_parse_spirv: -1`)。
4. 回归:26.2/26.3 实例仍打印各自的 `prefix='classes262/'`/`'classes263/'`,画面与改前一致。

## 5. 未做 / 存疑

- **未在真机验证**(随包 `libspvc.dylib` 是 iOS Mach-O,macOS/Windows 不能 dlopen;本机无 host 端 spvc)。
  本条只能由下一次 26.4 真机日志定案。
- 只有 `classes264` 重编并替换进 jar;**未碰** 26.2/26.3 类集、路由逻辑、native、launcher、玻璃相关文件。
- 备份:`D:\CTF\_510src\_bak_\spvcuaf_<ts>\metallum_agent.jar.orig`、`classes264.orig`;
  源备份 `_mc264src\...\MetalDevice.java._bak_spvcuaf`、`MetalCrossShaderCompiler.java._bak_spvcuaf`
  (与改后源一起编译可**逐字节**复原改前类集,已证)。
- `_mc264out\classes264` 已同步为改后版本(离线产物与 jar 一致);**注意**:`tree264` 参考 jar 仍是改前版,
  `_mc264merge_scripts\build_mc264_tree510.sh` 里「classes264 vs tree264 ref mismatch=0」的断言对这 9 个类会报不一致 ——
  该断言需按改后基线更新(本轮未动那个脚本)。
- 未 push / 未合并 / 未开 issue。

---

## 附:复现命令

```bash
python D:/CTF/_uafwork/build_classes264.py D:/CTF/_mc264src/java D:/CTF/_mc264out/files264.txt D:/CTF/_uafwork/out_fix
python D:/CTF/_uafwork/assemble264fix.py    D:/CTF/_uafwork/out_fix D:/CTF/_uafwork/classes264_fix
python D:/CTF/_uafwork/merge_spvcuaf.py \
  D:/CTF/_510src/tree510/JavaApp/libs/others/metallum_agent.jar \
  D:/CTF/_uafwork/classes264_fix D:/CTF/_uafwork/metallum_agent.jar.new
# 回退
cp D:/CTF/_510src/_bak_/spvcuaf_<ts>/metallum_agent.jar.orig \
   D:/CTF/_510src/tree510/JavaApp/libs/others/metallum_agent.jar
# 源补丁(CRLF 源;用 --binary 或 git apply)
patch -p0 --binary < D:/CTF/_510src/tree510/patches/26.4-spvc-uaf-fix.diff
```

> 校验:`python D:/CTF/_uafwork/build_classes264.py` 对**改前源**(= `*.java._bak_spvcuaf`)
> 编出的 184 个 class 与 `_mc264out/build` 逐字节相同 ⇒ 构建可复现、源备份即改前源。
