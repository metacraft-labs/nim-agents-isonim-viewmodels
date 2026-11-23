## `SessionTimelineVM`: the cardless activity timeline of one session -- a
## CARDLESS TIMELINE pattern: one column of lines with no box around any
## event, runs of similar events collapsed into one group line, and every
## line expandable down to its details and, for a shell command, the trace of
## the processes it ran. The panel it fills is titled `Agent Activity`.
##
## The domain is nim-agents' `activity_groups` (`TimelineFold`): what an
## event is, how events group, what breaks a group, and the ids that keep a
## line's identity as events arrive. This viewmodel publishes the fold
## through signals and adds the reader's state, which the data never moves:
##
## - **what the data puts in** -- the load state, the error or the reason
##   the session cannot be loaded, the fold, the session's status, and how
##   many items arrived while the reader was not following -- is cleared on
##   `restart`;
## - **what the reader sets** -- which lines are open, which line has focus,
##   whether the view follows the end, the line the reader reads at, the
##   filter -- is kept on `restart`. Ids are stable, so a line that still
##   exists after a restart is open and focused as the reader left it.
##
## **Loading.** `load` subscribes to the source's fleet frames and resets
## first (as every viewmodel over the seam does), then asks for the
## session's event history (`loadSessionEvents`) and folds its events
## (`rawEvents`, oldest first). It then folds every event frame of its own
## session, skipping one the history already held (by its place in the
## session's history), and ignores every other session's. A lifecycle frame
## of its session moves the status. A reset restarts it.
##
## **Reading.** `lines` flattens the open lines, each with its drill-down
## level (0 a top line, 1 an item of an open group, 2 an item's details, 3 a
## command trace's lines), its indent, its expand mark, its text and the role
## of each part of it. Wrapping is each host's; a line never carries a host's
## unit. A line's text role is decided here once, for every host.
##
## **Actions.** `toggle`, `expandAll` (every group), `collapseAll`;
## `focusNext`, `focusPrev`; `stepIn` (open the focused line and focus its
## first child) and `stepOut` (close the line holding the focus and focus
## it); `setFollow`, `jumpToLatest`; `readAt` and `anchor` (the line a host
## keeps still while it does not follow the end); `setFilter` (a list
## filter over the lines). A host binds them to keys; the ones this family
## proposes are `→` and `←` to open and close, `Enter` to step in, and `+`
## and `-` to expand and collapse everything.
##
## **Links.** An agent's message is also read for links (nim-agents'
## `trace_links.linkSpans`): a trace Agent Harbor holds
## (`agent-harbor://trace/<id>`, or its https form on the session's server,
## `serverOrigin`), a recording on this machine
## (`codetracer://recordings/<test>`), a plain https link, and the file links
## the source's link spans name (`loadLinkSpans`, by the message's place in
## the session's history). They are a part's `links`: the part's text split
## into pieces that join back to it exactly, so a line with links has the
## same `text`, `parts`, `copyText` and `path` as without them, and a host
## that does not draw links draws the line as before. `linkName` is a link's
## accessible name (`Trace <id>`, `Recording <test>`, `File <path>`).
##
## **Test runs.** The session's test runs (`loadSessionTestRuns`) are folded
## as one cardless line each at the run's start (nim-agents'
## `applyTestRun`), worded by `test_runs.summaryLine`; the line never joins a
## group, and opens to one line per test. A run still active is followed
## through `subscribeTestRun`. A source that serves neither leaves the
## timeline as it was.

import std/[json, sets, strutils]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import nim_agents/activity_groups
import nim_agents/agent_harbor/session_replay
import nim_agents/agent_harbor/trace_links as domain_trace_links
import nim_agents/agent_harbor/test_runs as domain_test_runs
import ./data_source
import ./source_feed

export activity_groups, data_source, viewmodel, signals, computation

const
  PanelTitle* = "Agent Activity"
  LoadingNotice* = "Loading activity\xE2\x80\xA6"
  EmptyNotice* = "No activity in this session yet."
  ErrorTitle* = "Could not load this session's activity"
  UnresolvablePrefix* = "This session cannot be loaded: "
  NoTraceText* = "No command trace was recorded"
  WithheldText* = "Instruction withheld"
  Dot = " \xC2\xB7 "
  Minus = "\xE2\x88\x92"
  Open = "\xE2\x96\xBE"     # ▾
  Closed = "\xE2\x96\xB8"   # ▸

type
  TimelineLineKind* = enum
    tlkTurn = "turn"         ## an operator message, starting a turn
    tlkGap = "gap"           ## a quiet gap line
    tlkItem = "item"         ## one event
    tlkGroup = "group"       ## a run of events as one line
    tlkDetail = "detail"     ## level 2: one of an item's details
    tlkTrace = "trace"       ## level 2: a command's trace, or that it has none
    tlkTraceLine = "trace-line" ## level 3: a line of a command trace

  LinePart* = object
    ## A run of a line's text with its role: `label` (the operator's words),
    ## `body`, `quiet`, `error`, `warning`, `running`, `ended`, `added`,
    ## `removed`, `mono` (commands, output, paths in details).
    text*: string
    role*: string
    links*: seq[domain_trace_links.LinkPart]
      ## The part's text split into plain text and links (traces,
      ## recordings, https links, files), joining back to `text` exactly;
      ## empty when it holds no link.

  TimelineLine* = object
    id*: string              ## what `toggle` and focus name
    kind*: TimelineLineKind
    level*: int              ## drill-down level, 0 to 3
    indent*: int             ## nesting depth
    itemKind*: string        ## the item's kind (`TimelineItemKind`), "" for a gap
    state*: TimelineItemState
    text*: string            ## the parts joined
    parts*: seq[LinePart]
    textRole*: string        ## the role of the line's main text
    expandable*, expanded*: bool
    glyph*: string           ## `▸` / `▾` for an expandable line, else ""
    focused*: bool
    copyText*: string        ## what a detail's copy action copies; "" for none
    path*: string
      ## The file path the line's first part ends with ("" for none): a host
      ## cuts it in its middle (`src/…/client.py`) and the words before it at
      ## their end.
    count*: int              ## a group's items of its kind
    failed*, running*: int   ## a group's failed and running items

  SessionTimelineVM* = ref object of ViewModel
    source: AgentHarborDataSource
    sessionId*: string
    policies: TimelinePolicies
    fold: TimelineFold
    session: FleetSession
    folded: int                ## the place in the history of the last event folded
    pending: seq[FleetFrame]   ## frames that came while the history loaded
    loadToken: int
    feeds: SourceFeeds
    expanded: HashSet[string]
    revision*: Signal[int]
      ## Moves whenever the data changes the timeline.
    readerRevision*: Signal[int]
      ## Moves whenever the reader opens or closes a line.
    state*: Signal[AsyncState]
    error*: Signal[string]
    unresolvable*: Signal[string]
      ## Why the session cannot be loaded ("" when it can).
    unseen*: Signal[int]
      ## Items that arrived while the view did not follow the end.
    focus*: Signal[string]
    follow*: Signal[bool]
    readingAt*: Signal[string]
      ## The line at the top of the reader's view, set by the host.
    filter*: Signal[string]
    connection*: Signal[string]
      ## The connection state a header badge shows ("" for none); a host
      ## sets it, since this viewmodel's source reports no connection.
    serverOrigin*: string
      ## The session's server (`https://host[:port]`), whose https trace
      ## links are traces; "" when unknown.
    ordinals: seq[(int, string)]
      ## Each folded event's place in the history, and the item it made or
      ## changed.
    linkSpans: seq[MessageLinkSpans]
    testRuns: seq[domain_test_runs.TestRunState]
    runFeeds: seq[Subscription[TestRunUpdate]]

proc newSessionTimelineVM*(source: AgentHarborDataSource; sessionId: string;
                           policies = agentHarborPolicies();
                           serverOrigin = ""): SessionTimelineVM =
  ## A timeline of `sessionId` over `source`; nothing loads until `load`.
  ## `serverOrigin` is the session's server, for its https trace links.
  withViewModel proc(dispose: proc()): SessionTimelineVM =
    let feeds = newSourceFeeds()
    var created: SessionTimelineVM
    # Disposing the viewmodel's root unsubscribes it from its source.
    onCleanup proc() =
      feeds.close()
      if not created.isNil:
        for s in created.runFeeds: s.cancel()
    created = SessionTimelineVM(source: source, sessionId: sessionId,
                      policies: policies, serverOrigin: serverOrigin,
                      fold: initTimelineFold(policies),
                      session: FleetSession(id: sessionId, rawStatus: "queued",
                                            status: fsQueued),
                      feeds: feeds, expanded: initHashSet[string](),
                      revision: createSignal(0), readerRevision: createSignal(0),
                      state: createSignal(asIdle), error: createSignal(""),
                      unresolvable: createSignal(""), unseen: createSignal(0),
                      focus: createSignal(""), follow: createSignal(true),
                      readingAt: createSignal(""), filter: createSignal(""),
                      connection: createSignal(""))
    created

proc sourceLabel*(vm: SessionTimelineVM): string =
  if vm.source.isNil: "" else: vm.source.label

proc feeds*(vm: SessionTimelineVM): SourceFeeds =
  ## The timeline's subscriptions to its source (`frames`, `resets`).
  vm.feeds

# ---------------------------------------------------------------------------
# Folding
# ---------------------------------------------------------------------------

proc bump(vm: SessionTimelineVM) =
  vm.revision.val = vm.revision.val + 1

proc foldEvent(vm: SessionTimelineVM; event: JsonNode): TimelineChange =
  ## One of its session's events: into the timeline and the status.
  result = vm.fold.applyJson(vm.sessionId, event)
  let before = vm.session.rawStatus
  inc vm.folded
  # Which item the event made or changed, so a message's link spans (named
  # by the event's place in the history) find its line.
  let made = if result.newItems > 0 and vm.fold.timeline.entries.len > 0:
               vm.fold.timeline.entries[^1].id
             elif result.updated.len > 0: result.updated[^1]
             else: ""
  if made.len > 0: vm.ordinals.add (vm.folded, made)
  vm.session.foldEvent(event, vm.folded, 0)
  if vm.session.rawStatus != before: result.changed = true

proc applyFrame*(vm: SessionTimelineVM; frame: FleetFrame): bool =
  ## One fleet frame, as the source delivers it. True when it changed the
  ## timeline: an event of this session the history did not hold, or a
  ## lifecycle frame moving its status. Frames of other sessions change
  ## nothing.
  case frame.kind
  of ffEvent:
    if frame.sessionId != vm.sessionId or frame.event.isNil: return false
    if vm.state.val == asLoading:
      vm.pending.add frame
      return false
    if vm.state.val != asReady: return false
    if frame.ordinal > 0 and frame.ordinal <= vm.folded: return false
    if frame.ordinal > 0: vm.folded = frame.ordinal - 1
    let change = vm.foldEvent(frame.event)
    if change.newItems > 0 and not vm.follow.val:
      vm.unseen.val = vm.unseen.val + change.newItems
    if change.changed: vm.bump()
    change.changed
  of ffLifecycle:
    let f = frame.lifecycle
    if f.sessionId != vm.sessionId or f.status.len == 0 or
        f.status == vm.session.rawStatus:
      return false
    vm.session.rawStatus = f.status
    vm.session.status = parseFleetStatus(f.status)
    if not vm.session.status.isActive:
      vm.session.awaitingInput = false
    vm.bump()
    true
  of ffSession:
    false

proc restart*(vm: SessionTimelineVM)

proc testRunBody(state: domain_test_runs.TestRunState): string =
  ## One line per test: its word across platforms, its name, and each
  ## platform's word.
  var lines: seq[string]
  for testId in state.order:
    var words: seq[string]
    for run in state.platformRuns:
      let key = platformKey(run.platform)
      words.add (if run.platform.label.len > 0: run.platform.label
                 else: platformLabel(run.platform.features)) & " " &
        statusWord(state.cell(key, testId).status)
    # The test's own name: after its runner's prefix and its file
    # (`pytest/tests/test_queue.py::test_x` is `test_x`).
    var name = testId
    let runner = runnerOf(testId)
    if runner.len > 0: name = testId[runner.len + 1 .. ^1]
    let colons = name.rfind("::")
    if colons >= 0 and colons + 2 < name.len: name = name[colons + 2 .. ^1]
    lines.add statusWord(state.rollupOf(testId)) & " " & name & " (" &
      words.join(Dot) & ")"
  lines.join("\n")

proc foldTestRun(vm: SessionTimelineVM; state: domain_test_runs.TestRunState): bool =
  ## One run into the fold (its line, its state, its tests); true when it
  ## changed the timeline.
  var item = tisOk
  if state.isActive: item = tisRunning
  else:
    let counts = state.countsOf
    if counts.failed + counts.errored > 0: item = tisFailed
  vm.fold.applyTestRun(state.id, state.startedMs, summaryLine(state), item,
                       testRunBody(state)).changed

proc followRun(vm: SessionTimelineVM; id: string; token: int) =
  let target = vm
  vm.runFeeds.add vm.source.subscribeTestRun(id,
    proc(update: DataResult[TestRunUpdate]): ProgressDelivery =
      if token != target.loadToken or not update.ok or update.value.kind != truEvent:
        return pdUnchanged
      for run in target.testRuns.mitems:
        if run.id == id:
          var event = update.value.event
          if event.testRunId.len == 0: event.testRunId = id
          if run.applyTestRunEvent(event) and target.foldTestRun(run):
            target.bump()
            return pdApplied
      pdUnchanged)

proc loadLinksAndRuns(vm: SessionTimelineVM; token: int) =
  ## After the history: the file links of the messages and the session's
  ## test runs. A source that serves neither changes nothing.
  let target = vm
  vm.source.loadLinkSpans(vm.sessionId, proc(answer: DataResult[seq[MessageLinkSpans]]) =
    if token != target.loadToken or not answer.ok or answer.value.len == 0: return
    target.linkSpans = answer.value
    target.bump())
  vm.source.loadSessionTestRuns(vm.sessionId,
    proc(answer: DataResult[seq[domain_test_runs.TestRunState]]) =
      if token != target.loadToken or not answer.ok or answer.value.len == 0: return
      target.testRuns = answer.value
      var changed = false
      for run in target.testRuns:
        if target.foldTestRun(run): changed = true
        if run.isActive: target.followRun(run.id, token)
      if changed: target.bump())

proc load*(vm: SessionTimelineVM) =
  ## Subscribes to the source's frames and resets, then loads the session's
  ## history; `asLoading` until it answers. An answer to an older `load` is
  ## ignored.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  vm.unresolvable.val = ""
  vm.pending = @[]
  let target = vm
  vm.feeds.frames.openFleetFrames(vm.source, proc(frame: FleetFrame): bool =
    target.applyFrame(frame))
  vm.feeds.resets.openResets(vm.source, proc(reset: StreamReset): bool =
    target.restart()
    true)
  vm.source.loadSessionEvents(vm.sessionId,
    proc(answer: DataResult[SessionEventHistory]) =
      if token != target.loadToken: return
      if not answer.ok:
        if answer.missing: target.unresolvable.val = answer.error
        else: target.error.val = answer.error
        target.state.val = asError
        return
      for event in answer.value.rawEvents:
        discard target.foldEvent(event)
      target.state.val = asReady
      let pending = target.pending
      target.pending = @[]
      for frame in pending: discard target.applyFrame(frame)
      target.bump()
      target.loadLinksAndRuns(token))

proc restart*(vm: SessionTimelineVM) =
  ## Starts over, as after a source's reset: what the data put in is
  ## dropped and loads again; what the reader set (open lines, focus,
  ## following, the line read at, the filter) is kept.
  vm.fold = initTimelineFold(vm.policies)
  vm.session = FleetSession(id: vm.sessionId, rawStatus: "queued", status: fsQueued)
  vm.folded = 0
  vm.ordinals = @[]
  vm.linkSpans = @[]
  vm.testRuns = @[]
  for s in vm.runFeeds: s.cancel()
  vm.runFeeds = @[]
  vm.unseen.val = 0
  vm.bump()
  vm.load()

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc nodes*(vm: SessionTimelineVM): seq[TimelineNode] =
  ## Tracked: the top-level nodes.
  discard vm.revision.val
  vm.fold.nodes

proc items*(vm: SessionTimelineVM): seq[TimelineItem] =
  ## Tracked: every item, in order.
  discard vm.revision.val
  vm.fold.items

proc foldOf*(vm: SessionTimelineVM): TimelineFold =
  ## Tracked: the fold itself.
  discard vm.revision.val
  vm.fold

proc isEmpty*(vm: SessionTimelineVM): bool =
  ## Tracked: loaded, and the session has nothing to show yet.
  discard vm.revision.val
  vm.state.val == asReady and vm.fold.itemCount == 0

proc statusLabel*(vm: SessionTimelineVM): string =
  ## Tracked: the session's status as a fleet row says it (`needs input`
  ## while it waits on a question).
  discard vm.revision.val
  vm.session.effectiveStatusLabel

proc category*(vm: SessionTimelineVM): FleetCategory =
  discard vm.revision.val
  vm.session.category

proc notice*(vm: SessionTimelineVM): string =
  ## Tracked: the notice a view centres instead of lines, "" when it shows
  ## lines or an error block (`error`, under `ErrorTitle`).
  case vm.state.val
  of asLoading: LoadingNotice
  of asError:
    if vm.unresolvable.val.len > 0: UnresolvablePrefix & vm.unresolvable.val else: ""
  of asReady: (if vm.isEmpty: EmptyNotice else: "")
  else: ""

proc isExpanded*(vm: SessionTimelineVM; id: string): bool =
  discard vm.readerRevision.val
  id in vm.expanded

proc expandedIds*(vm: SessionTimelineVM): seq[string] =
  ## Tracked: the open lines' ids.
  discard vm.readerRevision.val
  for id in vm.expanded: result.add id

proc partsText(parts: openArray[LinePart]): string =
  var texts: seq[string]
  for p in parts:
    if p.text.len > 0: texts.add p.text
  texts.join(" ")

proc itemParts(item: TimelineItem): (seq[LinePart], string) =
  ## An item's line as parts, and its main role.
  case item.kind
  of tikOperator:
    let text = if item.body.len > 0: item.body
               elif item.withheld: WithheldText
               else: item.line
    (@[LinePart(text: text, role: "label")], "label")
  of tikAgent:
    let text = if item.body.len > 0: item.body else: item.line
    (@[LinePart(text: text, role: "body")], "body")
  of tikQuestion:
    let role = if item.answered: "body" else: "warning"
    let text = if item.body.len > 0: item.body else: item.line
    (@[LinePart(text: text, role: role)], role)
  of tikFailure:
    var parts = @[LinePart(text: item.line, role: "error")]
    if item.body.len > 0 and item.body notin item.line:
      parts.add LinePart(text: item.body, role: "body")
    (parts, "error")
  of tikThought, tikStatus, tikResumed, tikModel, tikCancelled:
    (@[LinePart(text: item.line, role: "quiet")], "quiet")
  of tikCompleted:
    var parts = @[LinePart(text: item.line, role: "ended")]
    if item.body.len > 0: parts.add LinePart(text: item.body, role: "body")
    (parts, "ended")
  of tikTestRun:
    # A test run's line is its summary; failing in the error role, running
    # in the running role. Its tests are its details.
    let role = case item.state
      of tisRunning: "running"
      of tisFailed: "error"
      else: "body"
    (@[LinePart(text: item.line, role: role)], role)
  of tikEdit:
    if item.added + item.removed > 0:
      (@[LinePart(text: "Edited " & item.filePath, role: "body"),
         LinePart(text: "+" & $item.added, role: "added"),
         LinePart(text: Minus & $item.removed, role: "removed")], "body")
    else:
      (@[LinePart(text: item.line, role: "body")], "body")
  else:
    var parts = @[LinePart(text: item.line,
                           role: (if item.state == tisRunning: "running" else: "body"))]
    if item.state == tisFailed:
      parts.add LinePart(text: (if item.hasExit: "exit " & $item.exitCode else: "failed"),
                         role: "error")
    (parts, parts[0].role)

proc detailLines(fold: TimelineFold; item: TimelineItem): seq[TimelineLine] =
  ## Level 2 of an item, without ids or indents.
  let detail = fold.detailOf(item.id)
  proc add(lines: var seq[TimelineLine]; text, role: string; copy = false) =
    if text.len == 0: return
    lines.add TimelineLine(kind: tlkDetail, level: 2, text: text, textRole: role,
                           parts: @[LinePart(text: text, role: role)],
                           copyText: (if copy: text else: ""))
  if item.kind in {tikThought, tikCompleted} and detail.body.len > 0:
    result.add(detail.body, "body", copy = true)
  if item.kind == tikTestRun and detail.body.len > 0:
    for test in detail.body.splitLines:
      result.add(test, "body")
  if detail.options.len > 0:
    result.add("Options: " & detail.options.join(Dot), "body")
  for fact in detail.facts:
    result.add(fact.label & ": " & fact.value,
               if fact.tone == "error": "error" else: "quiet")
  if detail.arguments.len > 0 and detail.arguments != "null":
    result.add("Arguments: " & detail.arguments, "mono", copy = true)
  if detail.output.len > 0:
    result.add(detail.output.strip(leading = false), "mono", copy = true)
  if detail.diff.len > 0:
    result.add(detail.diff.strip(leading = false), "mono", copy = true)
  if item.kind == tikShell:
    if item.trace.isSome:
      let trace = item.trace.get
      let stage = trace.failedStage
      var text = "Command trace: " & $trace.processes.len &
        (if trace.processes.len == 1: " process" else: " processes")
      if stage >= 0: text.add ", stage " & $(stage + 1) & " failed"
      result.add TimelineLine(kind: tlkTrace, level: 2, text: text,
        textRole: (if stage >= 0: "error" else: "body"),
        parts: @[LinePart(text: text, role: (if stage >= 0: "error" else: "body"))],
        expandable: true)
    else:
      result.add TimelineLine(kind: tlkTrace, level: 2, text: NoTraceText,
        textRole: "quiet", parts: @[LinePart(text: NoTraceText, role: "quiet")])

proc seconds(ms: int64): string =
  ## `14.2 s`.
  $(ms div 1000) & "." & $((ms mod 1000) div 100) & " s"

proc traceLines(trace: CommandTrace): seq[TimelineLine] =
  ## Level 3: each process (argv; ids, exit, times, executable and directory;
  ## its output), the environment, the raw output.
  proc add(lines: var seq[TimelineLine]; text, role: string; copy = false;
           state = tisNone) =
    if text.len == 0: return
    lines.add TimelineLine(kind: tlkTraceLine, level: 3, text: text, textRole: role,
                           parts: @[LinePart(text: text, role: role)], state: state,
                           copyText: (if copy: text else: ""))
  for p in trace.processes:
    let state = if not p.hasExit: tisRunning
                elif p.exitCode != 0: tisFailed
                else: tisOk
    result.add(p.argv.join(" "), (if state == tisFailed: "error" else: "mono"),
               copy = true, state = state)
    var facts = @["pid " & $p.pid, "parent " & $p.ppid]
    facts.add (if p.hasExit: "exit " & $p.exitCode else: "running")
    facts.add seconds(p.startMs) & " to " &
      (if p.endMs >= 0: seconds(p.endMs) else: "now")
    if p.exe.len > 0: facts.add p.exe
    if p.cwd.len > 0: facts.add p.cwd
    result.add(facts.join(Dot), "quiet")
    result.add(p.stdout.strip(leading = false), "mono", copy = true)
    result.add(p.stderr.strip(leading = false), "error", copy = true)
  if trace.env.len > 0:
    var vars: seq[string]
    for v in trace.env: vars.add v.name & "=" & v.value
    result.add("Environment: " & vars.join(Dot), "quiet")
  if trace.rawOutput.len > 0:
    result.add("Raw output", "quiet")
    result.add(trace.rawOutput.strip(leading = false), "mono", copy = true)

proc matches(fold: TimelineFold; node: TimelineNode; query: string): bool =
  if query.len == 0: return true
  let q = query.toLowerAscii
  if q in fold.nodeText(node).toLowerAscii: return true
  for item in fold.itemsOf(node):
    if q in item.line.toLowerAscii or q in item.body.toLowerAscii: return true
  false

proc spansOf(vm: SessionTimelineVM; itemId: string): seq[FileLinkSpan] =
  ## The link spans of the messages that made or changed the item.
  for (ordinal, id) in vm.ordinals:
    if id != itemId: continue
    for m in vm.linkSpans:
      if m.ordinal == ordinal: result.add m.spans

proc linksOf(vm: SessionTimelineVM; item: TimelineItem; text: string): seq[domain_trace_links.LinkPart] =
  ## The message's text as plain text and links, or none when it holds no
  ## link. File spans count only over the message's own text (its body).
  let spans = if item.body.len > 0 and text == item.body: vm.spansOf(item.id)
              else: @[]
  let parts = linkSpans(text, vm.serverOrigin, spans)
  for p in parts:
    if p.kind != lpText or p.reason.len > 0: return parts
  @[]

proc buildLines(vm: SessionTimelineVM): seq[TimelineLine] =
  let fold = vm.fold
  let query = vm.filter.val
  proc itemLines(lines: var seq[TimelineLine]; vm: SessionTimelineVM;
                 item: TimelineItem; kind: TimelineLineKind; level, indent: int) =
    var (parts, role) = itemParts(item)
    if item.kind == tikAgent: parts[0].links = vm.linksOf(item, parts[0].text)
    var details = detailLines(fold, item)
    let open = item.id in vm.expanded
    let path = if item.filePath.len > 0 and parts[0].text.endsWith(item.filePath) and
                   parts[0].text.len > item.filePath.len: item.filePath
               else: ""
    lines.add TimelineLine(id: item.id, kind: kind, level: level, indent: indent,
      path: path,
      itemKind: $item.kind, state: item.state, parts: parts, text: partsText(parts),
      textRole: role, expandable: details.len > 0, expanded: open and details.len > 0,
      glyph: (if details.len == 0: "" elif open: Open else: Closed))
    if not open: return
    for k, d in details.mpairs:
      d.indent = indent + 1
      if d.kind == tlkTrace and d.expandable:
        d.id = "trace:" & item.id
        let traceOpen = d.id in vm.expanded
        d.expanded = traceOpen
        d.glyph = if traceOpen: Open else: Closed
        lines.add d
        if traceOpen:
          var trace = traceLines(item.trace.get)
          for j, t in trace.mpairs:
            t.id = d.id & ":" & $j
            t.indent = indent + 2
            lines.add t
      else:
        d.id = "detail:" & item.id & ":" & $k
        lines.add d
  for node in fold.nodes:
    if not fold.matches(node, query): continue
    case node.kind
    of tnGap:
      let text = fold.nodeText(node)
      result.add TimelineLine(id: node.id, kind: tlkGap, text: text, textRole: "quiet",
                              parts: @[LinePart(text: text, role: "quiet")])
    of tnTurn:
      result.itemLines(vm, fold.item(node.first), tlkTurn, 0, 0)
    of tnItem:
      result.itemLines(vm, fold.item(node.first), tlkItem, 0, 0)
      if fold.repeatsFault(node.first):
        # One fault is red once: a session's failed ending right after the
        # failure it repeats is drawn as an ending. The fold decides it from
        # the items, so a filter that hides the failure changes nothing.
        var at = result.high
        while result[at].id != node.id: dec at
        result[at].textRole = "ended"
        result[at].parts[0].role = "ended"
    of tnGroup:
      let open = node.id in vm.expanded
      var parts: seq[LinePart]
      if node.groupKind == tgkRepeat:
        parts.add LinePart(text: fold.nodeText(node), role: "quiet")
      else:
        parts.add LinePart(text: node.summary, role: "body")
        if node.groupKind == tgkEdit and node.added + node.removed > 0:
          parts.add LinePart(text: "+" & $node.added, role: "added")
          parts.add LinePart(text: Minus & $node.removed, role: "removed")
        if node.failed > 0: parts.add LinePart(text: node.failedText, role: "error")
        if node.runningItem.len > 0:
          let running = fold.item(fold.findItem(node.runningItem))
          parts.add LinePart(text: running.line, role: "running")
      result.add TimelineLine(id: node.id, kind: tlkGroup, itemKind: $fold.item(node.first).kind,
        state: (if node.running > 0: tisRunning elif node.failed > 0: tisFailed else: tisNone),
        parts: parts, text: partsText(parts), textRole: parts[0].role,
        expandable: true, expanded: open, glyph: (if open: Open else: Closed),
        count: node.count, failed: node.failed, running: node.running)
      if open:
        for i in node.first .. node.last:
          result.itemLines(vm, fold.item(i), tlkItem, 1, 1)
  let focused = vm.focus.val
  for line in result.mitems:
    line.focused = line.id.len > 0 and line.id == focused

proc lines*(vm: SessionTimelineVM): seq[TimelineLine] =
  ## Tracked: the open lines, in order.
  discard vm.revision.val
  discard vm.readerRevision.val
  discard vm.filter.val
  discard vm.focus.val
  vm.buildLines()

proc lineIndex(lines: openArray[TimelineLine]; id: string): int =
  for i, line in lines:
    if line.id == id: return i
  -1

proc runningLine*(vm: SessionTimelineVM): TimelineItem =
  ## Tracked: the newest running command (its line for a `Running: …`
  ## strip a host shows while that line is out of view); an item with an
  ## empty id when none runs.
  discard vm.revision.val
  for i in countdown(vm.fold.itemCount - 1, 0):
    let item = vm.fold.item(i)
    if item.state == tisRunning and item.kind == tikShell: return item

proc matchCount*(vm: SessionTimelineVM): int =
  ## Tracked: the top lines the filter keeps.
  discard vm.revision.val
  let query = vm.filter.val
  for node in vm.fold.nodes:
    if node.kind != tnGap and vm.fold.matches(node, query): inc result

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc readerChanged(vm: SessionTimelineVM) =
  vm.readerRevision.val = vm.readerRevision.val + 1

proc keepFocusVisible(vm: SessionTimelineVM; before: seq[TimelineLine]) =
  ## After lines closed: a focus that is no longer drawn moves to the nearest
  ## drawn line that held it.
  let focused = vm.focus.val
  if focused.len == 0: return
  let now = vm.buildLines()
  if now.lineIndex(focused) >= 0: return
  var i = before.lineIndex(focused)
  if i < 0: return
  var indent = before[i].indent
  while i >= 0:
    if before[i].indent < indent:
      indent = before[i].indent
      if now.lineIndex(before[i].id) >= 0:
        vm.focus.val = before[i].id
        return
    dec i
  vm.focus.val = ""

proc toggle*(vm: SessionTimelineVM; id: string) =
  ## Opens a closed line, closes an open one.
  if id.len == 0: return
  let before = vm.buildLines()
  if id in vm.expanded: vm.expanded.excl id
  else: vm.expanded.incl id
  vm.readerChanged()
  vm.keepFocusVisible(before)

proc expand*(vm: SessionTimelineVM; id: string) =
  if id.len == 0 or id in vm.expanded: return
  vm.expanded.incl id
  vm.readerChanged()

proc expandAll*(vm: SessionTimelineVM) =
  ## Opens every group (level 1); items and traces stay as they are.
  var changed = false
  for node in vm.fold.nodes:
    if node.kind == tnGroup and node.id notin vm.expanded:
      vm.expanded.incl node.id
      changed = true
  if changed: vm.readerChanged()

proc collapseAll*(vm: SessionTimelineVM) =
  ## Closes every line.
  if vm.expanded.len == 0: return
  let before = vm.buildLines()
  vm.expanded.clear()
  vm.readerChanged()
  vm.keepFocusVisible(before)

proc setFocus*(vm: SessionTimelineVM; id: string) =
  vm.focus.val = id

proc focusNext*(vm: SessionTimelineVM) =
  ## Focus moves to the next line (the first when none has focus).
  let lines = vm.buildLines()
  if lines.len == 0: return
  let i = lines.lineIndex(vm.focus.val)
  vm.focus.val = lines[if i < 0: 0 else: min(i + 1, lines.high)].id

proc focusPrev*(vm: SessionTimelineVM) =
  ## Focus moves to the line before (the last when none has focus).
  let lines = vm.buildLines()
  if lines.len == 0: return
  let i = lines.lineIndex(vm.focus.val)
  vm.focus.val = lines[if i < 0: lines.high else: max(i - 1, 0)].id

proc stepIn*(vm: SessionTimelineVM) =
  ## Opens the focused line, one level, and focuses its first child.
  let lines = vm.buildLines()
  let i = lines.lineIndex(vm.focus.val)
  if i < 0 or not lines[i].expandable: return
  vm.expand(lines[i].id)
  let now = vm.buildLines()
  let j = now.lineIndex(lines[i].id)
  if j >= 0 and j < now.high and now[j + 1].indent > now[j].indent:
    vm.focus.val = now[j + 1].id

proc stepOut*(vm: SessionTimelineVM) =
  ## Closes the line holding the focus and focuses it; on an open top line,
  ## closes it.
  let lines = vm.buildLines()
  let i = lines.lineIndex(vm.focus.val)
  if i < 0: return
  if lines[i].indent == 0:
    if lines[i].expanded: vm.toggle(lines[i].id)
    return
  var j = i - 1
  while j >= 0 and lines[j].indent >= lines[i].indent: dec j
  if j < 0: return
  vm.focus.val = lines[j].id
  if lines[j].expanded: vm.toggle(lines[j].id)

proc setFollow*(vm: SessionTimelineVM; follow: bool) =
  ## Following the end clears the count of unseen items.
  vm.follow.val = follow
  if follow: vm.unseen.val = 0

proc jumpToLatest*(vm: SessionTimelineVM) =
  vm.setFollow(true)

proc readAt*(vm: SessionTimelineVM; id: string) =
  ## The host reports the line at the top of the reader's view.
  vm.readingAt.val = id

proc anchor*(vm: SessionTimelineVM): string =
  ## Tracked: the line a host keeps still while new lines arrive: "" while
  ## following the end; otherwise the line read at, or, when it has joined a
  ## group since, the group's line.
  discard vm.revision.val
  discard vm.readerRevision.val
  if vm.follow.val: return ""
  let id = vm.readingAt.val
  if id.len == 0: return ""
  let lines = vm.buildLines()
  if lines.lineIndex(id) >= 0: return id
  let i = vm.fold.findItem(id)
  if i >= 0:
    for node in vm.fold.nodes:
      if node.first <= i and i <= node.last and node.kind != tnGap: return node.id
  ""

proc setFilter*(vm: SessionTimelineVM; query: string) =
  vm.filter.val = query.strip

# ---------------------------------------------------------------------------
# Links and test runs
# ---------------------------------------------------------------------------

proc linkName*(link: domain_trace_links.LinkPart): string =
  ## A link's accessible name, naming its target: `Trace <id>`, `Recording
  ## <test>`, `File <path>`, `Link <url>`; "" for plain text.
  case link.kind
  of lpTrace: accessibleName(link.reference)
  of lpFile:
    for t in link.targets:
      if t.exists: return "File " & t.path
    "File " & (if link.targets.len > 0: link.targets[0].path else: link.text)
  of lpUrl: "Link " & link.text
  of lpText: ""

proc hasLinks*(line: TimelineLine): bool =
  ## Whether a part of the line holds a link (or a link-like text that is
  ## not one, with its tooltip).
  for p in line.parts:
    if p.links.len > 0: return true
  false

proc testRunsOf*(vm: SessionTimelineVM): seq[domain_test_runs.TestRunState] =
  ## Tracked: the session's test runs, as their lines show them.
  discard vm.revision.val
  vm.testRuns
