## `TestRunsVM`: a change's tests as a MATRIX OF TESTS BY PLATFORMS -- the
## Test Results pane's join of what exists (the catalog) and what a run said,
## per platform. The panel it fills is titled `Test Results`: it is the Test
## Results pane in its Agent Harbor mode, with a platform dimension.
##
## Its data and the rules every surface shares come from a `TestRunFeed`
## (`test_run_feed.nim`): the platforms offered, their catalogs, the
## session's runs as their events arrive, and why a cell cannot be run or
## recorded. This viewmodel adds the reader's state and the panel's words:
##
## - **what the data puts in** (the feed's) is cleared on `restart`;
## - **what the reader sets** -- the platforms switched on, the record mode,
##   whether certified results are reused, the status filter and the query,
##   the open rows, the folded file groups, the selected test, the
##   keyboard's row and cell, a cancel waiting for confirmation -- is kept.
##
## **Reading.** `headline` (the Test Results headline's arms), `groups`
## (rows by file, in the catalog's order, never sorted), `platformHeads`,
## `notInCatalog` (Verification entries the catalog does not know),
## `notice`, `legend` (every mark, chip and backend the panel draws, with its
## meaning), and per cell `canRun` / `runAbsence`, `canRecord` /
## `recordAbsence`, `openMode` (the feed's rules, never restated).
##
## **Actions.** `run` and `record` (every test, one test, one cell), `cancel`
## then `confirmCancel` or `keepRunning`, `open` (an existing trace asks the
## host to open it; with none, or with Shift held, it starts a recorded run
## and asks the host once the trace is created), `setPlatform`,
## `setRecordMode`, `setReuse`, `setFilter`, `setQuery`, `toggleRow`,
## `toggleGroup`, `select`, and the keyboard's `focusNext`,
## `focusPrevious`, `stepCell`, `toggleFocused`, `runFocused`,
## `recordFocused`. Every write goes through the source's `submitAction`
## via the shared `ActionTracker`; a start the source refuses says why
## (`refusal`).
##
## **Host requests**, published as signals the story records:
## `requestedTrace` (a test's trace and where it opens) and `requestedFile`
## (a test's location).

import std/[sets, strutils]
import isonim/core/[signals, owner]
import isonim/viewmodel
import nim_agents/agent_harbor/[test_runs, trace_links]
import ./data_source
import ./action_tracker
import ./test_run_feed
import ./trace_placement

export test_run_feed, trace_placement, viewmodel, signals

const
  TestsPanelTitle* = "Test Results"
  TestsLoadingNotice* = "Loading tests\xE2\x80\xA6"
  TestsErrorTitle* = "Could not load the tests"
  TestsEmptyNotice* = "No tests found for this change."
  TestsEmptyHint* = "Tests appear once a platform has discovered them at this commit."
  NoPlatformNotice* = "No platform is offered by the fleet."
  NoPlatformHint* = "Executors offer platforms when they enroll."
  NoMatchNotice* = "No tests match the current filters"
  RunningHeadline* = "running\xE2\x80\xA6"
  NoTestsRanHeadline* = "run failed, no tests ran"
  NoTestsHeadline* = "no tests found"
  NoPlatformSwitchedOnText* = "No platform is switched on"
  NotStartedPrefix* = "Not started: "
  RecordingWord* = "recording\xE2\x80\xA6"
  Dot = " \xC2\xB7 "

type
  TestFilter* = enum
    tfAll = "All"
    tfFailing = "Failing"
    tfPassed = "Passed"
    tfNotRun = "Not run"
    tfRunning = "Running"

  RunScopeKind* = enum
    scAll = "all"        ## every listed test, on the platforms switched on
    scTest = "test"      ## one test, on the platforms switched on
    scCell = "cell"      ## one test on one platform

  RunScope* = object
    kind*: RunScopeKind
    testId*: string
    platform*: string    ## scCell: the platform key

  TestCellView* = object
    ## One test on one platform, as a cell and an opened row's sub-row draw it.
    cell*: TestCell
    platform*: string     ## the platform key
    label*: string        ## `Linux x86-64`
    statusWord*: string
    statusTitle*: string
      ## Why the status reads as it does, when a word alone does not say:
      ## a test the platform's run ended before reaching (`not run`).
    reusedTitle*: string  ## a reused result: the certificate, and that it did not run
    recordingWord*: string
      ## `recording…`, or the sentence for a recording that was not kept
    durationText*: string ## `12 ms`, "" when it has none (never for a reused result)
    runAbsence*, recordAbsence*: string
    recordWaiting*: bool
      ## Record waits behind this cell's Run, still being sent; its words
      ## are `recordAbsence` (`RecordWaitsForRunText`).
    open*: OpenMode
    openTitle*: string
    focused*: bool

  TestRowView* = object
    testId*, name*, file*, runner*: string
    line*: int
    status*: CellStatus   ## across the platforms switched on
    statusWord*: string
    milestones*: seq[string]   ## the plan's milestones whose Verification names it
    cells*: seq[TestCellView]  ## one per platform switched on, in the offer's order
    open*, selected*, focused*: bool

  TestGroupView* = object
    file*: string
    count*: int
    folded*: bool
    rows*: seq[TestRowView]

  PlatformHeadView* = object
    key*, label*: string
    features*: seq[string]
    enabled*: bool
    serveAbsence*: string    ## no backend serves it: the refusal
    recordReason*: string    ## Record is disabled on it for every runner: why
    catalogWord*: string     ## discovering, or why discovery failed
    runWord*: string         ## `queued on <backend>`, `running on …`, the counts, `cancelled`
    backend*, runner*: string
    backends*: seq[string]   ## every backend the fleet offers for it
    diagnostics*: seq[Diagnostic]
    counts*: TestCounts

  LegendEntry* = object
    term*, meaning*: string

  PendingOpen = object
    testId, platform, traceBefore: string

  TestRunsVM* = ref object of ViewModel
    feed: TestRunFeed
    ownsFeed: bool
    listener: int
    runId*: string
    serverOrigin*: string
    disabled: HashSet[string]
    openRows: HashSet[string]
    foldedGroups: HashSet[string]
    pendingOpens: seq[PendingOpen]
    readerRevision*: Signal[int]
    recordMode*: Signal[RecordMode]
    reuse*: Signal[bool]
    filter*: Signal[TestFilter]
    query*: Signal[string]
    selected*: Signal[string]
    focusRow*: Signal[string]
    focusCell*: Signal[int]
      ## The keyboard's cell in its row (-1: the row itself).
    confirming*: Signal[bool]
    shiftHeld*: Signal[bool]
    placement*: Signal[PlacementContext]
    refusal*: Signal[string]
      ## Why the last start was not (wholly) started; "" when it was.
    requestedTrace*: Signal[TraceRequest]
    traceRequests*: Signal[int]
    requestedFile*: Signal[string]
      ## The last location asked for (`<file>:<line>`); `fileRequests` counts.
    fileRequests*: Signal[int]

proc checkPendingOpens(vm: TestRunsVM)

proc newTestRunsVM*(source: AgentHarborDataSource; scope: ReviewScope; runId = "";
                    tracker: ActionTracker = nil; feed: TestRunFeed = nil;
                    serverOrigin = ""): TestRunsVM =
  ## The tests of `scope`'s change over `source`: through `feed` when one is
  ## given (a host that shows another surface over the same tests passes the
  ## same feed and tracker), else a feed of its own. `runId` shows that run
  ## in the header ("" for the session's newest). Nothing loads until `load`.
  withViewModel proc(dispose: proc()): TestRunsVM =
    let f = if feed.isNil: newTestRunFeed(source, scope, tracker) else: feed
    let vm = TestRunsVM(feed: f, ownsFeed: feed.isNil, runId: runId,
      serverOrigin: serverOrigin,
      disabled: initHashSet[string](), openRows: initHashSet[string](),
      foldedGroups: initHashSet[string](),
      readerRevision: createSignal(0), recordMode: createSignal(rmFailing),
      reuse: createSignal(true), filter: createSignal(tfAll), query: createSignal(""),
      selected: createSignal(""), focusRow: createSignal(""), focusCell: createSignal(-1),
      confirming: createSignal(false), shiftHeld: createSignal(false),
      placement: createSignal(PlacementContext()), refusal: createSignal(""),
      requestedTrace: createSignal(TraceRequest()), traceRequests: createSignal(0),
      requestedFile: createSignal(""), fileRequests: createSignal(0))
    vm.listener = f.listen(proc() = vm.checkPendingOpens())
    onCleanup proc() =
      f.unlisten(vm.listener)
      if vm.ownsFeed: f.close()
    vm

proc feed*(vm: TestRunsVM): TestRunFeed = vm.feed
proc tracker*(vm: TestRunsVM): ActionTracker = vm.feed.tracker

proc load*(vm: TestRunsVM) = vm.feed.load()

proc restart*(vm: TestRunsVM) =
  ## Loads again; what the reader set is kept.
  vm.feed.restart()

proc retry*(vm: TestRunsVM) = vm.feed.load()

proc bumpReader(vm: TestRunsVM) =
  vm.readerRevision.val = vm.readerRevision.val + 1

proc state*(vm: TestRunsVM): AsyncState = vm.feed.state.val
proc error*(vm: TestRunsVM): string = vm.feed.error.val

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc shownRun*(vm: TestRunsVM): TestRunState =
  ## Tracked: the run the header shows: `runId`'s, or the session's newest.
  if vm.runId.len > 0: vm.feed.run(vm.runId) else: vm.feed.latestRun

proc platformKeys*(vm: TestRunsVM): seq[string] =
  ## Tracked: every offered platform's key, in the offer's order.
  for offer in vm.feed.offers: result.add platformKey(offer.platform)

proc enabledPlatforms*(vm: TestRunsVM): seq[string] =
  ## Tracked: the platforms switched on, in the offer's order.
  discard vm.readerRevision.val
  for key in vm.platformKeys:
    if key notin vm.disabled: result.add key

proc isEnabled*(vm: TestRunsVM; platform: string): bool =
  discard vm.readerRevision.val
  platform notin vm.disabled

proc labelOf(vm: TestRunsVM; platform: string): string =
  let offer = vm.feed.offerOf(platform)
  if offer.platform.label.len > 0: offer.platform.label else: platformLabel(platform.split('+'))

proc canRun*(vm: TestRunsVM; testId, platform: string): bool =
  vm.feed.runAbsence(testId, platform).len == 0

proc runAbsence*(vm: TestRunsVM; testId, platform: string): string =
  vm.feed.runAbsence(testId, platform)

proc canRecord*(vm: TestRunsVM; testId, platform: string): bool =
  vm.feed.recordAbsence(testId, platform).len == 0

proc recordAbsence*(vm: TestRunsVM; testId, platform: string): string =
  vm.feed.recordAbsence(testId, platform)

proc openMode*(vm: TestRunsVM; testId, platform: string): OpenMode =
  vm.feed.openMode(testId, platform, vm.shiftHeld.val)

proc traceOf(vm: TestRunsVM; cell: TestCell): TraceReference =
  traceReferenceOf(cell.trace, vm.serverOrigin)

proc openTitle*(vm: TestRunsVM; testId, platform: string): string =
  ## Tracked: the open control's title: what it does, why it cannot, and
  ## where the trace opens (the placement sentence).
  let mode = vm.openMode(testId, platform)
  let head = case mode.kind
    of omOpenExisting: "Open the recorded trace. "
    of omRefreshAndOpen: "Record again, then open the new trace. "
    of omRecordAndOpen: "Record, then open the trace. "
  if mode.absence.len > 0: return head & mode.absence
  head & vm.placement.val.placementSentence(false)

proc durationText(cell: TestCell): string =
  if not cell.hasDuration or cell.reused: ""
  elif cell.durationMs >= 1000: $(cell.durationMs div 1000) & "." &
    $((cell.durationMs mod 1000) div 100) & " s"
  else: $cell.durationMs & " ms"

proc cellView(vm: TestRunsVM; cell: TestCell): TestCellView =
  result = TestCellView(cell: cell, platform: cell.platform,
                        label: vm.labelOf(cell.platform),
                        statusWord: statusWord(cell.status),
                        durationText: cell.durationText,
                        runAbsence: vm.runAbsence(cell.testId, cell.platform),
                        recordAbsence: vm.recordAbsence(cell.testId, cell.platform),
                        recordWaiting: vm.feed.recordWaiting(cell.testId, cell.platform),
                        open: vm.openMode(cell.testId, cell.platform),
                        openTitle: vm.openTitle(cell.testId, cell.platform))
  if cell.unreached: result.statusTitle = UnreachedText
  if cell.reused:
    result.reusedTitle = "Reused: a test certificate (" &
      (if cell.certificate.len > 0: cell.certificate else: "no reference") &
      ") shows it passed at this tree, so it was not run"
  case cell.recording
  of recRecording: result.recordingWord = RecordingWord
  of recDiscarded: result.recordingWord = RecordingDiscardedText
  else: discard

const RollupOrder = [tsErrored, tsFailed, tsCancelled, tsRunning, tsQueued,
                     tsPassed, tsSkipped, tsNotRun]

proc rollup(cells: openArray[TestCell]): CellStatus =
  var seen: set[CellStatus]
  for c in cells: seen.incl c.status
  for s in RollupOrder:
    if s in seen: return s
  tsNotRun

proc matchesFilter(status: CellStatus; filter: TestFilter): bool =
  case filter
  of tfAll: true
  of tfFailing: status in {tsFailed, tsErrored}
  of tfPassed: status == tsPassed
  of tfNotRun: status == tsNotRun
  of tfRunning: status in {tsRunning, tsQueued}

proc milestoneTags(vm: TestRunsVM): seq[(string, string)] =
  for j in vm.feed.joined:
    if j.testId.len > 0: result.add (j.testId, j.entry.milestoneId)

proc buildGroups(vm: TestRunsVM; applyFilters: bool): seq[TestGroupView] =
  let enabled = vm.enabledPlatforms
  let tags = vm.milestoneTags
  let query = vm.query.val.toLowerAscii
  let filter = vm.filter.val
  let focused = vm.focusRow.val
  let focusCell = vm.focusCell.val
  for test in vm.feed.tests:
    var cells: seq[TestCell]
    for c in vm.feed.cellsFor(test.id):
      if c.platform in enabled: cells.add c
    let status = rollup(cells)
    if applyFilters:
      if not status.matchesFilter(filter): continue
      if query.len > 0 and query notin test.name.toLowerAscii and
          query notin test.file.toLowerAscii and query notin test.id.toLowerAscii:
        continue
    var row = TestRowView(testId: test.id, name: test.name, file: test.file,
                          runner: test.runner, line: test.line, status: status,
                          statusWord: statusWord(status),
                          open: test.id in vm.openRows,
                          selected: test.id == vm.selected.val,
                          focused: test.id == focused)
    for (id, m) in tags:
      if id == test.id and m notin row.milestones: row.milestones.add m
    for i, c in cells:
      var v = vm.cellView(c)
      v.focused = row.focused and i == focusCell
      row.cells.add v
    var at = -1
    for i, g in result:
      if g.file == test.file: at = i
    if at < 0:
      result.add TestGroupView(file: test.file, folded: test.file in vm.foldedGroups)
      at = result.high
    inc result[at].count
    result[at].rows.add row

proc groups*(vm: TestRunsVM): seq[TestGroupView] =
  ## Tracked: the listed tests by file, in the catalog's order, after the
  ## filter and the query; a folded group keeps its rows (a host draws only
  ## its head).
  discard vm.readerRevision.val
  vm.buildGroups(applyFilters = true)

proc testCount*(vm: TestRunsVM): int =
  ## Tracked: every test the catalogs hold.
  vm.feed.tests.len

proc notInCatalog*(vm: TestRunsVM): seq[JoinedVerification] =
  ## Tracked: the plan's Verification entries no catalog test matches, each
  ## with why (no Run or Record for them).
  for j in vm.feed.joined:
    if j.testId.len == 0: result.add j

proc platformHeads*(vm: TestRunsVM): seq[PlatformHeadView] =
  ## Tracked: one head per offered platform, in the offer's order.
  discard vm.readerRevision.val
  let run = vm.shownRun
  for offer in vm.feed.offers:
    let key = platformKey(offer.platform)
    var head = PlatformHeadView(key: key, label: vm.labelOf(key),
                                features: offer.platform.features,
                                enabled: key notin vm.disabled,
                                serveAbsence: runAbsence(vm.feed.offers, offer.platform.features),
                                recordReason: recordAbsence(offer))
    for b in offer.backends: head.backends.add b.backend
    let read = vm.feed.catalogOf(key)
    if read.loaded:
      if read.error.len > 0:
        head.catalogWord = "Discovery failed on " & head.label & ": " & read.error
      elif read.catalog.state == csDiscovering:
        head.catalogWord = DiscoveringPrefix & head.label & "\xE2\x80\xA6"
      elif read.catalog.state == csFailed:
        head.catalogWord = "Discovery failed on " & head.label & ": " & read.catalog.reason
    else:
      head.catalogWord = DiscoveringPrefix & head.label & "\xE2\x80\xA6"
    for p in run.platformRuns:
      if platformKey(p.platform) == key:
        head.backend = p.backend
        head.runner = p.runner
        head.diagnostics = p.diagnostics
        head.counts = run.countsOf(key)
        head.runWord = case p.state
          of prsQueued: "queued on " & backendLabel(p.backend)
          of prsRunning: "running on " & backendLabel(p.backend) &
            (if p.runner.len > 0: " (" & p.runner & ")" else: "")
          of prsFinished: countsText(head.counts)
          of prsCancelled:
            let c = countsText(head.counts)
            if p.sawTestEvent and c.len > 0: "cancelled" & Dot & c else: "cancelled"
    result.add head

proc headline*(vm: TestRunsVM): string =
  ## Tracked: the Test Results headline's arms for the shown run: `running…`,
  ## the counts (`9 passed (3 reused) · 2 failed · 1 skipped`), `run failed,
  ## no tests ran`, `12 tests, not run yet`, `no tests found`; "" while
  ## loading or failed.
  if vm.state != asReady: return ""
  let n = vm.testCount
  if n == 0: return NoTestsHeadline
  let run = vm.shownRun
  if run.id.len == 0 or run.platformRuns.len == 0:
    return $n & (if n == 1: " test" else: " tests") & ", not run yet"
  if run.isActive: return RunningHeadline
  var ran = false
  for p in run.platformRuns:
    if p.sawTestEvent or p.hasTotals: ran = true
  if not ran: return NoTestsRanHeadline
  let counts = run.countsOf
  let text = countsText(counts)
  if text.len == 0: NoTestsRanHeadline else: text

proc notice*(vm: TestRunsVM): string =
  ## Tracked: the notice a view centres instead of rows (loading, empty, no
  ## platform, nothing matching); "" when it draws rows or the error block.
  case vm.state
  of asLoading, asIdle: TestsLoadingNotice
  of asError: ""
  of asReady:
    if vm.feed.offers.len == 0: NoPlatformNotice
    elif vm.testCount == 0:
      var discovering = false
      for c in vm.feed.catalogs:
        if not c.loaded or c.catalog.state == csDiscovering: discovering = true
      if discovering: "" else: TestsEmptyNotice
    elif vm.groups.len == 0: NoMatchNotice
    else: ""

proc hint*(vm: TestRunsVM): string =
  ## Tracked: what would fill an empty pane.
  case vm.notice
  of TestsEmptyNotice: TestsEmptyHint
  of NoPlatformNotice: NoPlatformHint
  else: ""

proc streamNotice*(vm: TestRunsVM): string =
  ## Tracked: `Lost the run's events; reconnecting…` while a stream is lost.
  vm.feed.notice

proc legend*(vm: TestRunsVM): seq[LegendEntry] =
  ## Tracked: what every status, chip and backend the panel draws means.
  for s in CellStatus:
    let meaning = case s
      of tsNotRun: "this platform has not run the test, or its run ended before reaching it"
      of tsQueued: "the platform's run has not started"
      of tsRunning: "the test is running"
      of tsPassed: "the test passed"
      of tsFailed: "the test failed"
      of tsSkipped: "the runner skipped the test"
      of tsErrored: "the test could not run to a result"
      of tsCancelled: "the run was cancelled before the test finished"
    result.add LegendEntry(term: statusWord(s), meaning: meaning)
  result.add LegendEntry(term: "reused",
    meaning: "passed: a test certificate proved it at this tree, so it was not run")
  result.add LegendEntry(term: RecordingWord, meaning: "a trace of the test is being recorded")
  result.add LegendEntry(term: NotDiscoveredText,
    meaning: "this platform's catalog does not hold the test")
  result.add LegendEntry(term: "record mark",
    meaning: "the platform can record a trace; without it, Record is disabled with the reason")
  var backends: seq[string]
  for offer in vm.feed.offers:
    for b in offer.backends:
      if b.backend notin backends: backends.add b.backend
  for b in backends:
    result.add LegendEntry(term: backendLabel(b),
      meaning: "the backend that runs the platform's tests")

# ---------------------------------------------------------------------------
# Header controls
# ---------------------------------------------------------------------------

proc scopeTests(vm: TestRunsVM; scope: RunScope): seq[string]
proc scopePlatforms(vm: TestRunsVM; scope: RunScope; recording: bool): seq[string]

proc headerTarget(vm: TestRunsVM; recording: bool): string =
  ## The target the header's Run (or Record) would send now; "" for none.
  let tests = vm.scopeTests(RunScope(kind: scAll))
  let platforms = vm.scopePlatforms(RunScope(kind: scAll), recording)
  if tests.len == 0 or platforms.len == 0: return ""
  vm.feed.startRequest(tests, platforms, rmNone, rpCertified).targetOf

proc inFlightOn(target: string; vm: TestRunsVM): bool =
  target.len > 0 and vm.tracker.inFlight(target)

proc runAllAbsence*(vm: TestRunsVM): string =
  ## Tracked: why the header's Run cannot be pressed; "" when it can.
  if vm.state != asReady: return TestsLoadingNotice
  if vm.feed.offers.len == 0: return NoPlatformNotice
  if vm.enabledPlatforms.len == 0: return NoPlatformSwitchedOnText
  if vm.testCount == 0: return TestsEmptyNotice
  for key in vm.enabledPlatforms:
    if not vm.feed.activeOn(key):
      # The same request is still being sent: a press now would send
      # nothing, so it says why rather than doing nothing.
      if vm.headerTarget(recording = false).inFlightOn(vm): return SendingText
      return ""
  RunInProgressOnPlatformText

proc recordSkipped*(vm: TestRunsVM): seq[(string, string)] =
  ## Tracked: the platforms switched on that the header's Record skips, each
  ## with why (no recorder there).
  for key in vm.enabledPlatforms:
    let why = recordAbsence(vm.feed.offerOf(key))
    if why.len > 0: result.add (vm.labelOf(key), why)

proc recordAllAbsence*(vm: TestRunsVM): string =
  ## Tracked: why the header's Record cannot be pressed; "" when it can. A
  ## Record whose request a Run still being sent already names waits behind
  ## it (`RecordWaitsForRunText`).
  let run = vm.runAllAbsence
  if run.len > 0 and run != SendingText: return run
  if vm.recordSkipped.len == vm.enabledPlatforms.len:
    return "No platform switched on can record"
  let target = vm.headerTarget(recording = true)
  if target.len > 0:
    let entry = vm.tracker.entryOf(target)
    if entry.status == astSubmitting:
      var records = false
      for (key, value) in entry.action.params:
        if key == "record" and value != $rmNone: records = true
      return (if records: SendingText else: RecordWaitsForRunText)
  ""

proc canCancel*(vm: TestRunsVM): bool =
  ## Tracked: the shown run is active.
  vm.shownRun.isActive

proc cancelAbsence*(vm: TestRunsVM): string =
  if vm.canCancel: "" else: "No run is in progress"

proc cancelQuestion*(vm: TestRunsVM): string =
  ## Tracked: `Cancel the run on 3 platforms?`.
  var n = 0
  for p in vm.shownRun.platformRuns:
    if p.isActive: inc n
  "Cancel the run on " & $n & (if n == 1: " platform?" else: " platforms?")

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc send(vm: TestRunsVM; action: OperatorAction): bool =
  vm.refusal.val = ""
  let target = vm
  vm.feed.submit(action, proc(entry: TrackedAction) =
    if entry.action.kind != oaStartTestRun: return
    case entry.status
    of astFailed: target.refusal.val = NotStartedPrefix & entry.reason
    of astConfirmed: target.refusal.val = entry.message
    else: discard)

proc scopeTests(vm: TestRunsVM; scope: RunScope): seq[string] =
  case scope.kind
  of scAll:
    for t in vm.feed.tests: result.add t.id
  else: result = @[scope.testId]

proc scopePlatforms(vm: TestRunsVM; scope: RunScope; recording: bool): seq[string] =
  ## The platforms a start for the scope asks for; none when it cannot run.
  var platforms: seq[string]
  case scope.kind
  of scCell:
    let why = if recording: vm.recordAbsence(scope.testId, scope.platform)
              else: vm.runAbsence(scope.testId, scope.platform)
    if why.len > 0: return @[]
    platforms = @[scope.platform]
  of scTest, scAll:
    for key in vm.enabledPlatforms:
      # An unservable platform is asked for, so the source refuses it by
      # name; an active one, or one that cannot record a recorded run, is
      # skipped.
      if vm.feed.activeOn(key): continue
      if recording and recordAbsence(vm.feed.offerOf(key)).len > 0 and
          runAbsence(vm.feed.offers, key.split('+')).len == 0:
        continue
      if scope.kind == scTest:
        let why = vm.runAbsence(scope.testId, key)
        if why.len > 0 and why != runAbsence(vm.feed.offers, key.split('+')): continue
      platforms.add key
  platforms

proc startOn(vm: TestRunsVM; scope: RunScope; recording: bool): bool =
  ## Sends a start for the scope on the platforms it may run on.
  let tests = vm.scopeTests(scope)
  if tests.len == 0: return false
  let platforms = vm.scopePlatforms(scope, recording)
  if platforms.len == 0: return false
  let action =
    if not recording:
      vm.feed.runRequest(tests, platforms,
                         (if vm.reuse.val: rpCertified else: rpNever))
    elif scope.kind == scAll:
      vm.feed.runRequest(tests, platforms, rpNever, vm.recordMode.val)
    else:
      vm.feed.recordRequest(tests, platforms)
  vm.send(action)

proc run*(vm: TestRunsVM; scope = RunScope(kind: scAll)): bool =
  ## Run: every listed test, one test, or one cell. False when nothing was
  ## sent.
  vm.startOn(scope, recording = false)

proc record*(vm: TestRunsVM; scope = RunScope(kind: scAll)): bool =
  ## Record: the header records in its mode (`failing`, `all`) on the
  ## platforms that can; a row or a cell records all it names. A recorded
  ## request never reuses.
  vm.startOn(scope, recording = true)

proc cancel*(vm: TestRunsVM) =
  ## Asks first: nothing is sent until `confirmCancel`.
  if vm.canCancel: vm.confirming.val = true

proc keepRunning*(vm: TestRunsVM) =
  vm.confirming.val = false

proc confirmCancel*(vm: TestRunsVM): bool =
  ## Sends the cancel the reader confirmed.
  if not vm.confirming.val: return false
  vm.confirming.val = false
  let run = vm.shownRun
  if not run.isActive: return false
  vm.send(vm.feed.cancelRequest(run.id))

proc publishTrace(vm: TestRunsVM; testId, platform: string; reference: TraceReference;
                  redirected = false) =
  var ctx = vm.placement.val
  if redirected: ctx.modifierHeld = not ctx.modifierHeld
  vm.requestedTrace.val = TraceRequest(reference: reference, testId: testId,
                                       platform: platform,
                                       destination: ctx.destinationOf(false))
  vm.traceRequests.val = vm.traceRequests.val + 1

proc open*(vm: TestRunsVM; testId, platform: string; redirected = false): bool =
  ## The open control. An existing trace asks the host to open it and runs
  ## nothing; with none, or with Shift held, it starts a recorded run of the
  ## test on the platform and asks the host once the trace is created.
  let mode = vm.openMode(testId, platform)
  if mode.absence.len > 0: return false
  let cell = vm.feed.cellOf(testId, platform)
  if mode.kind == omOpenExisting:
    vm.publishTrace(testId, platform, vm.traceOf(cell), redirected)
    return true
  if not vm.send(vm.feed.recordRequest([testId], [platform])): return false
  vm.pendingOpens.add PendingOpen(testId: testId, platform: platform,
                                  traceBefore: cell.trace)
  vm.checkPendingOpens()
  true

proc checkPendingOpens(vm: TestRunsVM) =
  ## A recorded run asked for by `open`: once its trace is created, the
  ## host is asked to open it; a recording not kept ends the wait.
  if vm.pendingOpens.len == 0: return
  var kept: seq[PendingOpen]
  for p in vm.pendingOpens:
    let cell = vm.feed.cellOf(p.testId, p.platform)
    if cell.recording == recRecorded and cell.trace.len > 0 and cell.trace != p.traceBefore:
      vm.publishTrace(p.testId, p.platform, vm.traceOf(cell))
    elif cell.recording == recDiscarded:
      discard
    else:
      kept.add p
  vm.pendingOpens = kept

proc waitingToOpen*(vm: TestRunsVM): int =
  ## How many opens wait for their recording.
  vm.pendingOpens.len

proc openLocation*(vm: TestRunsVM; testId: string) =
  ## Asks the host to open the test's location.
  let t = vm.feed.testOf(testId)
  var location = t.file
  let cell = vm.feed.cellsFor(testId)
  for c in cell:
    if c.location.file.len > 0:
      location = c.location.file & (if c.location.line > 0: ":" & $c.location.line else: "")
      break
  if location == t.file and t.line > 0: location.add ":" & $t.line
  if location.len == 0: return
  vm.requestedFile.val = location
  vm.fileRequests.val = vm.fileRequests.val + 1

proc setPlatform*(vm: TestRunsVM; platform: string; on: bool) =
  ## Switches a platform on or off (in view and in the next run).
  if on and platform in vm.disabled: vm.disabled.excl platform
  elif not on and platform notin vm.disabled: vm.disabled.incl platform
  else: return
  vm.bumpReader()

proc setRecordMode*(vm: TestRunsVM; mode: RecordMode) =
  if mode != rmNone: vm.recordMode.val = mode

proc setReuse*(vm: TestRunsVM; on: bool) = vm.reuse.val = on
proc setFilter*(vm: TestRunsVM; filter: TestFilter) = vm.filter.val = filter
proc setQuery*(vm: TestRunsVM; query: string) = vm.query.val = query.strip

proc toggleRow*(vm: TestRunsVM; testId: string) =
  if testId.len == 0: return
  if testId in vm.openRows: vm.openRows.excl testId else: vm.openRows.incl testId
  vm.bumpReader()

proc toggleGroup*(vm: TestRunsVM; file: string) =
  if file in vm.foldedGroups: vm.foldedGroups.excl file else: vm.foldedGroups.incl file
  vm.bumpReader()

proc select*(vm: TestRunsVM; testId: string) =
  ## Selects a test (opened from elsewhere): it is the keyboard's row, and a
  ## folded group holding it opens.
  vm.selected.val = testId
  vm.focusRow.val = testId
  vm.focusCell.val = -1
  let file = vm.feed.testOf(testId).file
  if file in vm.foldedGroups:
    vm.foldedGroups.excl file
    vm.bumpReader()

proc focusables*(vm: TestRunsVM): seq[string] =
  ## Tracked: the rows the keyboard moves over, in the order drawn (a folded
  ## group's rows are not drawn).
  for g in vm.groups:
    if g.folded: continue
    for r in g.rows: result.add r.testId

proc focusNext*(vm: TestRunsVM) =
  let rows = vm.focusables
  if rows.len == 0: return
  let i = rows.find(vm.focusRow.val)
  vm.focusRow.val = rows[if i < 0: 0 else: min(i + 1, rows.high)]
  vm.focusCell.val = -1

proc focusPrevious*(vm: TestRunsVM) =
  let rows = vm.focusables
  if rows.len == 0: return
  let i = rows.find(vm.focusRow.val)
  vm.focusRow.val = rows[if i < 0: rows.high else: max(i - 1, 0)]
  vm.focusCell.val = -1

proc stepCell*(vm: TestRunsVM; delta: int) =
  ## Moves the keyboard across its row's platform cells (-1: the row).
  if vm.focusRow.val.len == 0: return
  let n = vm.enabledPlatforms.len
  if n == 0: return
  vm.focusCell.val = clamp(vm.focusCell.val + delta, -1, n - 1)

proc focusedCell*(vm: TestRunsVM): string =
  ## The keyboard's cell's platform key ("" on the row).
  let i = vm.focusCell.val
  let enabled = vm.enabledPlatforms
  if i >= 0 and i < enabled.len: enabled[i] else: ""

proc toggleFocused*(vm: TestRunsVM) =
  ## `Enter`: on a cell, its open control; on a row, opens or closes it.
  let platform = vm.focusedCell
  if platform.len > 0: discard vm.open(vm.focusRow.val, platform)
  else: vm.toggleRow(vm.focusRow.val)

proc runFocused*(vm: TestRunsVM): bool =
  ## `r`: the keyboard's cell, or its row's test.
  if vm.focusRow.val.len == 0: return false
  let platform = vm.focusedCell
  if platform.len > 0:
    vm.run(RunScope(kind: scCell, testId: vm.focusRow.val, platform: platform))
  else:
    vm.run(RunScope(kind: scTest, testId: vm.focusRow.val))

proc recordFocused*(vm: TestRunsVM): bool =
  ## `R`: the keyboard's cell, or its row's test.
  if vm.focusRow.val.len == 0: return false
  let platform = vm.focusedCell
  if platform.len > 0:
    vm.record(RunScope(kind: scCell, testId: vm.focusRow.val, platform: platform))
  else:
    vm.record(RunScope(kind: scTest, testId: vm.focusRow.val))
