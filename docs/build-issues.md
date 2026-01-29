# CodMate 构建问题与解决方案

## 问题描述

CodMate 项目依赖于 Ghostty 终端模拟器库（`libghostty.a`），这是一个用 Zig 编写的静态库。初次构建时遇到以下问题：

1. 缺少 `ghostty/Vendor/lib/libghostty.a` 静态库文件
2. 从源码构建 Ghostty 时遇到 Metal 框架链接错误
3. 构建脚本 `build-libghostty-local.sh` 指向不存在的路径

## 错误信息

### 错误 1：缺少静态库

```
ld: library 'ghostty' not found
clang: error: linker command failed with exit code 1
```

### 错误 2：Metal 框架链接失败

```
error: undefined symbol: _MTLCopyAllDevices
error: undefined symbol: _OBJC_CLASS_$_MTLDepthStencilDescriptor
error: undefined symbol: _OBJC_CLASS_$_MTLRenderPassDescriptor
error: undefined symbol: _OBJC_CLASS_$_MTLRenderPipelineDescriptor
error: undefined symbol: _OBJC_CLASS_$_MTLTextureDescriptor
error: undefined symbol: _OBJC_CLASS_$_MTLVertexDescriptor
```

## 解决方案

### 步骤 1：克隆 Ghostty 源码

```bash
cd /tmp
git clone --depth 1 https://github.com/ghostty-org/ghostty.git ghostty-src
```

### 步骤 2：修复 Ghostty 构建系统

Ghostty 的 `pkg/macos/build.zig` 缺少 Metal 和 MetalKit 框架链接。需要添加以下内容：

**修改前：**
```zig
lib.linkFramework("IOSurface");
```

**修改后：**
```zig
lib.linkFramework("IOSurface");
lib.linkFramework("Metal");
lib.linkFramework("MetalKit");
```

同时需要在模块中添加：

**修改前：**
```zig
module.linkFramework("IOSurface", .{});
```

**修改后：**
```zig
module.linkFramework("IOSurface", .{});
module.linkFramework("Metal", .{});
module.linkFramework("MetalKit", .{});
```

### 步骤 3：构建 Ghostty 静态库

```bash
cd /tmp/ghostty-src
rm -rf zig-cache
zig build -Dapp-runtime=none \
    -Demit-xcframework=false \
    -Demit-macos-app=false \
    -Demit-exe=false \
    -Demit-docs=false \
    -Demit-helpgen=false \
    -Demit-webdata=false \
    -Demit-terminfo=false \
    -Demit-termcap=false \
    -Demit-themes=false \
    -Doptimize=ReleaseFast
```

### 步骤 4：复制构建产物到 CodMate

```bash
cd /Users/dengwenyu/Dev/AI/codmate

# 创建架构特定目录
mkdir -p ghostty/Vendor/lib/aarch64

# 复制静态库
cp /tmp/ghostty-src/zig-out/lib/libghostty.a ghostty/Vendor/lib/aarch64/

# 复制头文件
rsync -av --exclude='module.modulemap' \
    /tmp/ghostty-src/include/ \
    ghostty/Vendor/include/

# 记录版本
git -C /tmp/ghostty-src rev-parse HEAD > ghostty/Vendor/VERSION
```

### 步骤 5：修复 CodMate 的 Package.swift

**修改前：**
```swift
.unsafeFlags([
    "-L", "/Volumes/External/GitHub/CodMate/ghostty/Vendor/lib",
    ...
])
```

**修改后：**
```swift
.unsafeFlags([
    "-L", "/Users/dengwenyu/Dev/AI/codmate/ghostty/Vendor/lib",
    ...
])
```

### 步骤 6：构建并运行 CodMate

```bash
cd /Users/dengwenyu/Dev/AI/codmate
make run
```

## 构建产物

- **静态库位置**: `ghostty/Vendor/lib/aarch64/libghostty.a` (141MB)
- **头文件位置**: `ghostty/Vendor/include/`
- **Ghostty 版本**: `685daee01bbd18dc50c066ccfa85828509068a99`

## 系统要求

- macOS 13.5+
- Xcode Command Line Tools
- Zig 0.15.2+
- Swift 6 toolchain

## 相关文件

- `ghostty/Package.swift` - Ghostty Swift 包配置
- `ghostty/Vendor/lib/libghostty.a` - 静态库文件
- `ghostty/Vendor/include/` - C 头文件
- `scripts/build-libghostty-local.sh` - Ghostty 构建脚本（需要更新路径）
- `scripts/create-app-bundle.sh` - CodMate 应用打包脚本

## 注意事项

1. **架构支持**: 当前仅构建了 aarch64 (Apple Silicon) 版本，如需 x86_64 支持，需要分别构建两个架构然后使用 `lipo` 合并
2. **路径硬编码**: `ghostty/Package.swift` 中的路径是硬编码的，建议使用相对路径或环境变量
3. **Ghostty 版本**: 使用的是 Ghostty 主分支的最新代码，生产环境建议使用稳定版本
4. **构建时间**: Ghostty 静态库构建需要较长时间（约 5-10 分钟）

## 未来改进

1. 使用预编译的 XCFramework 替代手动构建
2. 添加自动化构建脚本，支持多架构
3. 使用相对路径或环境变量配置库路径
4. 添加构建缓存机制，减少重复构建时间

## 参考资料

- [Ghostty GitHub 仓库](https://github.com/ghostty-org/ghostty)
- [Ghostty 构建文档](https://ghostty.org/docs/install/build)
- [Integrating Zig and SwiftUI - Mitchell Hashimoto](https://mitchellh.com/writing/zig-and-swiftui)
- [CodMate README](../README.md)