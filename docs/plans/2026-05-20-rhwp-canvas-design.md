# rhwp-canvas 설계 문서

자유 편집 가능한 HWP 캔버스 — Phoenix LiveView hook + rhwp WASM.

## 1. 문제

기존 매칭박스 모델: 정해진 placeholder 영역만 input field UI 로 편집. 본문
다른 글자/문단/표 구조 자체는 변경 불가.

요구: 한컴 native 처럼 어디든 클릭 → 캐럿 → 자유 편집. 매칭(미리 라벨된 채워야
할 자리)은 navigation/검증 단위로만 유지.

## 2. 아키텍처

```
LiveView 셸 (Phoenix)
└── rhwp-canvas hook (assets/js/rhwp.js)
    ├── rhwp WASM (vendored /priv/static/assets/rhwp/)
    │   ├── 문서 모델 (mutable Document)
    │   ├── 렌더러 (renderPageSvg)
    │   └── DocumentEvent log (getEventLog)
    ├── Canvas SVG 페이지들 (per-page section)
    ├── 캐럿 div (overlay, position: absolute %)
    ├── hidden textarea (IME composition)
    └── fieldHighlights[] (메모리상 매칭 카탈로그)
```

문서 모델은 WASM 안. 우리는 mutation 호출 + 페이지 SVG 재렌더 + UI 오버레이.

## 3. 좌표 시스템

- WASM 페이지 좌표: 페이지 width = 793.7, height = 1122.5 (HWP page units).
- 화면 좌표: SVG viewBox 가 페이지 좌표 그대로, container DOM 이 CSS px 로
  scale.
- 변환: viewBox 비율로 client px ↔ page px.

캐럿/selection 은 `position: absolute; top/left: %` 로 SVG 좌표를 페이지 div
에 그대로 매핑. 페이지 reflow 후 SVG 만 다시 그리면 % 좌표는 자연스럽게 따라옴.

## 4. 클릭 → 캐럿 (hit-test)

1. `document.elementFromPoint(clientX, clientY)` → SVG 또는 그 안 글자 원소.
2. `closest('section.rhwp-svg-page')` 로 페이지 div 추출.
3. viewBox 비율로 client px → page px 변환.
4. `wasm.hitTest(pageIdx, pageX, pageY)` → `{cursorRect, sectionIndex,
   paragraphIndex, charOffset, parentParaIndex?, controlIndex?, cellIndex?,
   cellParaIndex?}`.
5. caretState = state, placeCanvasCaret 으로 % div 그림.

cursor_rect.rs 의 hit_test 가 line/run 경계에서 정확하지 않은 케이스가 있어
별도 fix (#112) — line 안 모든 run 의 bbox 를 보고 find_char_at_x 까지 함께
사용.

## 5. 키보드 입력 + IME

hidden textarea (`-9999px`, opacity 0, focus 가능):
- focus 만 받음, 사용자 입력 → input/keydown 이벤트.
- ArrowLeft/Right: charOffset ±1, queryCursorRect 로 새 cursor.
- ArrowUp/Down: hitTest at (x, y ± lineH), 6 단계 progressive 확장으로 셀
  탈출 / 페이지 경계 넘기.
- Backspace: charOffset > 0 → deleteText 1; charOffset == 0 → mergeParagraph
  (이전 문단과 합치기).
- Enter: splitParagraph (현재 charOffset 에서).
- Cmd+Z / C / V: snapshot-based undo / clipboard copy/paste.

IME (한글 등):
- compositionstart/update/end + input(insertCompositionText) 이벤트.
- 조합 중 실제 문서에 insert/delete 반복 → 즉시 시각 피드백.
- macOS Korean 은 compositionupdate 가 안 와서 input event 에서도 dedup
  처리.

## 6. 매칭 (fieldHighlights)

초기 1 회: `buildIrHighlights(doc, pageCount)` 가 spec(`.editables.json`) +
matchingBook + text invariant 매칭으로 ~50 fields 생성. 각 field 는
`{id, label, kind, position, rects, pageIndex, ...}`.

`position` 은 두 가지 shape:
- text_field: `{start: {sec, paragraphIndex, charOffset, ...}, end: {...}}`
- table_cell: 셀 위치 정보 (flat) 또는 위의 inner shape

이후엔 anchor 매칭을 다시 돌리지 않음. 모든 자유 편집을 incremental
reducer 가 따라가 position 을 결정적으로 갱신.

### 6.1 incremental reducer

`assets/js/field_position_reducer.js` — 순수 ES 모듈. `applyEvent(pos, event)` 가
정확한 새 position 또는 `INVALID` sentinel 반환.

처리하는 DocumentEvent:
- TextInserted, TextDeleted
- ParagraphSplit, ParagraphMerged, ParagraphDeleted, ParagraphInserted
- TableRowInserted, TableRowDeleted, TableColumnInserted, TableColumnDeleted
- CellsMerged, CellSplit, TableDeleted

규칙 예 (본문 텍스트):
- TextInserted{sec, para, off, len}: fieldOff ≥ off 면 +len.
- TextDeleted{sec, para, off, count}: fieldOff ≥ off+count 면 -count, 안에
  들어가면 INVALID.
- ParagraphMerged{sec, mergedPara, prevLen}: mergedPara+1 의 fields → para,
  charOffset += prevLen. mergedPara+1 보다 큰 건 -1.

셀-체이닝: 본문 paragraph 가 변하면 표가 들어있는 paragraph (parentParaIndex)
도 shift. 따라서 본문 mutation 이 셀 field 의 parentParaIndex 까지 정확히
반영.

테스트: `test/js/field_position_reducer_test.mjs` 40 케이스. determinism +
hard cases (행 삭제, 셀 병합 후 행 삭제, range field, multi-paragraph reflow).

### 6.2 mutation → event 합성

WASM 자체 `getEventLog` 는 셀 내부 offset 같은 정보가 부족. 우리는 모든
mutation 을 직접 호출하므로 호출 시점에 동봉된 인자로 충분한 event 를
직접 합성:

| mutation method | emitted event |
|---|---|
| insertTextAtCaret | TextInserted{...} |
| deleteCharBeforeCaret | TextDeleted{...} |
| deleteCanvasSelection | TextDeleted{range} |
| replaceCompositionAt | TextDeleted + TextInserted |
| insertNewParagraph | ParagraphSplit{...} |
| mergeWithPrevParagraph | ParagraphMerged{prevLen} |
| runTableOp (행/열 ±, 표 삭제) | TableRow/Column Inserted/Deleted / TableDeleted |

각 mutation 메서드 끝에 `applyFieldEvents([event])` 호출 → reducer 가 모든
field position 을 동기적으로 갱신.

## 7. 네비게이션 (Tab / Shift+Tab / 다음 버튼)

매칭 단위 순회 — position lex key 기반:

```
positionKey(pos) =
  본문:  (sec, paragraphIndex,  -1,         -1,             -1,         charOffset)
  셀:    (sec, parentParaIndex, controlIndex, cellParaIndex, cellIndex,  charOffset)
```

셀 내부에서 `cellParaIndex` 가 `cellIndex` 앞에 와서 row-first reading 보장
(원사업자 상호 → 수급사업자 상호 → 원사업자 전화 → ...).

`activateNextHighlightEditor(direction)`:
1. fieldHighlights → positionKey 매핑 후 lex sort.
2. anchor 결정: activeFieldId 있으면 그 field 키, 없으면
   canvasCaretState 의 키.
3. next = sorted.find(cmp > 0) || sorted[0] (wrap).
4. moveCanvasCaretToField → WASM getCursorRect{ByPath} 로 실제 cursor 위치
   가져와 caret 갱신.

Tab 키: `document.keydown` capture 단계에서 가로채기, 캐럿/포커스가 캔버스
영역일 때만. 컨텍스트 메뉴/chat input 등은 native Tab 유지.

## 8. 렌더 파이프라인 — paragraph 추가/삭제 후 cascade

text 삽입/삭제 처럼 paragraph 개수가 안 변하는 mutation 은 현재 페이지만
다시 그림 (`renderSvgPageAt`).

paragraph 개수가 바뀌는 mutation (split/merge, 표 행/열 추가·삭제, 표 삭제)
은 현재 페이지 이후 모든 페이지 reflow 가능 → `rerenderPagesFrom(currentPage)`
가 `getPageInfo` 로 새 페이지 총 개수 다시 조회하고 currentPage 부터 끝까지
SVG 다시 그림.

## 9. 우클릭 메뉴

rhwp-studio 의 `getDefaultContextMenuItems` / `getTableContextMenuItems`
항목 구조를 vendor (HTML 메뉴, WASM 콜 우리가 매핑).

본문: 잘라내기/복사/붙여넣기, 글자모양, 문단모양, 실행 취소.
셀 안: 위 + 셀 속성, 줄/칸 추가, 셀 합치기/나누기, 표 지우기 등.

dialog 가 필요한 항목 (글자 모양, 셀 속성 등) 은 현재 disabled. vendoring
필요 (후속 작업).

## 10. 정리 — 잘려나간 것들

매칭박스 시각화(overlay/highlight/inline input UI), 표 구조 hover toolbar,
field editor activation 시퀀스, persisted edits replay 일부 — 모두 자유
편집 모델로 흡수되거나 별도 우클릭 메뉴/Tab 으로 대체. 총 ~1500 줄 삭제.

## 11. 미해결 / 후속

- **server-side 영속화** (#105): 자유 편집 결과를 `changes` 테이블에 append,
  로드 시 replay. WASM 은 in-memory 라 reload 하면 사라짐.
- **dialog vendoring** (#108 + 별도): 셀 속성, 글자 모양, 문단 모양 등.
  rhwp-studio 의 dialog 코드를 우리 i18n/스타일에 맞춰 옮김.
- **F5 셀 블록 선택**: 한컴 표준 단축키 — 현재 미구현. cell selection state
  를 JS 측에서 추적.
- **다중 페이지 reflow 시 캐럿 visual 정확도**: cascade rerender 가 완료된
  후 캐럿 % 좌표가 맞는지 시각적 검증 더 필요.
