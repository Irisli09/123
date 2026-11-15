#!/usr/bin/env bash
#
# build-kext.sh
# SimpleMtkWlan.kext 一键构建脚本（x86_64，面向 macOS 15 / Xcode 16）
#
# !!! 必须在 macOS 上运行 !!!
#     kext 是特殊 Mach-O，链接阶段依赖 Apple 的 ld64 -kext 模式与 macOS SDK 的
#     Kernel.framework 头文件，Windows / Linux 上的 clang、osxcross、ld.lld
#     都无法产出可被内核加载的 kext。
#
# 用法：
#   chmod +x build-kext.sh && ./build-kext.sh
#
# 可选环境变量：
#   CONFIG=Release|Debug       构建配置（默认 Release）
#   ADHOC_SIGN=1|0             是否 ad-hoc 签名（默认 1；OpenCore 注入时签名可省）
#   ARCH=x86_64                目标架构（工程只支持 x86_64，别改成 arm64）
#   DEPLOYMENT_TARGET=10.13    部署目标（Xcode 15/16 支持的最低值是 10.13）
#   MKS_REF=<commit>           锁定 MacKernelSDK 版本（默认拉 master；构建异常时用于回退）
#
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="SimpleMtkWlan.xcodeproj"
SCHEME="SimpleMtkWlan"
CONFIG="${CONFIG:-Release}"
ARCH="${ARCH:-x86_64}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-10.13}"
OUT="build/out"
KEXT="$OUT/SimpleMtkWlan.kext"

step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 环境
step "0/6  环境检查"
[ "$(uname -s)" = "Darwin" ] || die "必须在 macOS 上运行，当前系统是 $(uname -s)。kext 无法交叉编译。"
command -v xcodebuild >/dev/null 2>&1 || die "找不到 xcodebuild。请从 App Store 安装 Xcode，然后执行：
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

sw_vers
xcodebuild -version
SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"
echo "macOS SDK            : $SDK_VER"
echo "目标架构 / 部署目标  : $ARCH / $DEPLOYMENT_TARGET"

# --------------------------------------------------------- 1. MacKernelSDK
step "1/6  MacKernelSDK（Kernel.framework 头文件 + libkmod.a）"
MKS_URL="https://github.com/acidanthera/MacKernelSDK.git"
if [ ! -f MacKernelSDK/Library/x86_64/libkmod.a ] || [ ! -d MacKernelSDK/Headers ]; then
  rm -rf MacKernelSDK
  echo "    MacKernelSDK 缺失或不完整，正在拉取..."
  command -v git >/dev/null 2>&1 || die "需要 git 来拉取 MacKernelSDK"
  if [ -n "${MKS_REF:-}" ]; then
    # 锁到指定 commit：新版 MacKernelSDK 偶有破坏老工程的改动，出问题时可回退
    echo "    锁定版本: $MKS_REF"
    git init -q MacKernelSDK \
      && git -C MacKernelSDK remote add origin "$MKS_URL" \
      && git -C MacKernelSDK fetch -q --depth 1 origin "$MKS_REF" \
      && git -C MacKernelSDK checkout -q FETCH_HEAD \
      || die "拉取 MacKernelSDK@$MKS_REF 失败"
  else
    git clone --depth 1 -q "$MKS_URL" MacKernelSDK \
      || die "拉取失败（网络问题？）。可手动执行：
       git clone --depth 1 $MKS_URL MacKernelSDK"
  fi
fi
echo "    MacKernelSDK 就绪: $(git -C MacKernelSDK rev-parse --short HEAD 2>/dev/null || echo 'present')"

# ------------------------------------------------------------- 2. 编译
step "2/6  构建（$CONFIG / $ARCH / deployment $DEPLOYMENT_TARGET）"
rm -rf "$OUT" build/DerivedData
mkdir -p build "$OUT"

if ! xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      -derivedDataPath build/DerivedData \
      -arch "$ARCH" \
      ARCHS="$ARCH" \
      ONLY_ACTIVE_ARCH=NO \
      MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
      CONFIGURATION_BUILD_DIR="$PWD/$OUT" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      build 2>&1 | tee build/xcodebuild.log; then
  echo
  grep -nE '(^|: )(error:|fatal error:)' build/xcodebuild.log | head -40 || true
  die "构建失败。完整日志: build/xcodebuild.log"
fi

# ------------------------------------------------------------- 3. 校验
step "3/6  产物校验"
[ -d "$KEXT" ] || die "未生成 $KEXT（详见 build/xcodebuild.log）"

PLIST="$KEXT/Contents/Info.plist"
EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
BIN="$KEXT/Contents/MacOS/$EXEC"
[ -f "$BIN" ] || die "kext 内缺少可执行文件: $BIN"

ARCHES="$(lipo -archs "$BIN")"
echo "    二进制架构        : $ARCHES"
echo "    CFBundleIdentifier: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
echo "    CFBundleVersion   : $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "    IOPCIPrimaryMatch : $(/usr/libexec/PlistBuddy -c 'Print :IOKitPersonalities:SimpleMtkWlan:IOPCIPrimaryMatch' "$PLIST")"
case " $ARCHES " in
  *" $ARCH "*) : ;;
  *) die "架构不符：期望 $ARCH，实际 $ARCHES" ;;
esac

# --------------------------------------------------- 4. 依赖/加载性静态检查
step "4/6  内核符号与依赖静态检查（不加载）"
if command -v kextutil >/dev/null 2>&1; then
  kextutil -n "$KEXT" 2>&1 | sed 's/^/    /' || \
    echo "    （kextutil 报了告警/错误；OpenCore 注入场景下签名与 KC 相关告警可忽略，
      但 'unresolved symbol' 必须解决）"
else
  echo "    跳过：找不到 kextutil"
fi
if command -v otool >/dev/null 2>&1; then
  echo "    链接的 kext 符号源:"
  otool -L "$BIN" 2>/dev/null | sed -n '2,20p' | sed 's/^/      /' || true
fi

# ------------------------------------------------------------- 5. 签名
step "5/6  签名与权限"
if [ "${ADHOC_SIGN:-1}" = "1" ]; then
  codesign --force --sign - --timestamp=none "$KEXT"
  codesign -dvv "$KEXT" 2>&1 | sed 's/^/    /' || true
else
  echo "    ADHOC_SIGN=0，跳过签名"
fi
chmod -R 755 "$KEXT"

# ------------------------------------------------------------- 6. 打包
step "6/6  打包"
ZIP="$OUT/SimpleMtkWlan-$CONFIG-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$KEXT" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

printf '\n构建完成\n'
printf '  KEXT : %s\n' "$PWD/$KEXT"
printf '  ZIP  : %s\n' "$PWD/$ZIP"
printf '  LOG  : %s\n' "$PWD/build/xcodebuild.log"
printf '\n注入 OpenCore：把 SimpleMtkWlan.kext 拷到 EFI/OC/Kexts/，见 BUILD-macOS.md 第 5 节\n'
