# HIR-249 replacement-engine PoC

This is a launcher-agnostic SwiftPM experiment for selected-text replacement. It does **not** depend on Hammerspoon or Lua; its location in `scripts-hammerspoon` is only an experiment workspace for HIR-249.

The PoC keeps capture, revalidation, mutation strategy, postcondition verification, clipboard handling, and outcome classification inside one macOS process. Replacement content is read from stdin and is not accepted as a process argument. stdout and the temporary JSONL diagnostic log contain only content-free metadata.

## Safety boundary

The executable refuses mutation unless `--controlled-fixture` is supplied. HIR-249 runtime work is limited to disposable/non-sensitive fixtures. For clipboard-based target revalidation, use a selection containing a unique sentinel within the controlled fixture so the same selected text cannot ambiguously identify another location in the same window. Target drift is checked before the strategy chain and before every strategy attempt. Direct AX writes are treated as `no_op` only after bounded polling keeps observing the exact original value. An event that was dispatched but cannot be verified is terminal as `replacement_dispatched_unverified`; the engine does not continue to another strategy and risk duplicate input.

For Slack (`com.tinyspeck.slackmacgap`) and Meru (`sh.zoid.meru`), target capture does not trust the system-wide focused element alone. It searches the focused window for `AXTextArea` candidates, requires an unambiguous selected-text context, and prefers the focused candidate. If a unique structural target cannot be resolved, the engine fails closed rather than performing an exploratory write.

Clipboard paste strategies use a bounded post-dispatch hold before restoring the original clipboard when no AX postcondition is available. This is controlled by `--paste-hold-ms` (default 150 ms) and is intended to avoid racing applications that consume the pasteboard asynchronously. The hold does not convert an unobservable dispatch into success; the outcome remains `replacement_dispatched_unverified` unless an exact postcondition is observed.

The normal strategy order is:

1. verified `AXSelectedText`
2. verified `AXValue + selected range`
3. clipboard + Command-V
4. Paste and Match Style
5. Unicode injection
6. chunked Unicode injection

Later event-based strategies can also be exercised individually in controlled diagnostic mode even when an earlier dispatched event would be terminal in the normal chain.

## Build and run on macOS

From this directory:

```sh
swift build
printf %s 'replacement fixture' | swift run replacement-engine --controlled-fixture --delay-ms 500
```

Exercise a single strategy:

```sh
printf %s 'replacement fixture' | swift run replacement-engine \
  --controlled-fixture \
  --mode single \
  --strategy paste_match_style
```

For the clipboard lifecycle discriminating experiment, vary the bounded hold explicitly:

```sh
printf %s 'replacement fixture' | swift run replacement-engine \
  --controlled-fixture \
  --mode single \
  --strategy clipboard_cmd_v \
  --paste-hold-ms 150
```

Start the diagnostic chain at a later strategy:

```sh
printf %s 'replacement fixture' | swift run replacement-engine \
  --controlled-fixture \
  --mode from \
  --strategy unicode_injection
```

The process needs macOS Accessibility permission for AX and synthetic keyboard-event behavior. Repository/static inspection does not prove that this permission or any application-specific replacement path works at runtime.

## Outcomes

stdout returns content-free JSON and one of four outcomes:

- `verified_replaced`
- `replacement_dispatched_unverified`
- `not_replaced`
- `error`

Exit codes are 0, 3, 2, and 1 respectively.

## Temporary diagnostic log

Default path:

```text
~/Library/Logs/hir-249-replacement-engine.jsonl
```

Each line records timestamp, bundle ID, attempted strategies, verification class, reason code, latency, and final outcome. It must not contain selected text, replacement text, prompt/response content, clipboard content, or AXValue content. A structured-log write failure is emitted as a content-free stderr warning without changing an already-known replacement outcome. The HIR-249 Plan requires cleanup after handoff or within 14 days; this PoC does not install a background retention mechanism.
