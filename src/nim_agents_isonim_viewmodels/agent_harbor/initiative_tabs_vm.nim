## `InitiativeTabStripVM`: the sessions family's INITIATIVE TAB BAR variant
## -- the tab bar of a front-end that groups agent work by initiative
## (CodeTracer's "CodeTracer as an Agent Harbor front-end": one tab per
## active initiative, alongside ordinary session tabs).
##
## What it publishes:
##
## - the tabs (`tabs`): first one tab per initiative -- its name, its state at
##   a glance (`InitiativeState`: needs input, working, blocked, idle, ended)
##   and `n/m` milestones -- then a tab per open session launched for no
##   initiative; a session of an initiative is selected inside its
##   initiative's tab (`selectedSessionOf`);
## - the recordings loaded for the active initiative, as the recording
##   switcher's numbered buttons (`recordingButtonsOf`; the host says which
##   recordings it has loaded, `setRecordings`);
## - the progress popup of the initiative under the pointer (`popupOf`);
## - `N agent harbor sessions` (`elsewhereCount` and `elsewhereLabel`, which a
##   view draws as a count badge and its label): the sessions started on another front-end
##   that no tab shows yet (`elsewhere`), each with its initiative and state,
##   brought into view by `openSession` -- as a tab of its own, or selected
##   inside its initiative's tab;
## - Previous / Next over the sessions waiting for the operator
##   (`stepInbox`), and auto-switch: when the active session stops waiting
##   because its instruction arrived, Next is taken on its own.
##
## Like the session tab strip (`session_tabs_vm.nim`), it reads through the
## data-source seam (`loadFleet`, `loadInitiatives`) and folds lifecycle
## frames (`applyFrame`), so a live or playback source drives it event by
## event. Front-end neutral: no width, no pixels.

import std/[strutils, tables]
import isonim/core/[signals, computation]
import isonim/viewmodel
import ./data_source
import ./session_items
import ./recording_switcher
import ./tab_layout

export data_source, session_items, recording_switcher, tab_layout, viewmodel,
  signals, computation

type
  StripTabKind* = enum
    stkInitiative = "initiative"
    stkSession = "session"

  StripTab* = object
    kind*: StripTabKind
    id*: string                 ## the initiative's or the session's id
    title*: string
    progressText*: string       ## `3/19` (initiatives)
    state*: InitiativeState     ## initiatives
    session*: SessionItem       ## session tabs: the session
    tooltip*: string
    active*: bool

  ElsewhereSession* = object
    item*: SessionItem
    initiativeTitle*: string

  InitiativePopup* = object
    ## The hover popup: what Agent Harbor's initiative progress popup shows.
    id*: string
    title*: string
    state*: InitiativeState
    headline*: string           ## `3 of 19 milestones · 16%`
    statusCounts*: array[MilestoneStatusClass, int]
    currentMilestone*: string
    executiveSummary*: string
    sessions*: seq[SessionItem]

  InitiativeTabStripVM* = ref object of ViewModel
    source: AgentHarborDataSource
    directory: SessionDirectory
    initiatives: seq[Initiative]
    nowMs: int64
    openIds: seq[string]
    selectedSession: Table[string, string]   ## initiative -> session
    recordings: Table[string, seq[RecordingEntry]]
    activeRecording: Table[string, string]
    policy*: SessionPolicy
    revision*: Signal[int]
    state*: Signal[AsyncState]
    error*: Signal[string]
    activeTab*: Signal[string]
      ## `initiative:<id>` or `session:<id>`; "" for none.
    popupId*: Signal[string]
      ## The initiative whose progress popup shows ("" for none).
    elsewhereOpen*: Signal[bool]
    autoSwitch*: Signal[bool]
    overflowOpen*: Signal[bool]
    stripWidth*: Signal[int]
      ## The width the tab bar has, in the renderer's unit (0: unknown, every
      ## tab is drawn).
    tabMinWidth*: int
      ## A tab's narrowest in that unit.
    controlsWidth*: int
      ## Previous/Next, `[N agent harbor sessions]`, the overflow chip and
      ## "+" together, in that unit.
    loadToken: int

const
  InitiativeTabMinWidthPx* = 192
    ## An initiative tab's narrowest on the web: 12rem (a mark, a name and
    ## `n/m`; the active one also holds its recording buttons).
  InitiativeBarControlsPx* = 425 + 32 + 46
    ## Everything on the tabs' line that is not a tab, on the web: the
    ## right-hand group (the sessions started elsewhere as a count badge and
    ## its label, Previous/Next with the position, `Auto-switch: off`; 425px
    ## measured at 1440px), "+" after the last tab (32) and the overflow chip
    ## (46), with their gaps.
  InitiativeBarCompactControlsPx* = 161 + 32 + 46
    ## The same, compact: the badge alone, the two steps and `Auto: off`
    ## (161px measured at 760px), "+" and the chip.
  InitiativeBarCompactBelowPx* = 960
    ## Narrower than this, the bar is compact.
  InitiativeBarStackedBelowPx* = 480
    ## Narrower than this, the controls take a second line under the tabs:
    ## beside even one tab they would push "+" out of the bar.
  InitiativeBarChipPx* = 46 + 32
    ## The overflow chip and "+" with their gaps, which stay on the tabs'
    ## line of a stacked bar.
  ActiveInitiativeExtraPx* = 110
    ## The room the active tab takes beyond the narrowest: its recording
    ## buttons (on a compact bar one and `+N`: ActiveInitiativeExtraCompactPx).
  ActiveInitiativeExtraCompactPx* = 50
  RecordingSlots* = 5
    ## Recording buttons the active tab draws before `+N`: with its mark,
    ## name and `n/m`, five keep the tab inside its widest (20rem on the web).
  RecordingSlotsCompact* = 1
    ## A compact bar draws only the active recording and `+N`.
  OwnFrontEnd* = "codetracer"
    ## Sessions this front-end started open as tabs on their own; the others
    ## wait behind `[N agent harbor sessions]`.

proc initiativeKey*(id: string): string = "initiative:" & id
proc sessionKey*(id: string): string = "session:" & id

proc newInitiativeTabStripVM*(source: AgentHarborDataSource;
                              policy = tabStripSessionPolicy()): InitiativeTabStripVM =
  withViewModel proc(dispose: proc()): InitiativeTabStripVM =
    InitiativeTabStripVM(
      source: source, directory: initSessionDirectory(), policy: policy,
      selectedSession: initTable[string, string](),
      recordings: initTable[string, seq[RecordingEntry]](),
      activeRecording: initTable[string, string](),
      revision: createSignal(0), state: createSignal(asIdle),
      error: createSignal(""), activeTab: createSignal(""),
      popupId: createSignal(""), elsewhereOpen: createSignal(false),
      autoSwitch: createSignal(false), overflowOpen: createSignal(false),
      stripWidth: createSignal(0), tabMinWidth: InitiativeTabMinWidthPx,
      controlsWidth: InitiativeBarControlsPx)

proc sourceLabel*(vm: InitiativeTabStripVM): string =
  if vm.source.isNil: "" else: vm.source.label

proc bump(vm: InitiativeTabStripVM) = vm.revision.val = vm.revision.val + 1

proc initiativeIndex(vm: InitiativeTabStripVM; id: string): int =
  for i, initiative in vm.initiatives:
    if initiative.id == id: return i
  -1

proc inInitiativeTab(vm: InitiativeTabStripVM; s: FleetSession): bool =
  ## A session launched for an initiative this bar has a tab for is shown
  ## inside that tab; any other session gets a tab of its own.
  s.planId.len > 0 and vm.initiativeIndex(s.planId) >= 0

proc firstTabKey(vm: InitiativeTabStripVM): string =
  if vm.initiatives.len > 0: return initiativeKey(vm.initiatives[0].id)
  for s in vm.directory.sessions:
    if not vm.inInitiativeTab(s) and s.id in vm.openIds: return sessionKey(s.id)
  ""

proc load*(vm: InitiativeTabStripVM) =
  ## Reads the sessions and the initiatives; the sessions this front-end
  ## started are open, and the first tab is active when none is.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  let target = vm
  var pending = 2
  var failed = ""
  proc settle() =
    dec pending
    if pending > 0: return
    if failed.len > 0:
      target.error.val = failed
      target.state.val = asError
    else:
      if target.activeTab.val.len == 0: target.activeTab.val = target.firstTabKey
      target.state.val = asReady
    target.bump()
  vm.source.loadInitiatives proc(answer: DataResult[seq[Initiative]]) =
    if token != target.loadToken: return
    if answer.ok: target.initiatives = answer.value
    else: failed = answer.error
    settle()
  vm.source.loadFleet proc(answer: DataResult[FleetSnapshot]) =
    if token != target.loadToken: return
    if answer.ok:
      target.nowMs = answer.value.capturedAtMs
      target.directory.replaceAll(answer.value.sessions)
      for s in target.directory.sessions:
        if s.originFrontEnd == OwnFrontEnd and s.id notin target.openIds:
          target.openIds.add s.id
    else:
      failed = answer.error
    settle()

proc itemOf(vm: InitiativeTabStripVM; session: FleetSession): SessionItem =
  result = sessionItemOf(session, vm.nowMs, vm.policy)
  if result.initiativeTitle.len == 0 and session.planId.len > 0:
    let at = vm.initiativeIndex(session.planId)
    if at >= 0: result.initiativeTitle = vm.initiatives[at].title

proc sessionsOf*(vm: InitiativeTabStripVM; initiativeId: string): seq[SessionItem] =
  ## Tracked: an initiative's sessions in launch order.
  discard vm.revision.val
  for s in vm.directory.sessions:
    if s.planId == initiativeId: result.add vm.itemOf(s)

proc stateOf*(vm: InitiativeTabStripVM; initiative: Initiative): InitiativeState =
  var attentions: seq[SessionAttention]
  for s in vm.directory.sessions:
    if s.planId == initiative.id: attentions.add s.attentionOf(vm.policy.status)
  let s = initiative.progress.summary
  initiativeStateOf(attentions, statusCounts(initiative.progress)[mscBlocked],
                    planDone(s.completedMilestones, s.totalMilestones))

proc stateWord*(state: InitiativeState): string =
  case state
  of isNeedsInput: "needs input"
  of isBlocked: "blocked"
  of isWorking: "working"
  of isIdle: "idle"
  of isEnded: "ended"

proc tabs*(vm: InitiativeTabStripVM): seq[StripTab] =
  ## Tracked: initiative tabs in the server's order, then the open sessions
  ## launched for no initiative, in launch order.
  discard vm.revision.val
  let active = vm.activeTab.val
  for initiative in vm.initiatives:
    let p = initiative.progress.summary
    let state = vm.stateOf(initiative)
    let progress = $p.completedMilestones & "/" & $p.totalMilestones
    result.add StripTab(kind: stkInitiative, id: initiative.id,
      title: initiative.title, progressText: progress, state: state,
      tooltip: initiative.title & "\n" & stateWord(state) & " \xC2\xB7 " &
        progress & " milestones",
      active: active == initiativeKey(initiative.id))
  for s in vm.directory.sessions:
    if not vm.inInitiativeTab(s) and s.id in vm.openIds:
      let item = vm.itemOf(s)
      result.add StripTab(kind: stkSession, id: s.id, title: item.title,
                          session: item, tooltip: item.tooltip,
                          active: active == sessionKey(s.id))

proc compact*(vm: InitiativeTabStripVM): bool =
  ## A narrow bar: Previous/Next without the position, auto-switch as
  ## `Auto: on|off`, and `[N]` for the sessions started elsewhere.
  let w = vm.stripWidth.val
  w > 0 and w < InitiativeBarCompactBelowPx

proc stacked*(vm: InitiativeTabStripVM): bool =
  ## A bar too narrow for the controls beside a tab: they take a line of
  ## their own under the tabs (the bar grows), so "+" stays in view.
  let w = vm.stripWidth.val
  w > 0 and w < InitiativeBarStackedBelowPx

proc singleLine*(vm: InitiativeTabStripVM): SingleLineLayout =
  ## Tracked: which tabs the bar draws and which go to its overflow menu;
  ## the active tab is always drawn.
  let tabs = vm.tabs
  var active = 0
  for i, tab in tabs:
    if tab.active: active = i
  # The controls share the tabs' line unless the bar is stacked (then only
  # the overflow chip does); the active tab is wider by its recording
  # buttons.
  let controls =
    if vm.stacked: InitiativeBarChipPx
    elif vm.compact: InitiativeBarCompactControlsPx
    else: vm.controlsWidth
  let extra = if vm.compact: ActiveInitiativeExtraCompactPx else: ActiveInitiativeExtraPx
  let capacity = singleLineCapacity(vm.stripWidth.val, vm.tabMinWidth, TabGapPx,
                                    controls + extra)
  singleLineLayout(tabs.len, active, capacity)

proc elsewhere*(vm: InitiativeTabStripVM): seq[ElsewhereSession] =
  ## Tracked: the sessions started on another front-end that no tab shows
  ## yet, newest first, each with its initiative's title ("" for none). A
  ## session of an initiative is among them until it is brought into view
  ## (inside its initiative's tab); its initiative's popup lists it anyway.
  discard vm.revision.val
  for i in countdown(vm.directory.sessions.high, 0):
    let s = vm.directory.sessions[i]
    if s.id notin vm.openIds:
      let item = vm.itemOf(s)
      result.add ElsewhereSession(item: item, initiativeTitle: item.initiativeTitle)

proc elsewhereCount*(vm: InitiativeTabStripVM): int =
  ## Tracked: how many sessions wait to be brought into view (the badge).
  vm.elsewhere.len

proc elsewhereLabel*(vm: InitiativeTabStripVM): string =
  ## `agent harbor sessions` (`session` for one): the words beside the
  ## count; "" when there are none (the item is hidden).
  let n = vm.elsewhereCount
  if n == 0: "" elif n == 1: "agent harbor session" else: "agent harbor sessions"

proc elsewhereTooltip*(vm: InitiativeTabStripVM): string =
  ## `5 agent harbor sessions started elsewhere: choose one to open it`.
  let n = vm.elsewhereCount
  if n == 0: "" else: $n & " " & vm.elsewhereLabel &
    " started elsewhere: choose one to open it"

proc activate*(vm: InitiativeTabStripVM; key: string): bool =
  if vm.activeTab.val == key: return false
  vm.activeTab.val = key
  vm.elsewhereOpen.val = false
  vm.overflowOpen.val = false
  true

proc showSession*(vm: InitiativeTabStripVM; sessionId: string): bool =
  ## Brings a session into view: its initiative's tab with it selected, or
  ## its own tab (opened if it was not).
  let at = vm.directory.find(sessionId)
  if at < 0: return false
  let s = vm.directory.sessions[at]
  if sessionId notin vm.openIds: vm.openIds.add sessionId
  if vm.inInitiativeTab(s):
    vm.selectedSession[s.planId] = sessionId
    discard vm.activate(initiativeKey(s.planId))
  else:
    discard vm.activate(sessionKey(sessionId))
  vm.bump()
  true

proc openSession*(vm: InitiativeTabStripVM; sessionId: string): bool =
  ## Chosen from the sessions started elsewhere: brought into view, as a
  ## tab of its own or inside its initiative's tab.
  vm.showSession(sessionId)

proc selectedSessionOf*(vm: InitiativeTabStripVM; initiativeId: string): string =
  discard vm.revision.val
  vm.selectedSession.getOrDefault(initiativeId, "")

proc activeSessionId*(vm: InitiativeTabStripVM): string =
  ## The session in view: a session tab's, or the session selected inside
  ## the active initiative tab.
  let key = vm.activeTab.val
  if key.startsWith("session:"): key["session:".len .. ^1]
  elif key.startsWith("initiative:"):
    vm.selectedSession.getOrDefault(key["initiative:".len .. ^1], "")
  else: ""

proc inboxCount*(vm: InitiativeTabStripVM): int =
  discard vm.revision.val
  inboxOrder(vm.directory.sessions, vm.policy.status).len

proc inboxPosition*(vm: InitiativeTabStripVM): string =
  ## `2 of 5` while the session in view is waiting; `5 waiting` otherwise;
  ## "" for an empty inbox.
  discard vm.revision.val
  let order = inboxOrder(vm.directory.sessions, vm.policy.status)
  if order.len == 0: return ""
  let current = vm.directory.find(vm.activeSessionId)
  for i, item in order:
    if item == current: return $(i + 1) & " of " & $order.len
  $order.len & " waiting"

proc stepInbox*(vm: InitiativeTabStripVM; delta: int): bool =
  ## Previous (`-1`) / Next (`+1`): the waiting session before or after the
  ## one in view, shown as `showSession` shows it.
  let order = inboxOrder(vm.directory.sessions, vm.policy.status)
  let next = inboxStep(order, vm.directory.find(vm.activeSessionId), delta)
  if next < 0: return false
  vm.showSession(vm.directory.sessions[next].id)

proc waitingInView(vm: InitiativeTabStripVM): bool =
  let inView = vm.directory.find(vm.activeSessionId)
  inView >= 0 and
    vm.directory.sessions[inView].attentionOf(vm.policy.status) in {saNeedsInput, saIdle}

proc afterChange(vm: InitiativeTabStripVM; wasWaiting: bool) =
  ## With auto-switch on, the session in view that stopped waiting (its
  ## instruction arrived) hands the view to the next waiting one.
  vm.bump()
  if vm.autoSwitch.val and wasWaiting and not vm.waitingInView:
    discard vm.stepInbox(1)

proc applyFrame*(vm: InitiativeTabStripVM; frame: LifecycleFrame) =
  ## A lifecycle frame from the live feed.
  let wasWaiting = vm.waitingInView
  if vm.directory.applyFrame(frame): vm.afterChange(wasWaiting)

proc markResumed*(vm: InitiativeTabStripVM; sessionId: string) =
  ## The operator's instruction reached a waiting session (a live source
  ## learns this from the session's events): it no longer waits.
  let wasWaiting = vm.waitingInView
  if vm.directory.resumeSession(sessionId): vm.afterChange(wasWaiting)

proc setRecordings*(vm: InitiativeTabStripVM; initiativeId: string;
                    entries: seq[RecordingEntry]; activeId = "") =
  ## The recordings the host has loaded for an initiative (CodeTracer's own
  ## state: its replays, not Agent Harbor's).
  vm.recordings[initiativeId] = entries
  vm.activeRecording[initiativeId] =
    if activeId.len > 0: activeId elif entries.len > 0: entries[0].id else: ""
  vm.bump()

proc selectRecording*(vm: InitiativeTabStripVM; initiativeId, recordingId: string): bool =
  for e in vm.recordings.getOrDefault(initiativeId, @[]):
    if e.id == recordingId:
      if vm.activeRecording.getOrDefault(initiativeId, "") == recordingId: return false
      vm.activeRecording[initiativeId] = recordingId
      vm.bump()
      return true
  false

proc recordingSlots*(vm: InitiativeTabStripVM): int =
  ## Tracked: how many recording buttons the active tab has room for; the
  ## rest are counted behind `+N`.
  if vm.compact: RecordingSlotsCompact else: RecordingSlots

proc recordingButtonsOf*(vm: InitiativeTabStripVM; initiativeId: string;
                         maxShown = -1): RecordingButtons =
  ## The active tab's recording buttons; `maxShown` defaults to
  ## `recordingSlots`, the room the bar's width leaves.
  discard vm.revision.val
  let slots = if maxShown < 0: vm.recordingSlots else: maxShown
  recordingButtons(vm.recordings.getOrDefault(initiativeId, @[]),
                   vm.activeRecording.getOrDefault(initiativeId, ""), slots)

proc popupOf*(vm: InitiativeTabStripVM; initiativeId: string): InitiativePopup =
  ## Tracked: the progress popup's content; an empty one for an unknown id.
  discard vm.revision.val
  let at = vm.initiativeIndex(initiativeId)
  if at < 0: return
  let initiative = vm.initiatives[at]
  let s = initiative.progress.summary
  result = InitiativePopup(
    id: initiative.id, title: initiative.title, state: vm.stateOf(initiative),
    headline: $s.completedMilestones & " of " & $s.totalMilestones &
      (if s.totalMilestones == 1: " milestone" else: " milestones") &
      " \xC2\xB7 " & $s.progressPercent & "%",
    statusCounts: statusCounts(initiative.progress),
    currentMilestone:
      if initiative.progress.currentMilestone.len == 0: ""
      elif s.currentMilestoneTitle.len > 0:
        initiative.progress.currentMilestone & ": " & s.currentMilestoneTitle
      else: initiative.progress.currentMilestone,
    executiveSummary: initiative.executiveSummary)
  result.sessions = vm.sessionsOf(initiativeId)
