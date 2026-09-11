## Runtime diagnostics

Hammerspoon runtimeへの状態確認・診断・一時Lua実行には、原則 `hs.ipc` 経由の `hs` CLIを使用する。

`hs.ipc` は `~/.hammerspoon/init.lua` で有効化済み。

```bash
hs -q -t 5 -c 'print(hs.application.frontmostApplication():name())'
```

- Git上のLuaと、現在Hammerspoonにロードされているruntime stateは同一とは限らない
- runtime確認が必要な場合は、source inspectionだけで判断せず hs CLIで確認する

## macOS runtime tests

- Finder / System Events / Apple Events / Hammerspoon IPCなど、macOSのGUI・Automation runtimeに依存する挙動は restricted sandbox の結果だけで判断しない
- restricted sandboxでは、実際のmacOS runtimeでは発生しないcompile error、IPC error、Automation failureが発生する場合がある
- これらの挙動を検証する場合は、通常のmacOS execution contextで再現確認する
- sandboxは以下には使用してよい。
  - source inspection
  - static analysis
  - syntax check（macOS application terminologyを必要としないもの）
  - unit tests
  - filesystem上だけで完結する処理
- AppleScriptのFinder terminologyを含むsourceがsandboxでcompile失敗しても、通常macOS contextで再確認するまでsource自体の不具合とは判断しない
