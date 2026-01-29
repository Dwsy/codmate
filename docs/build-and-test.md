# 构建和测试 CodMate 应用

## 构建命令

### 使用 make (推荐)

```bash
# 构建应用包
make app

# 使用特定版本号构建
BASE_VERSION=1.2.3 make app

# 构建 DMG（需要签名和公证）
make dmg

# 使用特定版本号构建 DMG
BASE_VERSION=1.2.3 make dmg
```

### 使用 SwiftPM

```bash
# 调试构建
swift build

# Release 构建
swift build -c release

# 运行应用（可能遇到问题）
swift run CodMate
```

## 手动测试搜索功能

### 方法一：使用演示脚本

```bash
# 运行演示脚本
/tmp/demo_search.swift
```

这会展示消息提取和简单搜索的基本功能。

### 方法二：构建应用后测试

1. **构建应用**
   ```bash
   make app
   ```

2. **运行应用**
   - 打开 `.build/debug/CodMate.app`
   - 或使用 Finder 打开构建好的应用

3. **测试搜索**
   - 在应用右上角找到搜索框（或使用快捷键 Cmd+Shift+F）
   - 输入搜索关键词（例如："api", "bug", "component"）
   - 查看搜索结果，确认显示 "User:" 或 "Assistant:" 前缀的消息

### 方法三：使用测试脚本验证消息提取

```bash
# 运行测试脚本（验证消息提取逻辑）
/tmp/test_search.swift
```

## 预期行为

### 搜索结果示例

当搜索 "塔板数" 时，应该看到：
```
📄 Sessions
   User: sheet1_to_md_correct.md  1) 两个"明显不对"的信号...
```

当搜索多个关键词 "web api" 时，可能会看到：
```
📄 Sessions
   User: 创建 web api 接口...
   Assistant: 我来帮您创建 web api 接口...
   User: 测试 web api 的代码...
```

### 搜索特点

1. **模糊匹配**：搜索 "react comp" 会匹配 "react component"
2. **多关键词**：搜索 "api auth" 会匹配同时包含 "api" 和 "auth" 的消息
3. **智能排序**：最相关、最新的结果排在前面
4. **消息标识**：清晰显示消息来源（User 或 Assistant）

## 常见问题

### 问题：构建时出现 "bundleProxyForCurrentProcess is nil"

这是 SwiftUI macOS 应用从命令行运行时的已知问题。正确做法是：
1. 构建应用包：`make app`
2. 从 Finder 运行应用，而不是使用 `swift run`

### 问题：搜索结果中没有消息

可能的原因：
1. 会话文件中没有匹配的消息（只有工具调用等）
2. 搜索词太具体，没有匹配到
3. 会话文件格式不同（可以尝试其他会话文件）

解决方法：
```bash
# 检查一个会话文件的内容
head -20 ~/.codex/sessions/2025/12/30/*.jsonl | jq .

# 在文件中搜索 user_message 或 agent_message
grep -c 'user_message' ~/.codex/sessions/2025/12/30/*.jsonl
```

### 问题：构建失败

如果遇到编译错误：
1. 检查 Swift 版本：`swift --version`（需要 Swift 5.9+）
2. 清理构建：`rm -rf .build`
3. 重新构建：`swift build`

## 验证修改

可以通过以下方式验证修改是否生效：

1. **检查代码**：确认 `scanSessionMessages` 函数存在
   ```bash
   grep -A5 "func scanSessionMessages" services/GlobalSearchService.swift
   ```

2. **检查搜索结果格式**：搜索结果应该包含 "User:" 或 "Assistant:" 前缀

3. **性能测试**：搜索大文件（> 1MB）时，响应时间应该在可接受范围内（< 2秒）

## 调试技巧

如果搜索功能不工作，可以：

1. **打印调试信息**（在开发构建中）：
   ```swift
   // 在 scanSessionMessages 函数中添加
   print("Processing line \(lineNumber): \(messageType ?? "unknown")")
   ```

2. **检查会话文件**：
   ```bash
   # 查看会话文件结构
   cat ~/.codex/sessions/2025/12/30/*.jsonl | jq -r '.payload.type' | sort | uniq -c
   ```

3. **测试单个文件**：
   ```bash
   # 运行测试脚本验证提取逻辑
   /tmp/test_search.swift ~/.codex/sessions/2025/12/30/*.jsonl
   ```

## 性能注意事项

- 首次搜索时可能需要加载和解析会话文件
- 大文件（> 10MB）搜索可能需要更长时间
- 搜索结果限制为最多 160 条（可在 GlobalSearchViewModel 中调整）
- 每文件最多匹配 3 条结果（可在 Request 初始化中调整）

## 下一步

如果测试通过，可以：
1. 提交更改到 git
2. 创建测试用例
3. 考虑添加更多搜索过滤选项
4. 优化性能（如果必要）
