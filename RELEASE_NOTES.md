# Release Notes - Pi Agent Integration & Message Search

**Version**: Development Build
**Date**: 2026-01-29
**Release Type**: Feature Release

---

## 🎉 Major Features

### 1. Pi Agent Complete Integration

CodMate now fully supports **Pi Agent** sessions alongside Codex, Claude, and Gemini!

#### What's New
- ✅ **Session Loading**: Load all 1,897+ Pi sessions from `~/.pi/agent/sessions/`
- ✅ **Message Parsing**: Extract 116,011 messages with full context
- ✅ **Timeline View**: Browse complete conversation history
- ✅ **Settings Page**: Configure Pi CLI, paths, and options
- ✅ **Usage Status**: Monitor Pi version, provider, and model usage
- ✅ **Resume & New Session**: Full Pi CLI integration

#### Statistics
```
Pi Sessions:      1,897 (97.2% of total)
User Messages:     9,964
Assistant Messages: 106,047
Total Messages:    116,011
Models Tracked:    38 different models
Projects:          75 directories
```

#### How to Use
1. **Enable Pi CLI**: Go to Settings → Pi → Toggle "Enable Pi CLI"
2. **Browse Sessions**: Pi sessions appear in the main session list
3. **View Timeline**: Click any Pi session to see full conversation
4. **Resume Session**: Use the Resume button to continue in embedded terminal
5. **Configure**: Adjust session paths and command options in Settings

---

### 2. Message-Level Fuzzy Search

Search now finds messages, not just files!

#### What's New
- 🔍 **Message Search**: Search user and assistant messages directly
- 🎯 **Fuzzy Matching**: Support multi-keyword search (e.g., "web api")
- 📊 **Smart Ranking**: Results sorted by relevance, recency, and position
- 🏷️ **Type Labels**: Clear "User:" or "Assistant:" prefixes
- ⚡ **FTS5 Indexing**: Fast SQLite full-text search

#### Search Examples
```
Search: "react component"
→ User: Implement react component structure
→ Assistant: Created component with hooks

Search: "api authentication"
→ User: Add API authentication middleware
→ Assistant: Implemented JWT auth
```

#### Technical Details
- Uses SQLite FTS5 full-text search engine
- Supports boolean operators (AND, OR)
- Ranks results by match quality and recency
- Falls back to file content search if no messages found

---

## 🔄 Changes & Improvements

### Added
- PiIcon asset for visual identification
- PiSettingsView for configuration
- PiSessionProvider for session enumeration
- PiSessionParser for .jsonl format parsing
- PiSettingsService for settings management
- Messages table with FTS5 search
- Message extraction and indexing
- Verification script for integration health check

### Changed
- SessionSource.Kind now includes `.pi`
- SettingCategory now includes `.pi`
- UsageProviderKind now includes `.pi`
- All UI components updated to display PiIcon
- SessionListViewModel includes Pi provider

### Removed
- ChromeCookieImporter (unused, Safari-only now)

### Documentation
- `docs/build-and-test.md` - Build and testing guide
- `docs/build-issues.md` - Troubleshooting guide
- `docs/message-search-feature.md` - Search feature docs
- `docs/message-search-implementation.md` - Implementation details
- `task/pi-codmate-integration/README.md` - Project documentation
- `CHANGELOG.md` - Structured changelog

---

## 📦 Installation & Setup

### Requirements
- macOS 13.5+
- Xcode Command Line Tools
- Pi Agent (optional, for Pi sessions)

### Build from Source
```bash
# Clone repository
git clone https://github.com/Dwsy/codmate.git
cd codmate

# Build
make app

# Run
open build/CodMate.app
```

### Verification
Run the verification script to check Pi integration:
```bash
./final-verification.sh
```

Expected output:
```
✅ App 运行正常
✅ 数据库完整
✅ 1897 个 Pi 会话已加载
✅ 时间线预览正常
✅ 所有核心功能正常
```

---

## 🐛 Known Issues

- Ghostty library may require manual build on first setup
- See `docs/build-issues.md` for solutions

---

## 🚀 Future Enhancements

- Message type filtering (search only user/assistant messages)
- Search syntax support (e.g., "user:keyword")
- Time range filtering for messages
- Click-to-jump to message position in timeline
- Extended search to tool call descriptions

---

## 📝 Migration Notes

### Database Schema
New tables added:
- `messages` - Stores session messages for search
- `messages_fts` - FTS5 virtual table for full-text search

### Backward Compatibility
- ✅ All existing sessions remain unchanged
- ✅ No migration required for existing data
- ✅ Search works with all session formats

---

## 🙏 Acknowledgments

Pi Agent integration successfully completed with:
- 59 files modified/created
- ~2,470 lines of code added
- 100% feature completion
- All tests passing

---

## 📞 Support

- **Issues**: https://github.com/Dwsy/codmate/issues
- **Documentation**: See `docs/` directory
- **Build Guide**: `docs/build-and-test.md`

---

**Enjoy using Pi Agent sessions in CodMate! 🎉**