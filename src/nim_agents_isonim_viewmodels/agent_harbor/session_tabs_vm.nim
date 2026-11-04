## `SessionTabStripVM`: the sessions family's TAB STRIP variant -- every
## Agent Harbor session an operator works with, from whichever front-end
## started it, as session tabs (the pattern of CodeTracer's own session tab
## strip: a label per tab, the active tab raised, a close control, "+" for a
## new tab). One viewmodel serves the strip's four layouts (`TabStripMode`):
##
## - `tsmSingleLine`: one row; tabs that do not fit go to an overflow menu,
##   the active tab is always kept visible (`singleLineLayout`);
## - `tsmMultiLine`: the row wraps onto as many lines as it needs
##   (`packTabRows`);
## - `tsmSidebar`: a vertical list, optionally grouped by initiative, which
##   can collapse to a rail of status marks;
## - `tsmDocked`: the same list as a panel in the layout.
##
## The order is the sessions' launch order (`tabStripSessionPolicy`): a tab
## never moves on its own, only when the operator moves it. The effective
## status separates an ended turn waiting for the next instruction ("idle")
## from a session blocked on a question ("needs input"); both policies are in
## nim-agents (`session_directory.nim`) and a host may pass the other.
##
## Reads through the data-source seam: `loadFleet` for the sessions,
## `loadInitiatives` for the initiatives' titles (an initiatives failure only
## loses the group titles; the strip still shows every session).

import std/[algorithm, strutils, tables]
import isonim/core/[signals, computation]
import isonim/viewmodel
import ./data_source
import ./session_items
import ./tab_layout

export data_source, session_items, tab_layout, viewmodel, signals, computation

type
  TabStripMode* = enum
    tsmSingleLine = "single-line"
    tsmMultiLine = "multi-line"
    tsmSidebar = "sidebar"
    tsmDocked = "docked"

  SessionTabGroup* = object
    ## One initiative's tabs (`planId` "" for sessions launched for none):
    ## in the sidebar and docked layouts, a node of the initiatives tree.
    planId*: string
    title*: string
    counts*: array[SessionAttention, int]
    tabs*: seq[SessionItem]
    state*: InitiativeState     ## the initiative's state at a glance
    progressText*: string       ## `3/19` milestones; "" when unknown
    collapsed*: bool            ## the tree node is folded

  SessionTabStripVM* = ref object of ViewModel
    source: AgentHarborDataSource
    directory: SessionDirectory
    nowMs: int64
    initiativeTitles: Table[string, string]
    initiativeOrder: seq[string]
    initiativeProgress: Table[string, MilestoneFileProgress]
    collapsedPlans: seq[string]
    policy*: SessionPolicy
    revision*: Signal[int]
    state*: Signal[AsyncState]
    error*: Signal[string]
    mode*: Signal[TabStripMode]
    activeId*: Signal[string]
    focusedPlan*: Signal[string]
      ## The initiative whose tabs are highlighted ("" for none).
    grouped*: Signal[bool]
      ## Sidebar and docked layouts group tabs by initiative.
    collapsed*: Signal[bool]
      ## The sidebar shows only status marks.
    overflowOpen*: Signal[bool]
    stripWidthPx*: Signal[int]
      ## The width the single-line strip has, as the renderer measured it,
      ## in the renderer's unit (0: unknown, every tab is drawn).
    tabMinWidth*: int
      ## A tab's narrowest in that unit (`TabMinWidthPx` on the web; a
      ## terminal front-end sets cells).
    tabControlsWidth*: int
      ## The overflow and "+" controls together, in that unit.
    activeTabExtra*: int
      ## How much wider than `tabMinWidth` the active tab is drawn.
    loadToken: int

# ---------------------------------------------------------------------------
# The viewmodel
# ---------------------------------------------------------------------------

proc newSessionTabStripVM*(source: AgentHarborDataSource;
                           mode = tsmSingleLine;
                           policy = tabStripSessionPolicy()): SessionTabStripVM =
  ## Nothing is loaded until `load`.
  withViewModel proc(dispose: proc()): SessionTabStripVM =
    SessionTabStripVM(
      source: source, directory: initSessionDirectory(), policy: policy,
      initiativeTitles: initTable[string, string](),
      revision: createSignal(0), state: createSignal(asIdle),
      error: createSignal(""), mode: createSignal(mode),
      activeId: createSignal(""), focusedPlan: createSignal(""),
      grouped: createSignal(mode in {tsmSidebar, tsmDocked}),
      collapsed: createSignal(false), overflowOpen: createSignal(false),
      stripWidthPx: createSignal(0), tabMinWidth: TabMinWidthPx,
      tabControlsWidth: TabStripButtonsPx, activeTabExtra: ActiveTabExtraPx)

proc sourceLabel*(vm: SessionTabStripVM): string =
  if vm.source.isNil: "" else: vm.source.label

proc bump(vm: SessionTabStripVM) =
  vm.revision.val = vm.revision.val + 1

proc load*(vm: SessionTabStripVM) =
  ## Reads the sessions and the initiatives. The first session becomes active
  ## when none is.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  let target = vm
  vm.source.loadInitiatives proc(answer: DataResult[seq[Initiative]]) =
    if token != target.loadToken or not answer.ok: return
    target.initiativeTitles.clear()
    target.initiativeOrder.setLen 0
    target.initiativeProgress.clear()
    for initiative in answer.value:
      target.initiativeTitles[initiative.id] = initiative.title
      target.initiativeOrder.add initiative.id
      target.initiativeProgress[initiative.id] = initiative.progress
    target.bump()
  vm.source.loadFleet proc(answer: DataResult[FleetSnapshot]) =
    if token != target.loadToken: return
    if answer.ok:
      target.nowMs = answer.value.capturedAtMs
      target.directory.replaceAll(answer.value.sessions)
      if target.directory.find(target.activeId.val) < 0:
        target.activeId.val =
          if target.directory.len > 0: target.directory.sessions[0].id else: ""
      target.bump()
      target.state.val = asReady
    else:
      target.error.val = answer.error
      target.state.val = asError

proc applyFrame*(vm: SessionTabStripVM; frame: LifecycleFrame) =
  ## A lifecycle frame from the live feed: a session appears as a new tab at
  ## the end, changes status in place, or its tab goes away.
  if vm.directory.applyFrame(frame):
    if vm.directory.find(vm.activeId.val) < 0:
      vm.activeId.val =
        if vm.directory.len > 0: vm.directory.sessions[0].id else: ""
    vm.bump()

proc tabs*(vm: SessionTabStripVM): seq[SessionItem] =
  ## Tracked: every tab, in strip order, the active one marked.
  discard vm.revision.val
  let active = vm.activeId.val
  for i in orderedIndexes(vm.directory.sessions, vm.policy):
    var item = sessionItemOf(vm.directory.sessions[i], vm.nowMs, vm.policy,
                             vm.directory.sessions[i].id == active)
    if item.initiativeTitle.len == 0 and item.planId in vm.initiativeTitles:
      item.initiativeTitle = vm.initiativeTitles[item.planId]
    result.add item

proc activeIndex*(vm: SessionTabStripVM): int =
  for i, tab in vm.tabs:
    if tab.active: return i
  -1

proc groups*(vm: SessionTabStripVM): seq[SessionTabGroup] =
  ## Tracked: the tabs by initiative, in the initiatives' order, then those
  ## of no initiative. Ungrouped, one group holds every tab.
  let tabs = vm.tabs
  if not vm.grouped.val:
    var all = SessionTabGroup()
    for tab in tabs:
      inc all.counts[tab.attention]
      all.tabs.add tab
    return @[all]
  var order: seq[int]
  for i in 0 ..< tabs.len: order.add i
  var sessions: seq[FleetSession]
  for tab in tabs: sessions.add FleetSession(id: tab.id, planId: tab.planId)
  for group in groupByPlan(sessions, order, vm.initiativeOrder):
    var g = SessionTabGroup(planId: group.planId,
                            title: vm.initiativeTitles.getOrDefault(group.planId, ""))
    if g.planId.len == 0: g.title = "No initiative"
    for i in group.indexes:
      if g.title.len == 0: g.title = tabs[i].initiativeTitle
      inc g.counts[tabs[i].attention]
      g.tabs.add tabs[i]
    if g.title.len == 0: g.title = g.planId
    var attentions: seq[SessionAttention]
    for tab in g.tabs: attentions.add tab.attention
    var blocked = 0
    if g.planId in vm.initiativeProgress:
      let p = vm.initiativeProgress[g.planId]
      blocked = statusCounts(p)[mscBlocked]
      g.progressText = $p.summary.completedMilestones & "/" & $p.summary.totalMilestones
    var done = false
    if g.planId in vm.initiativeProgress:
      let s = vm.initiativeProgress[g.planId].summary
      done = planDone(s.completedMilestones, s.totalMilestones)
    g.state = initiativeStateOf(attentions, blocked, done)
    g.collapsed = g.planId in vm.collapsedPlans
    result.add g
  if vm.policy.order == soAttention:
    # A list read top to bottom: the initiative whose sessions need the
    # reader most comes first (the most urgent session decides; the
    # initiatives' own order breaks ties), and the sessions of no
    # initiative stay last.
    proc urgency(g: SessionTabGroup): int =
      result = high(int)
      for a in SessionAttention:
        if g.counts[a] > 0: return ord(a)
    var keyed: seq[(int, int, int)]
    for i, g in result:
      keyed.add ((if g.planId.len == 0: 1 else: 0), g.urgency, i)
    keyed.sort()
    var ordered: seq[SessionTabGroup]
    for k in keyed: ordered.add result[k[2]]
    result = ordered

proc toggleGroup*(vm: SessionTabStripVM; planId: string) =
  ## Folds or unfolds an initiative's node of the tree.
  let at = vm.collapsedPlans.find(planId)
  if at >= 0: vm.collapsedPlans.delete(at) else: vm.collapsedPlans.add planId
  vm.bump()

proc singleLine*(vm: SessionTabStripVM): SingleLineLayout =
  ## Tracked: which tabs the single-line strip draws and which overflow.
  singleLineLayout(vm.tabs.len, vm.activeIndex,
                   singleLineCapacity(vm.stripWidthPx.val, vm.tabMinWidth,
                                      TabGapPx, vm.tabControlsWidth + vm.activeTabExtra))

proc counts*(vm: SessionTabStripVM): array[SessionAttention, int] =
  for tab in vm.tabs: inc result[tab.attention]

proc activate*(vm: SessionTabStripVM; id: string): bool =
  ## Makes the tab active; false for an unknown or already active tab.
  if vm.directory.find(id) < 0 or vm.activeId.val == id: return false
  vm.activeId.val = id
  vm.overflowOpen.val = false
  true

proc step*(vm: SessionTabStripVM; delta: int): bool =
  ## The next (`delta > 0`) or previous tab, wrapping; one tab does nothing.
  let tabs = vm.tabs
  if tabs.len < 2: return false
  let at = max(0, vm.activeIndex)
  vm.activate(tabs[(at + delta mod tabs.len + tabs.len) mod tabs.len].id)

proc close*(vm: SessionTabStripVM; id: string): bool =
  ## Closes a tab (the session goes on; closing only stops showing it). The
  ## next tab, else the previous, becomes active when the active one closes.
  let at = vm.directory.find(id)
  if at < 0: return false
  let tabs = vm.tabs
  var position = -1
  for i, tab in tabs:
    if tab.id == id: position = i
  if vm.activeId.val == id:
    vm.activeId.val =
      if tabs.len == 1: ""
      elif position + 1 < tabs.len: tabs[position + 1].id
      else: tabs[position - 1].id
  discard vm.directory.applyFrame(LifecycleFrame(event: "lifecycle",
    kind: "session_removed", sessionId: id))
  vm.bump()
  true

proc move*(vm: SessionTabStripVM; id: string; toIndex: int): bool =
  ## Moves a tab to `toIndex` in the strip (the launch order is kept
  ## otherwise).
  if not vm.directory.moveSession(id, toIndex): return false
  vm.bump()
  true

proc focusInitiative*(vm: SessionTabStripVM; planId: string) =
  ## Highlights an initiative's tabs and activates its first one (selecting
  ## an initiative in the Initiatives panel); "" clears the focus.
  vm.focusedPlan.val = planId
  if planId.len == 0: return
  for tab in vm.tabs:
    if tab.planId == planId:
      discard vm.activate(tab.id)
      break

proc setMode*(vm: SessionTabStripVM; mode: TabStripMode) =
  vm.mode.val = mode
  vm.overflowOpen.val = false

proc toggleOverflow*(vm: SessionTabStripVM) =
  vm.overflowOpen.val = not vm.overflowOpen.val

proc isInFocus*(vm: SessionTabStripVM; tab: SessionItem): bool =
  let plan = vm.focusedPlan.val
  plan.len > 0 and tab.planId == plan

proc originsShown*(vm: SessionTabStripVM): seq[string] =
  ## The distinct front-ends of origin among the tabs, in first-seen order.
  for tab in vm.tabs:
    if tab.originLabel.len > 0 and tab.originLabel notin result:
      result.add tab.originLabel

proc summaryText*(vm: SessionTabStripVM): string =
  ## `22 sessions · 3 need input · 2 idle · 6 running`.
  let counts = vm.counts
  var total = 0
  for c in counts: total += c
  var parts = @[$total & (if total == 1: " session" else: " sessions")]
  if counts[saNeedsInput] > 0:
    parts.add $counts[saNeedsInput] & (if counts[saNeedsInput] == 1: " needs input" else: " need input")
  if counts[saIdle] > 0: parts.add $counts[saIdle] & " idle"
  if counts[saRunning] > 0: parts.add $counts[saRunning] & " running"
  if counts[saFailed] > 0: parts.add $counts[saFailed] & " failed"
  parts.join(" \xC2\xB7 ")
