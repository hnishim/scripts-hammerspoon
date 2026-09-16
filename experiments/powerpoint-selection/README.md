# PowerPoint selection capture PoC

HIR-264のcontrolled fixture専用Spikeです。稼働中Hammerspoonから
`hs.application.frontmostApplication()` でPowerPointのbundle IDを確認し、
`hs.osascript.applescript` でPowerPointのselectionをcaptureします。Native writeの直前にも
同じ比較値を再取得して比較します。

## 実行方法

1. PowerPointで、保存不要の新規プレゼンテーションを作成します
2. 1枚のslideに、機密でない固定文字列を含むテキストボックスを1つ置き、文字列の一部を選択します
3. Hammerspoon Consoleで次を実行します

```lua
package.path = package.path .. ";" .. hs.configdir .. "/experiments/powerpoint-selection/?.lua"
local pp = require("PowerPointSelection")
local captured, err = pp.capture()
assert(captured, err)
-- captured.selectedTextは比較のためだけにメモリ上に保持し、表示・ログ・保存しない。
local matches, revalidateErr = pp.revalidate(captured)
assert(matches, revalidateErr)
local written, writeErr = pp.writeSelection(captured, "FIXTURE_REPLACEMENT")
assert(written, writeErr)
local afterWrite, afterWriteErr = pp.capture()
assert(afterWrite, afterWriteErr)
assert(afterWrite.selectedText == "FIXTURE_REPLACEMENT")
```

Capture後から `writeSelection` までの間に、PowerPoint以外を前面にする、slideやwindowを
切り替える、selectionを変更・collapseする、別presentationを前面にする、または本文を
変更すると、native writeを拒否します。Selection type、offset、length、本文、shape range
count、windowのname/caption/entry_index、presentationのname/pathも比較対象です。PowerPointが
前面でない場合もLua側で拒否します。

このPoCはcontrolled fixture限定であり、本番統合ではありません。本番入口への統合、AI/API、
clipboard、Office.js、Accessibility tree、追加依存は使用しません。Native writeはPowerPointの
selectionのtext rangeへ直接行います。

Text selectionではshape range countが0となり、完全なshape IDを取得できません。そのため、同一
slide上の別shapeが同じ比較値と同じ本文を持つ状態で利用条件（AIコマンド実行後から結果反映まで
選択を動かさない）が破られた場合、別shapeへ書き込む残余リスクがあります。

選択本文はログにも永続化にも出力しません。Capture結果は呼び出し元のメモリに返るため、fixture
実行後は参照を破棄してください。
