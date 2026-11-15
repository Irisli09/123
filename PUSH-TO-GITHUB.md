# 用 GitHub Actions 编出 SimpleMtkWlan.kext（Windows 上全程鼠标操作，不需要 Mac）

本机没有 macOS 工具链，所以 kext 由 GitHub 的 macOS 15 机器编。你只需要把工程推上去，其余自动化。

工程目录：`C:\Users\ldz11\Downloads\SimpleMtkWlan-main`

---

## 第 1 步：建一个空仓库

1. 打开 <https://github.com/new>
2. **Repository name** 填 `SimpleMtkWlan`（随便叫什么都行）
3. 选 **Public**（公开仓库用 Actions 不消耗额度；这份源码本来就是 GPLv2 公开代码）
4. **不要**勾选 "Add a README file"、".gitignore"、"license"（仓库必须是空的）
5. 点 **Create repository**

---

## 第 2 步：把工程内容上传上去

刚建好的空仓库页面下方有一行 `…or upload an existing file`，点它。

1. 在资源管理器打开 `C:\Users\ldz11\Downloads\SimpleMtkWlan-main`
2. **Ctrl+A 全选里面的所有文件和文件夹**（6 个文件 + 6 个文件夹，其中含 `.github`）
3. 把它们拖进浏览器页面的虚线框，等文件列表出现
4. 页面底部 **Commit changes**

### ⚠️ 最容易错的一步

**要拖的是 `SimpleMtkWlan-main` 里面的内容，不是 `SimpleMtkWlan-main` 这个文件夹本身。**

拖错的表现：仓库里出现一个 `SimpleMtkWlan-main/` 目录，所有文件都在它下面。这样工作流在仓库根目录找不到 `build-kext.sh`，会直接失败。

如果已经拖错了：删掉那个目录重新按上面步骤拖，或者用 GitHub Desktop 修正。

### 如果 `.github` 文件夹没上传成功

网页拖拽偶尔会漏掉以点开头的目录，表现为：上传完仓库里**看不到 `.github`**，Actions 标签页里**没有任何工作流**。

补救（纯网页，30 秒）：

1. 仓库页 **Add file → Create new file**
2. 文件名输入 `.github/workflows/build-kext.yml`（输入 `/` 会自动创建目录）
3. 用记事本打开本机的 `.github\workflows\build-kext.yml`，全选复制，粘贴进去
4. **Commit changes**

---

## 第 3 步：等它自己编

上传完成会产生一次 push 到 `main`，工作流 `Build SimpleMtkWlan kext` **会自动开始**。

- 没有自动开始：进 **Actions** 标签 → 左侧 `Build SimpleMtkWlan kext` → 右侧 **Run workflow** → **Run workflow**
- 整个流程约 5–10 分钟（拉 MacKernelSDK + 编 54 个源文件）

---

## 第 4 步：下载产物

进入那次运行的页面，滚到最底部 **Artifacts**：

| 产物 | 内容 |
|---|---|
| `SimpleMtkWlan-kext-x86_64` | 解压后里面有 `SimpleMtkWlan.kext` **目录**（直接拷到 `EFI/OC/Kexts/` 的就是它）和 `SimpleMtkWlan-Release-x86_64.zip`（同样的东西打包 + sha256 校验文件） |
| `xcodebuild-log`（仅失败时出现） | 完整构建日志 |

拿到 `SimpleMtkWlan.kext` 后，注入方式见 [BUILD-macOS.md](BUILD-macOS.md) 第 5 节（拷到 `EFI/OC/Kexts/` + `config.plist` 的 `Kernel`→`Add` 加一条）。

---

## 第 5 步：如果构建失败了

Actions 运行页面里展开红色那一步，或下载 `xcodebuild-log`，把 `error:` 开头的行发我。常见情况：

- **`Kernel.framework/Headers not found`** → MacKernelSDK 没拉到，重跑一次
- **`xcodebuild: error: scheme not found`** → 文件层级错了，检查是不是拖成了 `SimpleMtkWlan-main/` 套一层
- **源码本身的编译错误** → 这是上游代码问题，得改代码。日志里 `error:` 行足够定位

想锁定 MacKernelSDK 版本排查：在 `.github/workflows/build-kext.yml` 的 `Build kext` 步骤 `env` 里取消注释 `MKS_REF`。
