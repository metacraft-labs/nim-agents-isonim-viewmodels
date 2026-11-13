## `FleetSnapshotVM`: the sessions family's LIST variant -- the reactive view
## of an Agent Harbor fleet's sessions, the data behind a fleet overview panel
## (a scannable table of every session, waiting-for-a-person first; the
## counterpart of the AH WebUI's session feed, inventory items INV-P2-01 and
## INV-P2-12). The tab-strip variant over the same domain is
## `session_tabs_vm.nim`.
##
## It reads through an `AgentHarborDataSource` and publishes:
##
## - the load state (`state`, `error`): loading until the source answers,
##   then ready or error;
## - the fleet's sessions as presentation rows (`rows`), filtered by
##   category (`filter`) and ordered with the sessions that wait for a person
##   first, then by most recent activity;
## - the count of sessions per category (`counts`), for the filter strip;
## - the selected session (`selectedId`), whose event history it loads on
##   selection (`selectedEvents`, `eventsState`).
##
## Text formatting (agent labels, ages, activity lines) is done here rather
## than in a view so every front-end, and every headless test, reads the same
## words. The rules beneath it -- effective status, the title's fallback, the
## activity digest -- are nim-agents' (`nim_agents/agent_harbor/*`).
##
## A row's activity is a digest (`digestActivity`): every distinct recent
## line once, counted, the most informative first. A row shows the first line;
## `expandedId` names the one row that shows them all.
##
## The fleet is held as nim-agents' fleet fold (`fleet_fold.FleetFold`): a
## loaded snapshot is a fold of one listing, and `apply` folds the frames that
## follow it (a session starting, changing state, ending or being removed, its
## listing entry, its events), so the list follows a live feed or a played-back
## run after its first snapshot. A list that is only ever loaded shows exactly
## the snapshot, as before.
##
## Those frames reach it through the seam: `load` subscribes to the source's
## fleet frames (`subscribeFleetFrames`) and resets (`subscribeResets`)
## before it asks for the listing, so a live or playback source moves the
## list with no host call; a reset (a playback source seeking backwards)
## restarts it (`restart`). Disposing the viewmodel unsubscribes it. `feeds`
## reports each subscription (an error when the source does not provide the
## kind; a source that only answers loads leaves the list as loaded).

import std/[algorithm, strutils]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import nim_agents/agent_harbor/[session_directory, activity_digest, fleet_fold]
import ./data_source
import ./source_feed

export data_source, source_feed, viewmodel, signals, computation,
  activity_digest, fleet_fold

const
  FleetActivityLineLimit* = 3
    ## The most activity lines an expanded row shows (the AH WebUI shows
    ## three, inventory INV-P2-25); a collapsed row shows one.
  FleetWithheldPromptText* = "prompt withheld"
    ## Said beside a title that is not the prompt, when the server withheld it.
  FleetEmptyPromptText* = "no prompt"

type
  FleetFilter* = enum
    ffAll = "all"
    ffNeedsInput = "needs-input"
    ffRunning = "running"
    ffQueued = "queued"
    ffFailed = "failed"
    ffEnded = "ended"

  FleetRow* = object
    ## One session as a list row shows it.
    id*: string
    shortId*: string
    title*: string
    titleIsPlaceholder*: bool  ## a placeholder, rendered muted
    titleSource*: string       ## `prompt`, `name`, `branch`, `workspace` or `id`
    promptNote*: string        ## "prompt withheld" / "no prompt" when the title is not the prompt
    labelTooltip*: string      ## where a non-prompt title came from
    initiative*: string
    workspace*: string         ## the workspace, unless it is already the title
    category*: FleetCategory
    status*: FleetStatus
    statusLabel*: string
    agentLabel*: string
    agentCount*: int
    host*: string
    repository*: string
    branch*: string
    ageLabel*: string          ## since the last update
    durationLabel*: string     ## start to end, or to the snapshot, when live
    needsInput*: bool
    inputSource*: string
    failureText*: string
    activity*: seq[string]
      ## The digest's lines as shown, most informative first, at most
      ## `FleetActivityLineLimit`.
    activityLevels*: seq[string]
    activityMore*: int
      ## Distinct lines beyond those in `activity`.
    selected*: bool
    expanded*: bool

  FleetCounts* = object
    total*: int                ## sessions the server reports in all
    listed*: int               ## sessions this snapshot holds
    byCategory*: array[FleetCategory, int]
    withheldPrompts*: int      ## sessions whose prompt the server withheld

  FleetSnapshotVM* = ref object of ViewModel
    source: AgentHarborDataSource
    fold: FleetFold
    revision*: Signal[int]
      ## Moves whenever the fleet changes (a load answers, or a folded frame
      ## changes it); tracked reads depend on it.
    state*: Signal[AsyncState]
    error*: Signal[string]
    filter*: Signal[FleetFilter]
    selectedId*: Signal[string]
    expandedId*: Signal[string]
      ## The row that shows all its activity lines ("" for none).
    selectedEvents*: Signal[SessionEventHistory]
    eventsState*: Signal[AsyncState]
    eventsError*: Signal[string]
    loadToken: int
      ## Guards against an answer to a superseded load (a live source may
      ## answer a reload's first request after its second).
    feeds: SourceFeeds

proc newFleetSnapshotVM*(source: AgentHarborDataSource): FleetSnapshotVM =
  ## A viewmodel over `source`. Nothing is loaded until `load` is called, so
  ## a story or a test can observe the idle state too.
  withViewModel proc(dispose: proc()): FleetSnapshotVM =
    let feeds = newSourceFeeds()
    # Disposing the viewmodel's root unsubscribes it from its source.
    onCleanup proc() = feeds.close()
    FleetSnapshotVM(
      source: source, feeds: feeds,
      fold: initFleetFold(),
      revision: createSignal(0),
      state: createSignal(asIdle),
      error: createSignal(""),
      filter: createSignal(ffAll),
      selectedId: createSignal(""),
      expandedId: createSignal(""),
      selectedEvents: createSignal(SessionEventHistory()),
      eventsState: createSignal(asIdle),
      eventsError: createSignal(""))

proc sourceLabel*(vm: FleetSnapshotVM): string =
  if vm.source.isNil: "" else: vm.source.label

proc snapshot*(vm: FleetSnapshotVM): FleetSnapshot =
  ## Tracked read of the whole fleet, as a listing taken at the moment of the
  ## last frame folded (the loaded snapshot itself until a frame arrives).
  discard vm.revision.val
  vm.fold.snapshot

proc feeds*(vm: FleetSnapshotVM): SourceFeeds =
  ## The list's subscriptions to its source (`frames`, `resets`).
  vm.feeds

proc apply*(vm: FleetSnapshotVM; frame: FleetFrame): FoldOutcome
proc restart*(vm: FleetSnapshotVM)

proc load*(vm: FleetSnapshotVM) =
  ## Asks the source for the session list. The state is `asLoading` until it
  ## answers; an answer to an older `load` is ignored. Subscribes to the
  ## source's fleet frames and resets first, replacing earlier
  ## subscriptions, so no frame falls between the answer and the
  ## subscription.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  let target = vm
  vm.feeds.frames.openFleetFrames(vm.source, proc(frame: FleetFrame): bool =
    target.apply(frame) == foApplied)
  vm.feeds.resets.openResets(vm.source, proc(reset: StreamReset): bool =
    target.restart()
    true)
  vm.source.loadFleet proc(answer: DataResult[FleetSnapshot]) =
    if token != target.loadToken: return
    if answer.ok:
      target.fold = initFleetFold(answer.value)
      target.revision.val = target.revision.val + 1
      target.state.val = asReady
    else:
      target.error.val = answer.error
      target.state.val = asError

proc matches(filter: FleetFilter; category: FleetCategory): bool =
  case filter
  of ffAll: true
  of ffNeedsInput: category == fcNeedsInput
  of ffRunning: category == fcRunning
  of ffQueued: category == fcQueued
  of ffFailed: category == fcFailed
  of ffEnded: category == fcEnded

proc repositoryLabel(url: string): string =
  ## `owner/name` of a repository URL; the URL itself when it has no path.
  var s = url
  if s.endsWith(".git"): s = s[0 ..< ^4]
  let parts = s.split({'/', ':'})
  if parts.len >= 2 and parts[^1].len > 0 and parts[^2].len > 0:
    parts[^2] & "/" & parts[^1]
  else:
    s

proc failureOf*(session: FleetSession): string =
  ## Why a failed session failed (inventory INV-P2-16): its last error-level
  ## log line, else its last log line of any level (the server logs a
  ## process's exit, `[exit] status=143`, at info level), else the reason
  ## the data source found in the session's history, else nothing --
  ## a failure the server gave no reason for shows no invented one.
  ## The listing and the history are judged by the same rule
  ## (`failureReasonOf`), so a line a capture scrubbed is never a reason in
  ## either.
  if session.category != fcFailed: return ""
  result = failureReasonOf(session.recent.reversed)
  if result.len == 0: result = session.failureReason

proc toRow(session: FleetSession; digest: openArray[DigestLine]; nowMs: int64;
           selected: string; expanded = ""): FleetRow =
  # nim-agents' rule (`session_directory.titleOf`): the prompt, else the
  # session's name, branch or workspace, else its short id.
  let (title, labelSource) = session_directory.titleOf(session)
  let source = $labelSource
  result = FleetRow(
    id: session.id,
    shortId: if session.id.len > 8: session.id[0 ..< 8] else: session.id,
    title: title,
    titleIsPlaceholder: source == "id",
    titleSource: source,
    promptNote: if source == "prompt": ""
                elif session.promptWithheld: FleetWithheldPromptText
                else: FleetEmptyPromptText,
    labelTooltip: if source in ["prompt", "id"]: ""
                  else: source & (if session.labelSource.len > 0: ", from " & session.labelSource else: ""),
    initiative: session.initiative,
    workspace: if session.workspaceName == title: "" else: session.workspaceName,
    category: session.category,
    status: session.status,
    statusLabel: session.effectiveStatusLabel,
    agentLabel: agentLabel(session.agentSoftware, session.agentVersion),
    agentCount: session.agentCount,
    host: session.host,
    repository: if session.repoUrl.len > 0: repositoryLabel(session.repoUrl)
                else: "",
    branch: if session.branch == title: "" else: session.branch,
    ageLabel: ageLabel(nowMs, session.lastActivityMs),
    durationLabel: durationLabel(
      if session.startedAtMs > 0: session.startedAtMs else: session.createdAtMs,
      if session.endedAtMs > 0: session.endedAtMs
      elif session.status.isActive: nowMs
      else: 0),
    needsInput: session.category == fcNeedsInput,
    inputSource: session.awaitingInputSource,
    failureText: session.failureOf,
    selected: session.id == selected,
    expanded: session.id == expanded)
  let shown = min(digest.len, FleetActivityLineLimit)
  for i in 0 ..< shown:
    result.activity.add digest[i].lineText
    result.activityLevels.add digest[i].level
  result.activityMore = digest.len - shown

proc rowsOf*(fold: FleetFold; filter: FleetFilter;
             selected = ""; expanded = ""): seq[FleetRow] =
  ## The ordering every front-end shows, untracked: sessions waiting for a
  ## person first, then running, queued, failed and ended; within a category
  ## the most recently active first, the session id breaking ties so the
  ## order is total. Each row's activity is the digest the fold last
  ## recomputed for its session; ages are measured from the fold's clock.
  var sessions: seq[FleetSession]
  for session in fold.sessions:
    if filter.matches(session.category):
      sessions.add(session)
  sessions.sort proc(a, b: FleetSession): int =
    result = cmp(ord(a.category), ord(b.category))
    if result == 0: result = cmp(b.lastActivityMs, a.lastActivityMs)
    if result == 0: result = cmp(a.id, b.id)
  for session in sessions:
    result.add(session.toRow(fold.digestOf(session.id), fold.capturedAtMs,
                             selected, expanded))

proc rowsOf*(snapshot: FleetSnapshot; filter: FleetFilter;
             selected = ""; expanded = ""): seq[FleetRow] =
  ## The rows of one listing (`rowsOf` over a fold of it).
  rowsOf(initFleetFold(snapshot), filter, selected, expanded)

proc rows*(vm: FleetSnapshotVM): seq[FleetRow] =
  ## Tracked: depends on the fleet, the filter and the selection.
  discard vm.revision.val
  rowsOf(vm.fold, vm.filter.val, vm.selectedId.val, vm.expandedId.val)

proc countsOf*(fold: FleetFold): FleetCounts =
  ## What the filter strip counts, untracked.
  result = FleetCounts(total: fold.total, listed: fold.len,
                       byCategory: fold.counts)
  for session in fold.sessions:
    if session.promptWithheld: inc result.withheldPrompts

proc counts*(vm: FleetSnapshotVM): FleetCounts =
  ## Tracked: depends on the fleet only, so a filter change does not move
  ## the counts.
  discard vm.revision.val
  vm.fold.countsOf

proc anyInitiative*(vm: FleetSnapshotVM): bool =
  ## Tracked: whether any session of the fleet names an initiative -- over
  ## the whole fleet, not the filtered rows, so a filter that leaves few
  ## rows (or none) does not change which columns a wide list draws.
  discard vm.revision.val
  for session in vm.fold.sessions:
    if session.initiative.len > 0: return true
  false

proc capturedAgeLabel*(vm: FleetSnapshotVM): string =
  ## When the snapshot was taken (for a fleet that follows frames, the
  ## moment of the last one), as `YYYY-MM-DD HH:MM UTC`; empty if unknown.
  discard vm.revision.val
  let ms = vm.fold.capturedAtMs
  if ms <= 0: return ""
  # Civil date from days since the epoch (Hinnant's civil_from_days).
  let z = ms div 86_400_000 + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let day = doy - (153 * mp + 2) div 5 + 1
  let month = if mp < 10: mp + 3 else: mp - 9
  let year = yoe + era * 400 + (if month <= 2: 1 else: 0)
  let secs = (ms mod 86_400_000) div 1000
  proc two(v: int64): string = (if v < 10: "0" else: "") & $v
  $year & "-" & two(month) & "-" & two(day) & " " & two(secs div 3600) & ":" &
    two((secs mod 3600) div 60) & " UTC"

proc apply*(vm: FleetSnapshotVM; frame: FleetFrame): FoldOutcome =
  ## Folds one frame that follows the loaded snapshot (`fleet_fold.apply`)
  ## and tells what it did; the list moves only when the fleet changed. A
  ## frame that arrives before the first load answers is folded into an
  ## empty fleet, which that answer then replaces. A selected or expanded
  ## session the frame removed is no longer selected or expanded.
  result = vm.fold.apply(frame)
  if result != foApplied: return
  if vm.selectedId.val.len > 0 and vm.fold.find(vm.selectedId.val) < 0:
    vm.selectedId.val = ""
    vm.selectedEvents.val = SessionEventHistory()
    vm.eventsState.val = asIdle
    vm.eventsError.val = ""
  if vm.expandedId.val.len > 0 and vm.fold.find(vm.expandedId.val) < 0:
    vm.expandedId.val = ""
  vm.revision.val = vm.revision.val + 1

proc applyFrame*(vm: FleetSnapshotVM; frame: LifecycleFrame): FoldOutcome =
  ## A lifecycle frame from the feed, as the tab strip takes it.
  vm.apply(lifecycleFrame(frame))

proc restart*(vm: FleetSnapshotVM) =
  ## Starts over, as after a source's reset: the selection, its events and
  ## the expanded row are dropped (they named sessions of a fleet that is
  ## void), the filter is kept (the reader's choice, not the data's), and
  ## the list loads again.
  vm.selectedId.val = ""
  vm.expandedId.val = ""
  vm.selectedEvents.val = SessionEventHistory()
  vm.eventsState.val = asIdle
  vm.eventsError.val = ""
  vm.load()

proc setFilter*(vm: FleetSnapshotVM; filter: FleetFilter) =
  vm.filter.val = filter

proc toggleExpanded*(vm: FleetSnapshotVM; sessionId: string) =
  ## Shows all of a row's activity lines, or folds them back to one.
  vm.expandedId.val = if vm.expandedId.val == sessionId: "" else: sessionId

proc select*(vm: FleetSnapshotVM; sessionId: string) =
  ## Selects a session and loads its event history; selecting the selected
  ## session again keeps it (a row click is not a toggle).
  if vm.selectedId.val == sessionId and vm.eventsState.val in {asLoading, asReady}:
    return
  vm.selectedId.val = sessionId
  vm.selectedEvents.val = SessionEventHistory(sessionId: sessionId)
  if sessionId.len == 0:
    vm.eventsState.val = asIdle
    return
  vm.eventsState.val = asLoading
  vm.eventsError.val = ""
  let target = vm
  vm.source.loadSessionEvents(sessionId,
    proc(answer: DataResult[SessionEventHistory]) =
      if target.selectedId.val != sessionId: return
      if answer.ok:
        target.selectedEvents.val = answer.value
        target.eventsState.val = asReady
      else:
        target.eventsError.val = answer.error
        target.eventsState.val = asError)
