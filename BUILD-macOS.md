# SimpleMtkWlan 构建说明（目标：macOS 15 / 联发科 MT7921·MT7922）

## 1. 先说结论：Windows 上产不出 `.kext`

这不是配置问题，是工具链的硬边界。本次已在这台 Windows 上实测确认：

```
xcodebuild → 不存在      clang → 不存在      *.sdk → 不存在
```

| 依赖 | 为什么必须 | Windows / Linux 能否替代 |
|---|---|---|
| `ld64 -kext`（Apple 链接器） | kext 是 `MH_KEXT_BUNDLE` 类型的特殊 Mach-O，需要内核扩展专用链接模式 | 不能。GNU ld、LLD、osxcross 都不实现该模式 |
| macOS SDK 的 `Kernel.framework` 头文件 | `kern_return_t`、`IOPCIDevice`、`OSObject` 等 KPI 定义 | 不能 |
| `MacKernelSDK`（acidanthera） | 工程固定引用 `MacKernelSDK/Headers` 与 `MacKernelSDK/Library/x86_64/libkmod.a` | 需要联网拉取 |
| `codesign` / `lipo` / `ditto` | 签名、架构校验、打包 | 不能 |

所以：**要么在 macOS 上编，要么让 GitHub 的 macOS 机器替你编。** 本文两条路线都给全了。

## 2. 本次对工程做的改动（相对你下载的原始 zip）

| 文件 | 改动 | 原因 |
|---|---|---|
| `SimpleMtkWlan.xcodeproj/project.pbxproj` | `HEADER_SEARCH_PATHS` / `KERNEL_EXTENSION_HEADER_SEARCH_PATHS` 从作者机器绝对路径 `/Users/laobamac/Desktop/MacKernelSDK/Headers` 改为 `$(PROJECT_DIR)/MacKernelSDK/Headers` | 原值是**目标级覆盖**，会顶掉工程级的正确路径，换机器必然报头文件找不到 |
| 同上（4 处） | `MACOSX_DEPLOYMENT_TARGET` 10.9 / 10.12 → **10.13** | Xcode 15/16 支持的最低部署目标是 10.13，10.9 会在新版工具链上报不支持的部署目标 |
| `build-kext.sh` | 重写：环境自检 → 拉 MacKernelSDK → 编译 → 架构/Info.plist 校验 → `kextutil` 静态检查 → 签名 → 打包 | 一条命令跑完全流程，失败时直接指出日志位置和第一条 error |
| `.github/workflows/build-kext.yml` | runner 从 `macos-13` 改为 `macos-15` | `macos-13` 已被 GitHub 于 2025-12-04 完全下线，原写法现在会直接调度失败 |
| `PUSH-TO-GITHUB.md` | 新增：Windows 上纯鼠标上传 + 触发云端构建的逐步说明 | — |
| `BUILD-macOS.md` | 本文件 | — |

原工程备份：`SimpleMtkWlan.xcodeproj/project.pbxproj.bak-orig`（想还原直接覆盖回去）。

工程目标参数（构建产物由它们决定）：

- `ARCHS = x86_64` —— **只有 Intel 架构**。Apple Silicon 原生 macOS 不允许加载第三方 kext，这个 kext 只能在 Intel Mac / 黑苹果上用
- `MACOSX_DEPLOYMENT_TARGET = 10.13`，`SDKROOT = macosx`（编于 macOS 15 SDK，可在 macOS 15 上加载）
- `PRODUCT_BUNDLE_IDENTIFIER = com.laobamac.SimpleMtkWlan`，`MODULE_VERSION = 1.0.0`
- 默认不签名（`CODE_SIGN_IDENTITY = ""`），OpenCore 注入场景正合适
- 匹配设备：`0x796114c3`(MT7921) / `0x060814c3`(MT7921K/RZ608) / `0x792214c3`(MT7922)

## 3. 路线 A：有 Mac 时一条命令搞定

适用：真 Mac（Intel）、黑苹果、VMware/Parallels 里的 macOS 虚拟机。**需要完整 Xcode**（只有 Command Line Tools 不够，缺 kext 链接器和 SDK 头文件）。

```bash
cd SimpleMtkWlan-main          # 整个目录拷到 macOS 上
chmod +x build-kext.sh
./build-kext.sh                # 默认 Release + x86_64 + ad-hoc 签名
```

产物：

```
build/out/SimpleMtkWlan.kext
build/out/SimpleMtkWlan-Release-x86_64.zip
build/xcodebuild.log
```

想复现脚本内部动作，等价命令是：

```bash
git clone --depth 1 https://github.com/acidanthera/MacKernelSDK.git MacKernelSDK

xcodebuild -project SimpleMtkWlan.xcodeproj -scheme SimpleMtkWlan \
  -configuration Release -arch x86_64 ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=10.13 \
  CONFIGURATION_BUILD_DIR="$PWD/build/out" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
```

可选参数：`CONFIG=Debug ./build-kext.sh`（调试版）、`ADHOC_SIGN=0 ./build-kext.sh`（不签名）。

## 4. 路线 B：没有 Mac，用 GitHub Actions 云编译

完整点击步骤见 **[PUSH-TO-GITHUB.md](PUSH-TO-GITHUB.md)**（Windows 上纯鼠标操作）。要点：

1. GitHub 新建**空**仓库（Public，别勾 README），把 `SimpleMtkWlan-main` **里面的内容**（不是这个文件夹本身）拖进上传页面。
   注意 `.github` 目录必须一起上传，否则不会有工作流。
2. 上传提交后 push 到 `main` 会自动触发 `Build SimpleMtkWlan kext`；没触发就进 Actions 手动 Run workflow。
3. 约 5–10 分钟后，在该次运行页面底部 **Artifacts** 下载 `SimpleMtkWlan-kext-x86_64`，
   解压后里面直接就是 `SimpleMtkWlan.kext` 目录。

关于 runner 选择的几个坑（2026 年现状）：

- `macos-13` 已下线，**不要再写**。
- `macos-15` 是 arm64 机器，但我们的目标只是 `ARCHS=x86_64`，**交叉编译出来的 kext 本身没问题**——编译目标架构和宿主机架构无关。
- `macos-15-intel` 才是 x86_64 的 macOS 15 镜像，但它属于需要付费额度的 larger runner，免费/私有仓库下可能调度不上，所以工作流默认用 `macos-15`。
- 公开仓库免费额度充足；私有仓库按分钟计费。

## 5. 在 macOS 15（Sequoia）上加载

macOS 11 起，第三方 kext **无法**再通过 `kmutil load` 加载进系统（除非 Developer ID 签名 + 用户授权 + 关 SIP）。所以实际可行的只有 OpenCore 注入。

### 方式一：OpenCore 注入（推荐，正常系统 / Recovery / 安装器都生效）

1. `SimpleMtkWlan.kext` 整个目录拷到 `EFI/OC/Kexts/SimpleMtkWlan.kext`。
2. 编辑 `config.plist`，`Kernel` → `Add` 新增：

```xml
<dict>
    <key>Arch</key>          <string>x86_64</string>
    <key>BundlePath</key>    <string>SimpleMtkWlan.kext</string>
    <key>Comment</key>       <string>MT792x Wi-Fi (experimental)</string>
    <key>Enabled</key>       <true/>
    <key>ExecutablePath</key><string>Contents/MacOS/SimpleMtkWlan</string>
    <key>MaxKernel</key>     <string></string>
    <key>MinKernel</key>     <string></string>
    <key>PlistPath</key>     <string>Contents/Info.plist</string>
</dict>
```

想只在 Sequoia 及以上生效，`MinKernel` 填 `24.0.0`（macOS 15 = Darwin 24）。

3. 重启。OpenCore 在引导阶段注入，不校验签名，未签名/自签都能加载。

### 方式二：Recovery 里临时加载（仅调试用）

```bash
csrutil disable            # 先关 SIP（Recovery 终端里执行），然后重启
# 再进 Recovery：
kmutil load -p /Volumes/<卷名>/SimpleMtkWlan.kext -v 5
```

重启即失效，不进正常系统内核缓存。日常使用请回到方式一。

## 6. 加载后怎么验证（macOS 15 命令）

```bash
kmutil showloaded | grep -i mtkwlan        # 已加载列表（kextstat 在新系统上已淡出）
ioreg -l -w0 -p IOService | grep -i -A6 SimpleMtkWlan   # 看是否 attach 到 IOPCIDevice
log show --last 5m --predicate 'process == "kernel" AND (eventMessage CONTAINS[c] "mtk" OR eventMessage CONTAINS[c] "mwx")'
system_profiler SPAirPortDataType
```

驱动把 probe / 固件加载 / 队列初始化都打了日志，排错优先看 `SimpleMtkWlan` 和 `MtkMwx` 前缀。

## 7. 必须知道的限制

- **实验性**：README 明确写 "under active hardware bring-up"、"not release-stable yet"，当前还在调 association/authentication 的发送路径。**编译成功 ≠ 能上网**，更可能是「kext 能加载、网卡能 probe，但握手失败」。
- **仅 x86_64**：Apple Silicon 原生系统加载不了；Rosetta 也不涉及内核态。
- **仅 MT7921 / MT7921K(RZ608) / MT7922**：换卡要改 `SimpleMtkWlan/Info.plist` 的 `IOPCIPrimaryMatch`。
- **别和其他 MT792x 驱动共存**：同 PCI ID 会 probe 冲突，只留一个。
- **kext 崩溃 = 内核 panic**：先在有回滚能力的机器/Recovery 上验证，并记住退路是把 `Kernel` → `Add` 里那一项的 `Enabled` 改回 `false`。

## 8. 报错对照

| 报错 | 原因 / 处理 |
|---|---|
| `xcodebuild: command not found` / `xcrun: error: unable to find utility "clang"` | 没装完整 Xcode，或 `xcode-select` 指向 CLT：`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| `'Kernel.framework/Headers' file not found`、`libkmod.a not found` | MacKernelSDK 没拉全，删掉目录重跑（脚本第 1 步会自动重拉） |
| `The macOS deployment target ... is set to 10.9` | 已改成 10.13；若你手动还原了 pbxproj，加 `MACOSX_DEPLOYMENT_TARGET=10.13` |
| `ld: building for kexts requires ...` | 不是 Apple 链接器 / 不在 macOS 上构建 |
| `code signature invalid`、`kext rejected` | 用 `kmutil load` 加载未签名 kext：改走 OpenCore 注入 |
| `... is not compatible with ... arch` | 架构不符：产物必须是 x86_64，且机器是 Intel |
| `xcodebuild: error: scheme not found` | 不在工程根目录，或 scheme 名写错（应为 `SimpleMtkWlan`） |
| 加载后立即 panic | 驱动与硬件/系统版本不匹配，禁用 `Kernel`→`Add` 项回滚 |
