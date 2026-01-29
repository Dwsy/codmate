# Changelog

All notable changes to CodMate will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

#### Pi Agent Integration
- **Complete Pi session support**: Load, display, and manage Pi Agent sessions alongside Codex, Claude, and Gemini
- **Pi session parser**: Parse Pi session format (.jsonl) with full message extraction
- **Pi settings page**: Configure Pi CLI, session paths, and command options
- **Pi usage status**: Display version, default provider, and model information
- **PiIcon asset**: Visual identification for Pi sessions in the UI

#### Message Search
- **Message-level fuzzy search**: Search user and assistant messages within session files
- **FTS5 full-text search**: SQLite-based full-text search with ranking
- **Multi-keyword support**: Search with multiple keywords (e.g., "web api")
- **Message type prefix**: Clear display of "User:" or "Assistant:" in search results
- **Smart scoring**: Results ranked by match quality, recency, and position

#### Pi CLI Integration
- **Pi resume support**: Resume Pi sessions with embedded terminal
- **Pi new session support**: Create new Pi sessions from existing ones
- **Session timeline**: View complete conversation history for Pi sessions
- **Model tracking**: Track and display Pi model usage across sessions

### Changed

- Updated SessionSource.Kind to include `.pi` case
- Updated SettingCategory to include `.pi` settings page
- Updated UsageProviderKind to include `.pi` provider
- Updated all UI components to display PiIcon when appropriate
- Enhanced SessionListViewModel to include Pi provider

### Removed

- **ChromeCookieImporter**: Removed unused Chrome cookie import (Safari-only now)

### Documentation

- Added `docs/build-and-test.md`: Comprehensive build and testing guide
- Added `docs/build-issues.md`: Ghostty library build troubleshooting
- Added `docs/message-search-feature.md`: Message search feature documentation
- Added `docs/message-search-implementation.md`: Implementation details
- Added `task/pi-codmate-integration/README.md`: Complete Pi integration project documentation
- Added `final-verification.sh`: Automated verification script for Pi integration

### Technical Details

#### Pi Integration Statistics
- **Sessions loaded**: 1,897 Pi sessions
- **Messages parsed**: 116,011 messages (9,964 user + 106,047 assistant)
- **Models tracked**: 38 different Pi models
- **Projects**: 75 different project directories
- **Time range**: 23 days of session history

#### Database Schema Changes
- Added `messages` table for message indexing
- Added `messages_fts` virtual table for FTS5 full-text search
- Added indexes for message search optimization

#### Session Indexing
- Parse levels: metadata → full → preview
- Timeline previews for 43+ sessions
- Complete message extraction with JSON handling

---

## [Previous Versions]

See git history for earlier changes.