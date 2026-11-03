## `FleetSnapshotVM`: the reactive view of an Agent Harbor fleet's sessions,
## the data behind a fleet overview panel (the counterpart of the
## AH WebUI's session feed, inventory items INV-P2-01 and INV-P2-12).
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
## words.

import std/[algorithm, strutils]
import isonim/core/[signals, computation]
import isonim/viewmodel
import ./data_source

export data_source, viewmodel, signals, computation

const
  FleetActivityLineLimit* = 3
    ## Activity lines per row, as the AH WebUI shows (inventory INV-P2-25).
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
    activityLevels*: seq[string]
    selected*: bool

  FleetCounts* = object
    total*: int                ## sessions the server reports in all
    listed*: int               ## sessions this snapshot holds
    byCategory*: array[FleetCategory, int]

  FleetSnapshotVM* = ref object of ViewModel
    source: AgentHarborDataSource
    snapshot: FleetSnapshot
    revision*: Signal[int]
      ## Moves whenever `snapshot` is replaced; tracked reads depend on it.
    state*: Signal[AsyncState]
    error*: Signal[string]
    filter*: Signal[FleetFilter]
    selectedId*: Signal[string]
    selectedEvents*: Signal[SessionEventHistory]
    eventsState*: Signal[AsyncState]
    eventsError*: Signal[string]
    loadToken: int
      ## Guards against an answer to a superseded load (a live source may
      ## answer a reload's first request after its second).

proc newFleetSnapshotVM*(source: AgentHarborDataSource): FleetSnapshotVM =
  ## A viewmodel over `source`. Nothing is loaded until `load` is called, so
  ## a story or a test can observe the idle state too.
  withViewModel proc(dispose: proc()): FleetSnapshotVM =
    FleetSnapshotVM(
      source: source,
      revision: createSignal(0),
      state: createSignal(asIdle),
      error: createSignal(""),
      filter: createSignal(ffAll),
      selectedId: createSignal(""),
      selectedEvents: createSignal(SessionEventHistory()),
      eventsState: createSignal(asIdle),
      eventsError: createSignal(""))

proc sourceLabel*(vm: FleetSnapshotVM): string =
  if vm.source.isNil: "" else: vm.source.label

proc snapshot*(vm: FleetSnapshotVM): FleetSnapshot =
  ## Tracked read of the whole snapshot.
  discard vm.revision.val
  vm.snapshot

proc load*(vm: FleetSnapshotVM) =
  ## Asks the source for the session list. The state is `asLoading` until it
  ## answers; an answer to an older `load` is ignored.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  let target = vm
  vm.source.loadFleet proc(answer: DataResult[FleetSnapshot]) =
    if token != target.loadToken: return
    if answer.ok:
      target.snapshot = answer.value
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

proc lastActivityMs(session: FleetSession): int64 =
  result = max(session.updatedAtMs, max(session.startedAtMs, session.createdAtMs))
  for event in session.recent:
    result = max(result, event.timestampMs)

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

proc titleOf*(session: FleetSession): tuple[text, source: string] =
  ## What a row is titled, in order of preference: the prompt's first line;
  ## when the prompt is withheld or empty, what a person calls the session --
  ## its name, its branch, its workspace; and only when nothing is known, its
  ## short id. Every session therefore gets a title that tells it apart from
  ## its neighbours.
  let shortId = if session.id.len > 8: session.id[0 ..< 8] else: session.id
  if session.prompt.strip.len > 0: (session.prompt.strip.splitLines()[0], "prompt")
  elif session.name.strip.len > 0: (session.name.strip, "name")
  elif session.branch.strip.len > 0: (session.branch.strip, "branch")
  elif session.workspaceName.strip.len > 0: (session.workspaceName.strip, "workspace")
  else: ("Session " & shortId, "id")

proc activityLines*(recent: openArray[FleetActivity];
                    limit = FleetActivityLineLimit): (seq[string], seq[string]) =
  ## The newest `limit` activity lines, oldest first, with their levels. A run
  ## of identical consecutive lines is one line marked `×N`, so a stalled
  ## session that resumed three times reads as one line, not three.
  var texts, levels: seq[string]
  var counts: seq[int]
  for event in recent:
    if texts.len > 0 and texts[^1] == event.text and levels[^1] == event.level:
      inc counts[^1]
    else:
      texts.add(event.text)
      levels.add(event.level)
      counts.add(1)
  let start = max(0, texts.len - limit)
  for i in start ..< texts.len:
    result[0].add(if counts[i] > 1: texts[i] & " \xC3\x97" & $counts[i] else: texts[i])
    result[1].add(levels[i])

proc toRow(session: FleetSession; nowMs: int64; selected: string): FleetRow =
  let (title, source) = session.titleOf
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
    selected: session.id == selected)
  (result.activity, result.activityLevels) = activityLines(session.recent)

proc rowsOf*(snapshot: FleetSnapshot; filter: FleetFilter;
             selected = ""): seq[FleetRow] =
  ## The ordering every front-end shows, untracked: sessions waiting for a
  ## person first, then running, queued, failed and ended; within a category
  ## the most recently active first, the session id breaking ties so the
  ## order is total.
  var sessions: seq[FleetSession]
  for session in snapshot.sessions:
    if filter.matches(session.category):
      sessions.add(session)
  sessions.sort proc(a, b: FleetSession): int =
    result = cmp(ord(a.category), ord(b.category))
    if result == 0: result = cmp(b.lastActivityMs, a.lastActivityMs)
    if result == 0: result = cmp(a.id, b.id)
  for session in sessions:
    result.add(session.toRow(snapshot.capturedAtMs, selected))

proc rows*(vm: FleetSnapshotVM): seq[FleetRow] =
  ## Tracked: depends on the snapshot, the filter and the selection.
  discard vm.revision.val
  rowsOf(vm.snapshot, vm.filter.val, vm.selectedId.val)

proc counts*(vm: FleetSnapshotVM): FleetCounts =
  ## Tracked: depends on the snapshot only, so a filter change does not move
  ## the counts.
  discard vm.revision.val
  FleetCounts(total: vm.snapshot.total, listed: vm.snapshot.sessions.len,
              byCategory: categoryCounts(vm.snapshot.sessions))

proc capturedAgeLabel*(vm: FleetSnapshotVM): string =
  ## When the snapshot was taken, as `YYYY-MM-DD HH:MM UTC`; empty if unknown.
  discard vm.revision.val
  let ms = vm.snapshot.capturedAtMs
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

proc setFilter*(vm: FleetSnapshotVM; filter: FleetFilter) =
  vm.filter.val = filter

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
