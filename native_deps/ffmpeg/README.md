# FFmpeg LGPL Universal Binary Builder

为 XFileSuite 构建 LGPL 合规的 FFmpeg。macOS shared media runtime 会以
`FFMPEG_LINKAGE=shared` 调用本脚本；默认静态模式仅用于独立构建和 Windows
工作流，不再作为 macOS App 的第二份 FFmpeg 产物发布。

## 许可证

此脚本构建的 FFmpeg 严格遵循 **LGPL 2.1** 许可证，适用于闭源商业应用：

- `--disable-gpl` — 禁用所有 GPL 组件
- `--disable-nonfree` — 禁用所有非自由组件
- `--disable-version3` — 禁用 GPLv3/LGPLv3 组件

所有附加库均为 LGPL 或 BSD 许可，可安全用于商业闭源软件。

## 包含的组件

| 库 | 许可证 | 功能 | 版本 |
|---|---|---|---|
| **FFmpeg** | LGPL 2.1 | 多媒体核心 | 8.1.2 |
| **libmp3lame** | LGPL 2.1 | MP3 编码 | 3.100 |
| **libogg** | BSD | OGG 容器格式 | 1.3.5 |
| **libvorbis** | BSD | Vorbis 音频编码 | 1.3.7 |
| **libvpx** | BSD | VP8/VP9 视频编码 (WebM) | 1.15.2 |
| **libwebp** | BSD-3-Clause | WebP / 动画 WebP 编码 | 1.6.0 |
| **libopus** | BSD-3-Clause | Opus 音频编码 | 1.5.2 |
| **VideoToolbox** | Apple | H.264/H.265/ProRes 硬件编解码 | 系统内置 |
| **AudioToolbox** | Apple | AAC/ALAC 等音频编解码 | 系统内置 |
| **SecureTransport** | Apple | HTTPS/TLS 支持 | 系统内置 |
| **zlib** | zlib | 压缩支持 | 系统内置 |

## 构建产物

- **架构**: Universal Binary (arm64 + x86_64)
- **最低系统**: macOS 11.0 (Big Sur)
- **依赖**: 仅系统框架，无第三方动态库
- **输出**:
  - `dist/ffmpeg-<version>-<stamp>-macos-universal/bin/ffmpeg`
  - `dist/ffmpeg-<version>-<stamp>-macos-universal/bin/ffprobe`
  - `dist/ffmpeg-<version>-<stamp>-macos-universal.tar.gz` (打包)

## 使用方法

### 前置要求

- macOS with Xcode (含 Command Line Tools)
- `nasm` (推荐，用于 x86_64 汇编优化): `brew install nasm`
- `pkg-config`: `brew install pkg-config`

### 快速开始

```bash
cd native_deps/ffmpeg
./build.sh
```

构建完成后，二进制文件会自动复制到 `macos/Runner/Resources/` 目录。

### 常用选项

```bash
# 仅构建，不打包，不安装到项目
./build.sh --no-package --no-install

# 构建并打包，但不自动安装
./build.sh --no-install

# 自定义参数
MIN_MACOS=12.0 FFMPEG_VERSION=7.0 ./build.sh
```

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `MIN_MACOS` | `11.0` | 最低支持的 macOS 版本 |
| `FFMPEG_VERSION` | `8.1.2` | FFmpeg 版本 |
| `LAME_VERSION` | `3.100` | LAME 版本 |
| `OGG_VERSION` | `1.3.5` | libogg 版本 |
| `VORBIS_VERSION` | `1.3.7` | libvorbis 版本 |
| `VPX_VERSION` | `1.15.2` | libvpx 版本 |
| `WEBP_VERSION` | `1.6.0` | libwebp 版本 |
| `JOBS` | CPU 核心数 | 并行编译任务数 |
| `BUILD_ID` | (空) | 可选的构建 ID |

### 缓存

源码和中间产物缓存在 `work/` 目录下。重复构建时已下载的源码不会重新下载。
如需完全重新构建，删除 `work/` 目录：

```bash
rm -rf work/
```

## 如何添加新的 LGPL 库

以添加 `libopus` 为例：

1. 在脚本顶部添加版本变量和 URL：
```bash
OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
OPUS_TARBALL_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
OPUS_TARBALL_PATH="$WORK_DIR/opus-${OPUS_VERSION}.tar.gz"
OPUS_SRC_DIR="$WORK_DIR/opus-${OPUS_VERSION}"
```

2. 添加 `fetch_opus()` 函数（参考 `fetch_ogg()`）

3. 添加 `build_opus_arch()` 函数（参考 `build_ogg_arch()`）

4. 在 `build_one_arch()` 中调用：
```bash
build_opus_arch "$ARCH"
```

5. 在 FFmpeg configure 中添加：
```bash
--enable-libopus \
```

6. 在 `LIB_LDFLAGS` 中添加 `-lopus`

7. 在 `main()` 中调用 `fetch_opus`

## 目录结构

```
native_deps/ffmpeg/
├── build.sh          # 构建脚本
├── README.md         # 本文档
├── work/             # 构建中间产物 (gitignored)
│   ├── ffmpeg-8.1.2/     # FFmpeg 源码
│   ├── lame-3.100/       # LAME 源码
│   ├── libogg-1.3.5/     # libogg 源码
│   ├── libvorbis-1.3.7/  # libvorbis 源码
│   ├── libvpx-1.15.2/    # libvpx 源码
│   ├── libwebp-1.6.0/    # libwebp 源码
│   ├── prefix-arm64/     # arm64 安装前缀
│   ├── prefix-x86_64/    # x86_64 安装前缀
│   └── build-*/          # 各架构构建目录
└── dist/             # 最终产物 (gitignored)
    └── ffmpeg-8.1.2-<stamp>-macos-universal/
        ├── bin/ffmpeg
        ├── bin/ffprobe
        └── BUILDINFO.txt
```

## LGPL 合规说明

在闭源商业应用中使用此 LGPL 构建时：

1. **动态链接**: FFmpeg 作为独立可执行文件通过 `Process.run()` 调用，不构成静态链接
2. **可替换性**: 用户可以替换 `ffmpeg` 二进制文件
3. **许可证声明**: 需在应用中包含 FFmpeg 的 LGPL 许可证文本和版权声明
4. **源码提供**: 必须提供与实际分发二进制精确对应的 FFmpeg 及其静态链接 LGPL 库源码、补丁、构建脚本和构建信息；不能只提供上游通用链接。

## 对外源码包

运行以下命令生成应上传至公开 GitHub Release 的固定源码包：

```bash
./package-source.sh
```

默认生成 `dist/xfilesuite-ffmpeg-macos-8.1.2-xfilesuite.2-source.tar.gz` 及其 SHA-256 文件。
构建并发布后，源码包中的 `BUILDINFO.md` 会记录该次内置 macOS `ffmpeg` 的 SHA-256。
只有 FFmpeg、静态链接库或构建参数改变时，才需要创建新的合规源码包和新的 GitHub Release。

> 本构建不包含任何 GPL 或 nonfree 组件（如 x264、x265、libfdk_aac 等）。
> H.264/H.265 编码通过 Apple VideoToolbox 硬件加速实现，无需 GPL 编码器。
