# 📢 Latest Update - January 29, 2026

## ✨ New: Pi Agent Support + Message Search

### 🎉 Pi Agent Complete Integration

CodMate now fully supports **Pi Agent** sessions! Manage your Pi sessions alongside Codex, Claude, and Gemini.

**Quick Stats:**
- ✅ 1,897 Pi sessions loaded
- ✅ 116,011 messages parsed
- ✅ 38 different models tracked
- ✅ 75 project directories

**What You Can Do:**
1. **Browse Pi Sessions**: All Pi sessions appear in the main list
2. **View Timeline**: See complete conversation history
3. **Resume Sessions**: Continue work in embedded terminal
4. **Configure Settings**: Go to Settings → Pi to customize

### 🔍 Message-Level Fuzzy Search

Search now finds **messages**, not just files!

**Try These Searches:**
- `"react component"` - Find React component discussions
- `"api authentication"` - Locate auth-related conversations
- `"bug fix"` - See bug fix discussions

**Results Show:**
- `User: [message content]` - User messages
- `Assistant: [message content]` - AI responses

### 📚 Documentation

New documentation added:
- `CHANGELOG.md` - Detailed change history
- `RELEASE_NOTES.md` - Complete release notes
- `docs/build-and-test.md` - Build and testing guide
- `docs/message-search-feature.md` - Search feature docs
- `task/pi-codmate-integration/README.md` - Pi integration details

### 🔧 Technical Updates

- Added FTS5 full-text search for messages
- New database schema for message indexing
- PiIcon asset for visual identification
- Verification script for health checks

---

## 🚀 Quick Start

```bash
# Pull latest changes
git pull origin main

# Build
make app

# Run
open build/CodMate.app

# Verify Pi integration
./final-verification.sh
```

---

## 📖 More Information

- **Full Release Notes**: See `RELEASE_NOTES.md`
- **Changelog**: See `CHANGELOG.md`
- **Build Guide**: See `docs/build-and-test.md`

---

**Enjoy the new features! 🎊**