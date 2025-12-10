# Architecture Changes for Multi-Platform Language Server Distribution

## Overview
This document describes the changes made to support architecture-specific language server builds and automatic downloads in the VSCode extension.

## Changes Made

### 1. GitHub Actions Workflow (`publish-release-version.yml`)

**Updated artifact downloads to support all architectures:**
- Linux x64 and ARM64
- macOS x64 and ARM64 (Apple Silicon)
- Windows x64 and ARM64

**Updated artifact packaging:**
- Changed artifact naming from `hylo-lsp-server-mac-x64.zip` to `hylo-lsp-server-macos-x64.zip`
- Added support for all 6 platform/architecture combinations
- Removed client binary packaging (focusing only on language server)
- Each artifact now includes the language server binary and a version reference file

### 2. VSCode Extension Download Logic (`download-language-server.ts`)

**Platform and Architecture Detection:**
- Updated `getTargetLspFilename()` to use `os.platform()` and `os.arch()` for proper cross-platform support
- Maps platform names correctly: `darwin` → `macos`, `win32` → `windows`, `linux` → `linux`
- Maps architecture names: `x64` → `x64`, `arm64` → `arm64`
- Generates filenames like: `hylo-lsp-server-{platform}-{arch}.zip`

**Version Support:**
- Added `specifiedVersion` parameter to `updateLanguageServer()` function
- Supports downloading specific versions by tag (e.g., `v1.0.0`) or `latest`
- Updated repository URL to point to `hylo-lang/hylo-language-server`

**Executable Naming:**
- Updated `languageServerExecutableFilename()` to use `os.platform()` instead of `os.type()`
- Returns correct executable name for each platform

### 3. VSCode Extension Packaging (`.vscodeignore`)

**Excluded from published extension:**
```
dist/bin/**
dist/hylo-stdlib/**
dist/manifest.json
```

**Result:** Language server binaries are NOT bundled in the published extension and will be downloaded automatically at runtime. Development builds (using `build-and-install-vscode-extension.sh`) will still bundle the binaries with a `"dev"` manifest.

### 4. Extension Configuration (`package.json`)

**New Configuration Options:**
- `hylo.languageServer.version` (default: `"latest"`): Specify which version to download
  - Set to `"latest"` for automatic latest version
  - Set to a specific tag like `"v1.0.0"` for a fixed version
- `hylo.languageServer.autoUpdate` (default: `true`): Automatically check for and download updates

**Updated Repository URL:**
- Changed from `hylo-lang/vscode-hylo` to `hylo-lang/hylo-language-server`

### 5. Extension Activation (`extension.ts`)

**Automatic Language Server Management:**
- On first activation, checks if language server is installed
- Downloads the specified version if not present
- Respects auto-update settings (won't update if disabled or in dev mode)
- Uses configuration settings for version selection
- Proper error handling with user-friendly messages

**Dev Mode Protection:**
- Development builds (with `"name": "dev"` in manifest) are never overwritten by automatic updates
- Allows developers to work with local builds without interference

## Usage

### For End Users (Published Extension)

The extension will automatically:
1. Download the language server on first use
2. Check for updates on each activation (if auto-update is enabled)
3. Download the correct binary for your platform and architecture

**To specify a version:**
1. Open VSCode settings
2. Search for "Hylo"
3. Set `Hylo › Language Server: Version` to your desired version (e.g., `v1.0.0`) or keep as `latest`

**To disable auto-updates:**
1. Open VSCode settings
2. Search for "Hylo"
3. Uncheck `Hylo › Language Server: Auto Update`

**To manually update:**
- Run command: `Hylo: Update Language Server Version`

### For Developers (Local Development)

When building locally with `build-and-install-vscode-extension.sh`:
1. The script creates a `"dev"` manifest
2. Language server binaries are bundled in `dist/bin/`
3. Auto-update is disabled for dev builds
4. You can force an update with the manual update command if needed

## Release Process

### Creating a Release

When creating a new release tag (e.g., `v1.0.0`):
1. The CI builds language servers for all 6 platform/architecture combinations
2. Artifacts are packaged as `hylo-lsp-server-{platform}-{arch}.zip`
3. Release includes:
   - `hylo-stdlib.zip` (standard library)
   - 6 language server binaries (one per platform/arch)
   - Version reference file in each archive

### Artifact Naming Convention

```
hylo-lsp-server-linux-x64.zip
hylo-lsp-server-linux-arm64.zip
hylo-lsp-server-macos-x64.zip
hylo-lsp-server-macos-arm64.zip
hylo-lsp-server-windows-x64.zip
hylo-lsp-server-windows-arm64.zip
hylo-stdlib.zip
```

## Benefits

1. **Smaller Extension Package**: No bundled binaries means faster installation
2. **Cross-Platform Support**: Native binaries for all major platforms and architectures
3. **Flexible Versioning**: Users can pin to specific versions or use latest
4. **Automatic Updates**: Stay up-to-date with the latest language server features
5. **Developer Friendly**: Local development builds work seamlessly without conflicts

## Migration Notes

### Breaking Changes

- Artifact naming changed from `mac` to `macos` in filenames
- Old artifact names will not be found by the new download logic
- First activation after update will download the language server

### Compatibility

- Requires releases to include the new artifact naming scheme
- The extension will automatically detect the correct binary for the user's system
- No user action required for the migration
