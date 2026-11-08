## Tab-strip layout rules, pure and signal-free, for every tab bar variant
## (`session_tabs_vm.nim`, `initiative_tabs_vm.nim`) and every renderer: the
## multi-line strip's rows (`packTabRows`) and the single-line strip's
## visible tabs and overflow (`singleLineLayout`, CodeTracer's rule: the
## active tab is always drawn). Widths are in the renderer's unit -- pixels
## on the web and in GPUI, cells in a terminal.

type
  SingleLineLayout* = object
    visible*: seq[int]   ## tab indexes drawn in the row, in order
    overflow*: seq[int]  ## tab indexes in the overflow menu, in order

const
  TabMinWidthPx* = 160
    ## An Agent Harbor tab's narrowest: 10rem (`agent_harbor.styl`). Its
    ## mark, origin and close take room CodeTracer's plain 6em tab does not
    ## have; below 10rem the title would shrink to a few letters, so more
    ## tabs go to the overflow menu instead.
  TabGapPx* = 4
    ## The space between two tabs, in web pixels.
  TabStripButtonsPx* = 56 + 12 + 26 + 2 * 4
    ## The `+N` chip at its widest (a warning mark and two digits, 56px),
    ## its 12px gap from the "+", the "+" (26px), and their margins.
  ActiveTabExtraPx* = 64
    ## The room the active tab takes beyond the narrowest (14rem against
    ## 10rem on the web), so the tab the reader works in keeps a readable
    ## title beside its mark, origin and close.

# ---------------------------------------------------------------------------
# Layout rules (pure, signal-free; every renderer uses them)
# ---------------------------------------------------------------------------

proc packTabRows*(widths: openArray[int]; budget: int; gap = 0): seq[seq[int]] =
  ## The multi-line strip: tabs in order, a new row whenever the next tab
  ## would pass `budget`; a tab wider than the budget gets a row of its own.
  ## Every tab is on exactly one row.
  var row: seq[int]
  var used = 0
  for i, w in widths:
    let need = (if row.len > 0: gap else: 0) + w
    if row.len > 0 and used + need > budget:
      result.add row
      row = @[]
      used = 0
    used += (if row.len > 0: gap else: 0) + w
    row.add i
  if row.len > 0: result.add row

proc singleLineCapacity*(width: int; tabMin = TabMinWidthPx; gap = TabGapPx;
                         controls = TabStripButtonsPx): int =
  ## How many tabs fit on one line of `width`, at their narrowest
  ## (`tabMin`), beside the overflow and "+" controls. The defaults are the
  ## web strip's pixels; a terminal front-end passes its cell counts. 0 width
  ## means unmeasured: no limit.
  if width <= 0: return high(int)
  max(1, (width - controls + gap) div (tabMin + gap))

proc singleLineLayout*(tabCount, activeIndex, capacity: int): SingleLineLayout =
  ## CodeTracer's rule for its session strip (`visibleTabIndexes`): the first
  ## tabs that fit, except that an active tab beyond them takes the last
  ## visible place, so the active tab is always in the row.
  if tabCount <= 0: return
  let fit = max(0, min(tabCount, capacity))
  let active = if activeIndex in 0 ..< tabCount: activeIndex else: 0
  if fit == 0: return
  if active < fit:
    for i in 0 ..< fit: result.visible.add i
  else:
    for i in 0 ..< fit - 1: result.visible.add i
    result.visible.add active
  for i in 0 ..< tabCount:
    if i notin result.visible: result.overflow.add i

