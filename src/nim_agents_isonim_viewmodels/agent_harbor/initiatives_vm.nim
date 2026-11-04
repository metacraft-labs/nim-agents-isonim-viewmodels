## `InitiativesVM`: the running initiatives (plans) a server knows and the
## sessions behind each -- the data of an Initiatives panel, a TREE pattern
## (one row per initiative, its sessions under it as a node that folds and
## shows its first few sessions until it is expanded). Selecting an initiative
## names it to the host (`selectedId`), which focuses its session tabs
## (`SessionTabStripVM.focusInitiative`) and shows its progress
## (`InitiativeProgressVM`).
##
## Reads through the data-source seam: `loadInitiatives` (the proposed
## `GET /api/v1/initiatives`) and `loadFleet`, whose sessions give each
## initiative's sessions their states. An initiative whose sessions the
## listing does not hold still shows, with the count it names.

import std/[strutils, tables]
import isonim/core/[signals, computation]
import isonim/viewmodel
import ./data_source
import ./session_items

export data_source, session_items, viewmodel, signals, computation

type
  InitiativeRow* = object
    id*: string
    title*: string
    repository*: string
    manager*: string
    currentMilestone*: string     ## `CTF-P2: Prototypes: …`, "" when none
    progressText*: string         ## `3/19 · 16%`
    progressLong*: string         ## `3 of 19 milestones · 16%`, for a tooltip
    state*: InitiativeState       ## its state at a glance, from its sessions
    progressPercent*: int
    statusCounts*: array[MilestoneStatusClass, int]
    sessions*: seq[SessionItem]   ## in launch order
    sessionCounts*: array[SessionAttention, int]
    missingSessions*: int         ## named by the initiative, absent from the listing
    selected*: bool
    folded*: bool                 ## the node hides its sessions
    expanded*: bool               ## the node shows all its sessions, not the first few

  InitiativesVM* = ref object of ViewModel
    source: AgentHarborDataSource
    initiatives: seq[Initiative]
    sessions: Table[string, FleetSession]
    nowMs: int64
    unattached: int
      ## Sessions of the listing launched for no initiative.
    policy*: SessionPolicy
    revision*: Signal[int]
    state*: Signal[AsyncState]
    error*: Signal[string]
    selectedId*: Signal[string]
    folded: seq[string]
    expanded: seq[string]
    loadToken: int

proc newInitiativesVM*(source: AgentHarborDataSource;
                       policy = tabStripSessionPolicy()): InitiativesVM =
  withViewModel proc(dispose: proc()): InitiativesVM =
    InitiativesVM(source: source, policy: policy,
                  sessions: initTable[string, FleetSession](),
                  revision: createSignal(0), state: createSignal(asIdle),
                  error: createSignal(""), selectedId: createSignal(""))

proc sourceLabel*(vm: InitiativesVM): string =
  if vm.source.isNil: "" else: vm.source.label

proc load*(vm: InitiativesVM) =
  ## Ready once the initiatives answer; the sessions fill in when the listing
  ## answers (a listing failure leaves the sessions as counts only).
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  let target = vm
  vm.source.loadFleet proc(answer: DataResult[FleetSnapshot]) =
    if token != target.loadToken or not answer.ok: return
    target.sessions.clear()
    target.unattached = 0
    target.nowMs = answer.value.capturedAtMs
    for session in answer.value.sessions:
      target.sessions[session.id] = session
      if session.planId.len == 0: inc target.unattached
    target.revision.val = target.revision.val + 1
  vm.source.loadInitiatives proc(answer: DataResult[seq[Initiative]]) =
    if token != target.loadToken: return
    if answer.ok:
      target.initiatives = answer.value
      target.revision.val = target.revision.val + 1
      target.state.val = asReady
    else:
      target.error.val = answer.error
      target.state.val = asError

proc progressText*(progress: MilestoneFileProgress): string =
  let s = progress.summary
  $s.completedMilestones & " of " & $s.totalMilestones &
    (if s.totalMilestones == 1: " milestone" else: " milestones") &
    " \xC2\xB7 " & $s.progressPercent & "%"

proc currentMilestoneText*(progress: MilestoneFileProgress): string =
  if progress.currentMilestone.len == 0: ""
  elif progress.summary.currentMilestoneTitle.len > 0:
    progress.currentMilestone & ": " & progress.summary.currentMilestoneTitle
  else: progress.currentMilestone

proc rowOf(vm: InitiativesVM; initiative: Initiative; selected: string): InitiativeRow =
  result = InitiativeRow(
    id: initiative.id, title: initiative.title,
    repository: initiative.repository, manager: initiative.manager,
    currentMilestone: currentMilestoneText(initiative.progress),
    progressText: $initiative.progress.summary.completedMilestones & "/" &
      $initiative.progress.summary.totalMilestones & " \xC2\xB7 " &
      $initiative.progress.summary.progressPercent & "%",
    progressLong: progressText(initiative.progress),
    progressPercent: initiative.progress.summary.progressPercent,
    statusCounts: statusCounts(initiative.progress),
    selected: initiative.id == selected,
    folded: initiative.id in vm.folded,
    expanded: initiative.id in vm.expanded)
  for id in initiative.sessionIds:
    if id in vm.sessions:
      var item = sessionItemOf(vm.sessions[id], vm.nowMs, vm.policy)
      if item.initiativeTitle.len == 0: item.initiativeTitle = initiative.title
      inc result.sessionCounts[item.attention]
      result.sessions.add item
    else:
      inc result.missingSessions
  # The sessions that need the reader first (needs input, idle, running,
  # queued, failed, ended), launch order within each.
  var ordered: seq[SessionItem]
  for a in SessionAttention:
    for item in result.sessions:
      if item.attention == a: ordered.add item
  result.sessions = ordered
  var attentions: seq[SessionAttention]
  for item in result.sessions: attentions.add item.attention
  let s = initiative.progress.summary
  result.state = initiativeStateOf(attentions, result.statusCounts[mscBlocked],
                                   planDone(s.completedMilestones, s.totalMilestones))

proc rows*(vm: InitiativesVM): seq[InitiativeRow] =
  ## Tracked: the initiatives that need the reader first -- by their state
  ## (needs input, blocked, working, idle, ended), the server's order within
  ## a state -- and within one, its sessions needing the reader first.
  discard vm.revision.val
  let selected = vm.selectedId.val
  var all: seq[InitiativeRow]
  for initiative in vm.initiatives:
    all.add vm.rowOf(initiative, selected)
  for state in InitiativeState:
    for row in all:
      if row.state == state: result.add row

proc initiative*(vm: InitiativesVM; id: string): Initiative =
  discard vm.revision.val
  for initiative in vm.initiatives:
    if initiative.id == id: return initiative

proc select*(vm: InitiativesVM; id: string) =
  vm.selectedId.val = id

proc toggleFolded*(vm: InitiativesVM; id: string) =
  ## Folds or unfolds an initiative's node of the tree.
  let at = vm.folded.find(id)
  if at >= 0: vm.folded.delete(at) else: vm.folded.add id
  vm.revision.val = vm.revision.val + 1

proc toggleExpanded*(vm: InitiativesVM; id: string) =
  ## Shows all of an initiative's sessions, or only the first few again.
  let at = vm.expanded.find(id)
  if at >= 0: vm.expanded.delete(at) else: vm.expanded.add id
  vm.revision.val = vm.revision.val + 1

proc summaryText*(vm: InitiativesVM): string =
  ## `5 initiatives · 22 sessions · 3 need input`.
  let rows = vm.rows
  var sessions, needs = 0
  for row in rows:
    sessions += row.sessions.len + row.missingSessions
    needs += row.sessionCounts[saNeedsInput]
  var parts = @[$rows.len & (if rows.len == 1: " initiative" else: " initiatives"),
                $sessions & (if sessions == 1: " session" else: " sessions")]
  if needs > 0: parts.add $needs & (if needs == 1: " needs input" else: " need input")
  if vm.unattached > 0:
    parts.add $vm.unattached & " in no initiative"
  parts.join(" \xC2\xB7 ")
