# COMPETITOR-GAP: “渲染器之外”差集同步 —— 来源与许可

本文件记录本轮（渲染器之外）从竞争对手仓库抄入 `tree510` 的每一项及其来源、许可、回退方式。
★ 本轮**未 push / 未合并 / 未开 issue / 未提 PR**，全部为本地 commit。

## 对比基线与方法

- 我们的树：`D:\CTF\_510src\tree510`（HEAD `899e51ec9`，remote `upstream` 派生）。
- 对手参照：`D:\CTF\_uibuild\repo` = **`Gsjsjzhznsz/Air-Minecraft-iOS-Launcher`**，分支 `ui/e-design-1`，commit
  `50c59ee6bfc8e14bcbf3de3abee7a2f824209ba5`（在 tree510 内亦可经 `remotes/fork/ui/e-design-1` 访问）。
- 两树 **无共同祖先**（unrelated histories）；对手仓库文件为 **CRLF**，故所有“内容不同”判定在
  **LF 归一化 + md5** 后计算（否则会误报 342 处，实测真差异仅 82 处）。
- 已按用户指示**排除 NG-GL4ES（ZalithLauncher2）**，本轮不再引入。

> **[fix16] 注意**：这里的"排除"仅指本轮 `tree510` 的差集同步，不代表当前
> `main` 中没有 NG-GL4ES。当前 main 仍保留完整 NG-GL4ES 接线且默认构建，
> 详见 `RENDERER_GAP_PROVENANCE.md` 的 "[fix16] 当前 main 状态"段。

## 许可证

对手仓库与我们同为 **GNU GPL-3.0**（`LICENSE` 逐字同源，均为 Amethyst-iOS-MyRemastered 的 fork）。
故按其许可导入同源项目的文件是合规的；本文件即 attribution 记录。

## 已抄入（本 commit）

| 路径 | 来源 | 许可 | 原始 md5（导入前） | 说明 |
|---|---|---|---|---|
| `intentprobe/project.yml` | 对手仓库 `ui/e-design-1` @ `50c59ee6b` | GPL-3.0 | `3ef81565f3f4ba253710803eb97a971d` | XcodeGen 工程描述（独立 probe App，bundleIdPrefix `com.probe`） |
| `intentprobe/Sources/App.swift` | 同上 | GPL-3.0 | `230a33897b60eca9c4ed0e18217ed10d` | probe App 入口（SwiftUI） |
| `intentprobe/Sources/AmethystIntents.swift` | 同上 | GPL-3.0 | `75bd1b04b96465de3fe272d4eac0ab00` | App Intents / Siri 快捷指令参考（`LaunchVersionIntent` / `SetRendererIntent` / `AmethystShortcuts`） |
| `METAL_TUTORIAL.txt` | 同上 | GPL-3.0 | `1a6f73c84bca4e239bf231624b121cbd` | Metal(metallum) 集成用户文档 |

### 为什么抄 intentprobe（关键理由 —— 不是“为抄而抄”）

本树**已有** `.github/workflows/intentprobe.yml`（与对手逐字相同，见 commit `d7619d684` “补齐换底时漏掉的
fork 独有文件”），该 workflow 的 `working-directory: intentprobe` + `xcodegen generate` **指向一个本树不存在的
目录** —— 即本树的 CI 里挂着一个“引用了空目录”的 workflow。补齐 `intentprobe/` 只做两件事：

1. 让这个既有 workflow 不再引用不存在的路径（消除悬空引用，不新增任何自动化）；
2. 把对手用于“验证 App Intents 元数据能否在无签名构建下生成”的 probe 源码留在树内，作为
   **将来若要做 Siri 快捷指令功能**的可复用证据/参考。

它**完全不参与 App 打包**：`intentprobe/` 是独立的 XcodeGen 工程（`xcodegen generate` 另行生成
`.xcodeproj`），不在 `Natives/CMakeLists.txt`、不在 `Makefile`、不在任何 payload/打包清单中。
故 **无需改 CMakeLists、无需进打包清单** —— 这也是它“低风险”的根本原因。

### 回退

```bash
rm -rf tree510/intentprobe tree510/METAL_TUTORIAL.txt
git -C tree510 revert <this-commit>     # 或 git checkout <prev> -- intentprobe METAL_TUTORIAL.txt
```

## 已记录、**故意不抄/不换**（同名不同版 · 沿用上一轮既定策略）

以下为“同名不同构建”的二进制，双方从各自源码线构建，md5 不同但**不是能力缺口**；
按既定策略**只记录不强行替换**（强换会破坏本树已收敛的构建线与真机验证）。

| 文件 | 我们 | 对手 | 结论 |
|---|---|---|---|
| `Natives/resources/Frameworks/libmetallum.dylib` | 221856 B | 231576 B | 各自构建（对手含其 agent/natives 线）——不换 |
| `Natives/resources/Frameworks/libshaderc.dylib` | 9384224 B | 8522336 B | 各自构建——不换 |
| `Natives/resources/Frameworks/libspirv-cross-c-shared.0.dylib` | 2679856 B | 3475240 B | 各自构建——不换 |
| `Natives/resources/Frameworks/liblwjgl.dylib` | 305216 B | 302104 B | 各自构建——不换 |
| `Natives/resources/Frameworks/liblwjgl_stb.dylib` | 464472 B | 406224 B | 各自构建——不换 |
| `JavaApp/libs/others/metallum_agent.jar` | 6852035 B | 539580 B（另有根目录 4106015 B 冗余副本） | 本树 agent 更大更新（多版本分支），不换 |
| 根目录 `metallum_agent.jar` | 无 | 4106015 B | 对手的**陈旧冗余副本**；本树经 `JavaApp/libs/others/` 生效（JavaLauncher.m:1921），不抄 |
| `Natives/resources/Frameworks/libopenal.dylib` | 无（**构建期生成**） | 4112728 B（= `libopenal_impl.dylib` 的字节副本） | 本树 Makefile 由 `libopenal_impl.dylib` 用 `-reexport_library` 生成同名垫片 ⇒ **非缺口**，不抄 |
