# 2.0.1 清理规则表

本文件由 `Tests/StorageCleanerMacTests/CleanupRuleTableTests.swift` 从 `CleanupRuleSetLoader.loadBundled()` 生成，请勿手改。规则改动后用 `STORAGE_CLEANER_RECORD_RULE_TABLE=1 swift test --filter CleanupRuleTableTests` 重新生成；文件与规则不一致时测试失败（DECISIONS D100 G4-1）。

规则集 schemaVersion 2，rulesVersion 2026.10.26.1，共 87 条：`developer-catalog` 33 条（`DeveloperToolArtifactCatalog`），`coverage-catalog` 41 条（`CleanupCoverageCatalog`），`json` 13 条（`Resources/CleanupRules.v2.json`）。顺序即加载顺序：多条规则命中同一项目时，排在前面的规则认领。

列说明：根路径中 `~` 是用户主目录；范围与匹配见 `CleanupRule.candidateScope` 和 `include.nameMatcher`；风险、动作、默认勾选为规则里的原始取值；需先退出的 App 是 bundle ID；修订是 `maintenance.revision`。

| # | ID | 来源 | 根路径 | 范围与匹配 | 风险 | 动作 | 默认勾选 | 需先退出的 App | 证据 | 修订 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `developer.codex-cache` | developer-catalog | `~/.codex` | immediateChildren · exact: cache | safe | moveToTrash | unselected | — | — | 1 |
| 2 | `developer.codex-plugin-cache` | developer-catalog | `~/.codex/plugins` | immediateChildren · exact: cache | safe | moveToTrash | unselected | — | — | 1 |
| 3 | `developer.codex-temporary-files` | developer-catalog | `~/.codex` | immediateChildren · exact: tmp | safe | moveToTrash | unselected | — | — | 1 |
| 4 | `developer.codex-logs` | developer-catalog | `~/.codex` | immediateChildren · exact: logs | safe | moveToTrash | selected | — | — | 1 |
| 5 | `developer.claude-code-cache` | developer-catalog | `~/.claude` | immediateChildren · exact: cache | safe | moveToTrash | unselected | — | — | 1 |
| 6 | `developer.claude-code-plugin-cache` | developer-catalog | `~/.claude/plugins` | immediateChildren · exact: cache | safe | moveToTrash | unselected | — | — | 1 |
| 7 | `developer.claude-code-temporary-files` | developer-catalog | `~/.claude` | immediateChildren · exact: tmp | safe | moveToTrash | unselected | — | — | 1 |
| 8 | `developer.claude-code-app-cache` | developer-catalog | `~/Library/Caches` | immediateChildren · exact: Claude, claude-code | safe | moveToTrash | unselected | com.anthropic.claudefordesktop | — | 1 |
| 9 | `developer.claude-code-cli-cache` | developer-catalog | `~/Library/Caches` | immediateChildren · exact: claude-cli-nodejs | safe | moveToTrash | unselected | — | — | 1 |
| 10 | `developer.claude-code-logs` | developer-catalog | `~/.claude` | immediateChildren · exact: debug, logs | safe | moveToTrash | selected | — | — | 1 |
| 11 | `developer.claude-code-telemetry` | developer-catalog | `~/.claude` | immediateChildren · exact: telemetry | safe | moveToTrash | unselected | — | — | 1 |
| 12 | `developer.cursor-cache` | developer-catalog | `~/Library/Application Support/Cursor` | immediateChildren · exact: Cache, CachedData, Code Cache, GPUCache | safe | moveToTrash | unselected | com.todesktop.230313mzl4w4u92 | — | 1 |
| 13 | `developer.cursor-app-cache` | developer-catalog | `~/Library/Caches` | immediateChildren · exact: com.todesktop.230313mzl4w4u92 | safe | moveToTrash | unselected | com.todesktop.230313mzl4w4u92 | — | 1 |
| 14 | `developer.cursor-logs` | developer-catalog | `~/Library/Application Support/Cursor` | immediateChildren · exact: logs | safe | moveToTrash | selected | com.todesktop.230313mzl4w4u92 | — | 1 |
| 15 | `developer.github-copilot-cache` | developer-catalog | `~/.cache` | immediateChildren · exact: github-copilot | safe | moveToTrash | unselected | — | — | 1 |
| 16 | `developer.github-copilot-app-cache` | developer-catalog | `~/Library/Caches` | immediateChildren · exact: GitHub Copilot | safe | moveToTrash | unselected | — | — | 1 |
| 17 | `developer.github-copilot-logs` | developer-catalog | `~/Library/Logs` | immediateChildren · exact: GitHub Copilot | safe | moveToTrash | selected | — | — | 1 |
| 18 | `developer.opencode-cache` | developer-catalog | `~/.cache` | immediateChildren · exact: opencode | safe | moveToTrash | unselected | — | — | 1 |
| 19 | `developer.opencode-logs` | developer-catalog | `~/.local/share/opencode` | immediateChildren · exact: log, logs | safe | moveToTrash | selected | — | — | 1 |
| 20 | `developer.openclaw-cache` | developer-catalog | `~/.openclaw` | immediateChildren · exact: cache | safe | moveToTrash | unselected | — | — | 1 |
| 21 | `developer.openclaw-temporary-files` | developer-catalog | `~/.openclaw` | immediateChildren · exact: tmp | safe | moveToTrash | unselected | — | — | 1 |
| 22 | `developer.openclaw-app-cache` | developer-catalog | `~/Library/Caches` | immediateChildren · exact: OpenClaw | safe | moveToTrash | unselected | — | — | 1 |
| 23 | `developer.openclaw-logs` | developer-catalog | `~/.openclaw` | immediateChildren · exact: logs | safe | moveToTrash | selected | — | — | 1 |
| 24 | `developer.openclaw-app-logs` | developer-catalog | `~/Library/Logs` | immediateChildren · exact: OpenClaw | safe | moveToTrash | selected | — | — | 1 |
| 25 | `developer.workbuddy-logs` | developer-catalog | `~/.workbuddy` | immediateChildren · exact: logs, traces | safe | moveToTrash | selected | — | — | 1 |
| 26 | `developer.windsurf-logs` | developer-catalog | `~/Library/Application Support/Windsurf` | immediateChildren · exact: logs | safe | moveToTrash | selected | — | — | 1 |
| 27 | `developer.continue-index` | developer-catalog | `~/.continue` | immediateChildren · exact: index | safe | moveToTrash | unselected | — | — | 1 |
| 28 | `developer.claude-desktop-web-cache` | developer-catalog | `~/Library/Application Support/Claude` | immediateChildren · exact: Cache, Code Cache, GPUCache | safe | moveToTrash | unselected | com.anthropic.claudefordesktop | <https://www.electronjs.org/docs/latest/api/app#appgetpathname><br><https://www.electronjs.org/docs/latest/api/session#sesclearcache> | 1 |
| 29 | `developer.codex-desktop-web-cache` | developer-catalog | `~/Library/Application Support/Codex` | immediateChildren · exact: Cache, Code Cache, GPUCache | safe | moveToTrash | unselected | com.openai.codex | <https://www.electronjs.org/docs/latest/api/app#appgetpathname><br><https://www.electronjs.org/docs/latest/api/session#sesclearcache> | 1 |
| 30 | `developer.vscode-web-cache` | developer-catalog | `~/Library/Application Support/Code` | immediateChildren · exact: Cache, Code Cache, GPUCache | safe | moveToTrash | unselected | com.microsoft.VSCode | <https://www.electronjs.org/docs/latest/api/app#appgetpathname><br><https://www.electronjs.org/docs/latest/api/session#sesclearcache> | 1 |
| 31 | `developer.vscode-logs` | developer-catalog | `~/Library/Application Support/Code` | immediateChildren · exact: logs | safe | moveToTrash | selected | com.microsoft.VSCode | <https://github.com/microsoft/vscode/blob/main/src/vs/platform/environment/common/environmentService.ts> | 2 |
| 32 | `developer.lmstudio-web-cache` | developer-catalog | `~/Library/Application Support/LM Studio` | immediateChildren · exact: Cache, Code Cache, GPUCache | safe | moveToTrash | unselected | — | <https://www.electronjs.org/docs/latest/api/app#appgetpathname><br><https://www.electronjs.org/docs/latest/api/session#sesclearcache> | 1 |
| 33 | `developer.rod-browser-downloads` | developer-catalog | `~/.cache/rod` | immediateChildren · exact: browser | safe | moveToTrash | unselected | — | <https://github.com/go-rod/rod/blob/main/lib/launcher/browser.go> | 1 |
| 34 | `browser-cache.google-chrome` | coverage-catalog | `~/Library/Caches/Google` | immediateChildren · exact: Chrome | safe | moveToTrash | selected | com.google.Chrome | — | 1 |
| 35 | `browser-cache.safari` | coverage-catalog | `~/Library/Containers/com.apple.Safari/Data/Library` | immediateChildren · exact: Caches | safe | moveToTrash | selected | com.apple.Safari | — | 1 |
| 36 | `browser-cache.microsoft-edge` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: Microsoft Edge | safe | moveToTrash | selected | com.microsoft.edgemac | — | 1 |
| 37 | `browser-cache.brave` | coverage-catalog | `~/Library/Caches/BraveSoftware` | immediateChildren · exact: Brave-Browser | safe | moveToTrash | selected | com.brave.Browser | — | 1 |
| 38 | `browser-cache.firefox` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: Firefox | safe | moveToTrash | selected | org.mozilla.firefox | — | 1 |
| 39 | `browser-cache.arc` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: company.thebrowser.Browser | safe | moveToTrash | selected | company.thebrowser.Browser | — | 1 |
| 40 | `application-cache.whatsapp` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: net.whatsapp.WhatsApp | safe | moveToTrash | selected | net.whatsapp.WhatsApp | — | 1 |
| 41 | `application-cache.codex` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: Codex, com.openai.codex | safe | moveToTrash | selected | com.openai.codex | — | 1 |
| 42 | `application-cache.ego-lite` | coverage-catalog | `~/Library/Caches/Citro Labs` | immediateChildren · exact: ego lite | safe | moveToTrash | selected | com.citrolabs.ego.lite | — | 1 |
| 43 | `application-cache.typeless-updater` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: typeless-updater | safe | moveToTrash | selected | now.typeless.desktop | — | 1 |
| 44 | `application-cache.zoom` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: us.zoom.xos | safe | moveToTrash | selected | us.zoom.xos | — | 1 |
| 45 | `developer.playwright-mcp-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: ms-playwright-mcp | safe | moveToTrash | unselected | — | — | 1 |
| 46 | `developer.pip-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: pip | safe | moveToTrash | unselected | — | — | 1 |
| 47 | `developer.swiftpm-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: org.swift.swiftpm | safe | moveToTrash | unselected | — | — | 1 |
| 48 | `developer.clang-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: clang | safe | moveToTrash | unselected | — | — | 1 |
| 49 | `developer.bun-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: bun | safe | moveToTrash | unselected | — | — | 1 |
| 50 | `developer.go-build-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: go-build | safe | moveToTrash | unselected | — | — | 1 |
| 51 | `developer.gopls-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: gopls | safe | moveToTrash | unselected | — | — | 1 |
| 52 | `developer.golangci-lint-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: golangci-lint | safe | moveToTrash | unselected | — | — | 1 |
| 53 | `developer.playwright-browsers` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: ms-playwright, ms-playwright-go | safe | moveToTrash | unselected | — | — | 1 |
| 54 | `developer.pnpm-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: pnpm | safe | moveToTrash | unselected | — | — | 1 |
| 55 | `developer.yarn-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: Yarn | safe | moveToTrash | unselected | — | — | 1 |
| 56 | `developer.node-gyp-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: node-gyp | safe | moveToTrash | unselected | — | — | 1 |
| 57 | `developer.typescript-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: typescript | safe | moveToTrash | unselected | — | — | 1 |
| 58 | `developer.deno-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: deno | safe | moveToTrash | unselected | — | — | 1 |
| 59 | `developer.electron-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: electron, electron-builder | safe | moveToTrash | unselected | — | — | 1 |
| 60 | `developer.cypress-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: Cypress | safe | moveToTrash | unselected | — | — | 1 |
| 61 | `developer.poetry-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: pypoetry | safe | moveToTrash | unselected | — | — | 1 |
| 62 | `developer.cocoapods-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: CocoaPods | safe | moveToTrash | unselected | — | — | 1 |
| 63 | `developer.carthage-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: org.carthage.CarthageKit | safe | moveToTrash | unselected | — | — | 1 |
| 64 | `developer.sccache-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: Mozilla.sccache | safe | moveToTrash | unselected | — | — | 1 |
| 65 | `developer.flutter-cache` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: flutter_engine | safe | moveToTrash | unselected | — | — | 1 |
| 66 | `system-log.diagnostics` | coverage-catalog | `~/Library/Logs` | immediateChildren · exact: com.apple.diagnosticextensionsd | safe | moveToTrash | selected | — | — | 1 |
| 67 | `application-log.codex` | coverage-catalog | `~/Library/Logs` | immediateChildren · exact: com.openai.codex | safe | moveToTrash | selected | com.openai.codex | — | 1 |
| 68 | `system-cache.cloudkit` | coverage-catalog | `~/Library/Caches` | immediateChildren · exact: CloudKit | reviewOnly | moveToTrashAfterReview | unselected | — | — | 1 |
| 69 | `mail.downloaded-attachments` | coverage-catalog | `~/Library/Containers/com.apple.mail/Data/Library` | immediateChildren · exact: Mail Downloads | reviewOnly | moveToTrashAfterReview | unselected | com.apple.mail | — | 1 |
| 70 | `mail.library-attachment-folders` | coverage-catalog | `~/Library/Mail` | namedDescendantDirectories · exact: Attachments | reviewOnly | moveToTrashAfterReview | unselected | com.apple.mail | — | 1 |
| 71 | `system.broken-preferences` | coverage-catalog | `~/Library/Preferences` | immediateChildren · any | reviewOnly | moveToTrashAfterReview | unselected | — | — | 1 |
| 72 | `trash.user-trash` | coverage-catalog | `~/.Trash` | root · any | protected | emptyTrash | unselected | — | — | 1 |
| 73 | `trash.volume-trashes` | coverage-catalog | `/Volumes` | root · any | protected | emptyTrash | unselected | — | — | 1 |
| 74 | `trash.icloud-drive` | coverage-catalog | `~/Library/Mobile Documents/.Trash` | root · any | protected | emptyTrash | unselected | — | — | 1 |
| 75 | `developer.npx-cache` | json | `~/.npm` | immediateChildren · exact: _npx | safe | moveToTrash | selected | — | — | 1 |
| 76 | `developer.npm-content-cache` | json | `~/.npm` | immediateChildren · exact: _cacache | safe | moveToTrash | unselected | — | — | 1 |
| 77 | `developer.homebrew-cache` | json | `~/Library/Caches` | immediateChildren · exact: Homebrew | safe | moveToTrash | unselected | — | — | 1 |
| 78 | `developer.uv-cache` | json | `~/.cache` | immediateChildren · exact: uv | safe | moveToTrash | unselected | — | — | 1 |
| 79 | `developer.bun-install-cache` | json | `~/.bun/install/cache` | root · any | safe | moveToTrash | unselected | — | <https://bun.sh/docs/install/cache><br><https://bun.sh/docs/cli/pm> | 1 |
| 80 | `developer.xcode-derived-data` | json | `~/Library/Developer/Xcode/DerivedData` | root · any | safe | moveToTrash | unselected | com.apple.dt.Xcode | — | 1 |
| 81 | `developer.xcode-ios-device-support` | json | `~/Library/Developer/Xcode/iOS DeviceSupport` | immediateChildren · any | safe | moveToTrash | unselected | com.apple.dt.Xcode | — | 1 |
| 82 | `developer.gradle-cache` | json | `~/.gradle` | immediateChildren · exact: caches | safe | moveToTrash | unselected | — | <https://docs.gradle.org/current/userguide/directory_layout.html> | 1 |
| 83 | `developer.cargo-registry-cache` | json | `~/.cargo/registry` | immediateChildren · exact: cache | safe | moveToTrash | unselected | — | <https://doc.rust-lang.org/cargo/guide/cargo-home.html> | 1 |
| 84 | `system.user-caches` | json | `~/Library/Caches` | immediateChildren · any | safe | moveToTrash | selected | — | — | 1 |
| 85 | `system.user-logs` | json | `~/Library/Logs` | immediateChildren · any | safe | moveToTrash | selected | — | — | 1 |
| 86 | `user-data.istat-menus-setapp-history` | json | `~/Library/Application Support/iStat Menus 7 (Setapp)` | immediateChildren · exact: history | reviewOnly | moveToTrashAfterReview | unselected | com.bjango.istatmenus-setapp, com.bjango.istatmenus-setapp.agent, com.bjango.istatmenus-setapp.history, com.bjango.istatmenus-setapp.status | — | 1 |
| 87 | `applications.duplicate-installed-apps` | json | `/Applications` | immediateChildren · any | protected | moveToTrashAfterProtectedReview | unselected | — | — | 1 |
