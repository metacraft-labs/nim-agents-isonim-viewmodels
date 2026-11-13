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
##
## Progress events reach it through the seam too: `load` subscribes to the
## source's progress events (`subscribeProgress`, through a `ProgressFeed`),
## so a source that sends one moves the rows with no host call; disposing the
## viewmodel unsubscribes it. `progressState` / `progressError` report the
## feed (an error when the source does not provide the events).
##
## The sessions under each initiative follow the source the same way: `load`
## also subscribes to its fleet frames (`subscribeFleetFrames`: a session
## changes state, starts or stops waiting, ends, goes away), resumes
## (`subscribeResumes`) and resets (`subscribeResets`: the panel starts over,
## `restart`). An initiative lists the sessions its entry names
## (`Initiative.sessionIds`); a session launched for it after the load shows
## once the initiative is loaded again. `feeds` reports every subscription.

import std/strutils
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import ./data_source
import ./progress_feed
import ./source_feed
import ./session_items

export data_source, progress_feed, session_items, viewmodel, signals, computation

type
  InitiativeRow* = object
    id*: string
    title*: string
    repository*: string
    manager*: string
    currentMilestone*: string     ## `RC-M2: Core change` (id and title), "" when none
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
    directory: SessionDirectory
      ## The listing's sessions, following the source's frames.
    nowMs: int64
    policy*: SessionPolicy
    revision*: Signal[int]
    state*: Signal[AsyncState]
    error*: Signal[string]
    selectedId*: Signal[string]
    folded: seq[string]
    expanded: seq[string]
    loadToken: int
    feeds: SourceFeeds
    progressState*: Signal[AsyncState]
      ## The progress feed: `asIdle` before `load`, `asReady` while subscribed,
      ## `asError` when the source does not provide progress events.
    progressError*: Signal[string]

proc newInitiativesVM*(source: AgentHarborDataSource;
                       policy = tabStripSessionPolicy()): InitiativesVM =
  withViewModel proc(dispose: proc()): InitiativesVM =
    let feeds = newSourceFeeds()
    # Disposing the viewmodel's root unsubscribes it from its source.
    onCleanup proc() = feeds.close()
    InitiativesVM(source: source, policy: policy,
                  directory: initSessionDirectory(),
                  revision: createSignal(0), state: createSignal(asIdle),
                  error: createSignal(""), selectedId: createSignal(""),
                  feeds: feeds, progressState: feeds.progress.state,
                  progressError: feeds.progress.error)

proc sourceLabel*(vm: InitiativesVM): string =
  if vm.source.isNil: "" else: vm.source.label

proc applyProgress*(vm: InitiativesVM; event: ProgressEvent): bool =
  ## A progress event, as the source's subscription delivers it. True when
  ## it changed an initiative; one for an unknown initiative or milestone, or
  ## one that repeats a status, changes nothing and moves no signal.
  if vm.initiatives.applyProgressEvent(event):
    vm.revision.val = vm.revision.val + 1
    return true
  false

proc lateProgressEvents*(vm: InitiativesVM): int =
  ## Progress events a source delivered after the viewmodel unsubscribed
  ## (disposed or reloaded); none of them moved it.
  vm.feeds.progress.lateEvents

proc feeds*(vm: InitiativesVM): SourceFeeds =
  ## The panel's subscriptions to its source (`frames`, `resumes`,
  ## `progress`, `resets`).
  vm.feeds

proc applyFleetFrame*(vm: InitiativesVM; frame: FleetFrame): bool =
  ## A fleet frame from the source, folded into the sessions the panel
  ## holds. True when it changed them.
  if not vm.directory.followFrame(vm.nowMs, frame): return false
  vm.revision.val = vm.revision.val + 1
  true

proc resume*(vm: InitiativesVM; event: ResumeEvent): bool =
  ## The operator's input reached a waiting session (nim-agents'
  ## `resumeSession`). True when that changed it.
  if not vm.directory.resumeSession(event.sessionId, event.atMs): return false
  vm.nowMs = max(vm.nowMs, event.atMs)
  vm.revision.val = vm.revision.val + 1
  true

proc restart*(vm: InitiativesVM)

proc load*(vm: InitiativesVM) =
  ## Ready once the initiatives answer; the sessions fill in when the listing
  ## answers (a listing failure leaves the sessions as counts only). Subscribes
  ## to the source's progress events first, replacing an earlier subscription,
  ## so no event falls between the answer and the subscription.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  let target = vm
  vm.feeds.progress.openProgress(vm.source, proc(event: ProgressEvent): bool =
    target.applyProgress(event))
  vm.feeds.frames.openFleetFrames(vm.source, proc(frame: FleetFrame): bool =
    target.applyFleetFrame(frame))
  vm.feeds.resumes.openResumes(vm.source, proc(event: ResumeEvent): bool =
    target.resume(event))
  vm.feeds.resets.openResets(vm.source, proc(reset: StreamReset): bool =
    target.restart()
    true)
  vm.source.loadFleet proc(answer: DataResult[FleetSnapshot]) =
    if token != target.loadToken or not answer.ok: return
    target.directory = initSessionDirectory(answer.value.sessions)
    target.nowMs = answer.value.capturedAtMs
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
    let at = vm.directory.find(id)
    if at >= 0:
      var item = sessionItemOf(vm.directory.sessions[at], vm.nowMs, vm.policy)
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
  var unattached = 0
  for session in vm.directory.sessions:
    if session.planId.len == 0: inc unattached
  if unattached > 0:
    parts.add $unattached & " in no initiative"
  parts.join(" \xC2\xB7 ")

proc restart*(vm: InitiativesVM) =
  ## Starts over, as after a source's reset: the initiatives, their sessions
  ## and the selection are dropped with the data they came from; folded and
  ## expanded nodes are the reader's and stay. Then the panel loads again.
  vm.initiatives = @[]
  vm.directory = initSessionDirectory()
  vm.nowMs = 0
  vm.selectedId.val = ""
  vm.revision.val = vm.revision.val + 1
  vm.load()
