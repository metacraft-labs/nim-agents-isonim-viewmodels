## `TestRunFeed`: what every surface that shows a change's tests on Agent
## Harbor's platforms reads, and the rules they share -- a helper of the
## viewmodels, as `ActionTracker` is, not a viewmodel of its own. The Tests
## panel (`test_runs_vm.nim`) composes one; so does any other surface that
## offers Run and Record on the same tests. A host that shows two of them
## passes both the same feed and the same tracker, so a press on one is seen
## on the other before the run it asks for exists.
##
## **Reads.** `load` asks the source for the platforms the fleet offers
## (`loadTestPlatforms`), each offered platform's catalog of the change's
## tests (`loadTestCatalog`, the change being the session's), the session's
## test runs (`loadSessionTestRuns`) and, when the scope names a task, the
## task's review record, whose Verification entries are joined with the
## catalog (nim-agents' `joinVerifications`). It subscribes to every run not
## finished (`subscribeTestRun`) and folds each event with nim-agents'
## `applyTestRunEvent`; the stream's loss and resumption set `notice`. A
## reset of the source (`subscribeResets`) loads again. The platforms and
## the runs are what the feed cannot do without: a failure of either is the
## feed's error. A catalog that fails is that platform's (`csFailed` with the
## reason); a record that cannot be read leaves the entries unjoined.
##
## **Rules**, one function each, every surface calling the same one:
##
## - `cellsFor(testId)`: one cell per offered platform, in the offer's
##   order, from the newest run that asked for the test on that platform
##   (not run when none did);
## - `runAbsence(testId, platform)`: why Run cannot be pressed there: no
##   backend serves the platform (nim-agents' `runAbsence`), its catalog
##   lacks the test (`not discovered`), a run is already active on it, or a
##   start that covers that test on that platform is still being sent
##   (`Sending…`); "" when it can;
## - `recordAbsence(testId, platform)`: the same, then nim-agents'
##   `recordAbsence` for the test's runner. A Record waits behind a Run of
##   the same test on the same platform that is still being sent (both are
##   starts of one target): it is then not merely disabled but waiting, and
##   says so (`recordWaiting`, `RecordWaitsForRunText`; a provisional
##   decision);
## - `openMode(testId, platform, shiftHeld)`: nim-agents' `openModeOf`; its
##   recording modes start a run, so they are also blocked for every reason
##   `recordAbsence` gives (a run active on the platform, a start being
##   sent).
##
## **Requests.** `runRequest` asks for tests on platforms with the record
## mode and reuse given (the panel's Run: `none`, reuse certified results by
## default); `recordRequest` asks to record them, `record=all`,
## `reuse=never`, since a recorded request never reuses. `submit` sends a
## request through the shared tracker; once the source confirms a start the
## feed reads the session's runs again and subscribes to the new one.
## `cancelRequest` cancels a run.
##
## The feed holds no presentation state: what the reader sets (the
## platforms switched on, filters, open rows) is each surface's.
##
## **Cost of a read.** A panel lists hundreds of tests on several platforms
## and asks these rules once per cell, so a read between two changes of the
## data must not redo the catalog's merge. The merged catalog (`tests`), its
## test-id index (`testOf`) and each platform's set of test ids (the `not
## discovered` rule) are built once per `generation` and reused until the
## data changes again.

import std/[sets, strutils, tables]
import isonim/core/signals
import isonim/viewmodel
import nim_agents/agent_harbor/[operator_actions, review_record]
import nim_agents/agent_harbor/test_runs
import ./data_source
import ./action_tracker

const
  SendingText* = "Sending\xE2\x80\xA6"
    ## A press whose action the source has not answered yet.
  RecordWaitsForRunText* = "Waiting for the Run on this platform, which is being sent"
    ## Record on a cell whose Run is still being sent: it waits behind it.
  StreamLostPrefix* = "Lost the run's events; reconnecting\xE2\x80\xA6"
  DiscoveringPrefix* = "Discovering tests on "

type
  CatalogRead* = object
    ## One offered platform's catalog as the feed holds it.
    platform*: TestPlatform
    loaded*: bool                 ## the source answered
    catalog*: PlatformCatalog
    error*: string                ## the read failed: why

  FeedListener* = proc() {.closure.}

  TestRunFeed* = ref object
    source: AgentHarborDataSource
    scope*: ReviewScope
    tracker: ActionTracker
    loadToken: int
    platformsLoaded, runsLoaded: bool
    offers: seq[PlatformOffer]
    catalogs: seq[CatalogRead]
    runs: seq[TestRunState]
    verifications: seq[VerificationEntry]
    subscriptions: seq[(string, Subscription[TestRunUpdate])]
    resets: Subscription[StreamReset]
    lost: seq[(string, string)]   ## run id, reason: streams lost and not resumed
    listeners: seq[(int, FeedListener)]
    nextListener: int
    revision*: Signal[int]
      ## Moves whenever the data changes.
    state*: Signal[AsyncState]
    error*: Signal[string]
    generation: int
      ## Moves with every change of the data, including the clearing a
      ## `load` does before any answer (which does not move `revision`):
      ## what the memoized reads below are keyed on.
    memoGeneration: int           ## the generation the memo was built at; -1: none
    memoTests: seq[CatalogTest]   ## `mergeCatalogs` of the held catalogs
    memoIndex: Table[string, int] ## test id -> its index in `memoTests`
    memoListed: Table[string, HashSet[string]]
      ## platform key -> the test ids its discovered catalog holds

proc newTestRunFeed*(source: AgentHarborDataSource; scope: ReviewScope;
                     tracker: ActionTracker = nil): TestRunFeed =
  ## A feed of the tests of `scope`'s change (its session; its task's plan
  ## for the Verification join, when it names one) over `source`; nothing
  ## loads until `load`.
  TestRunFeed(source: source, scope: scope,
              tracker: (if tracker.isNil: newActionTracker() else: tracker),
              revision: createSignal(0), state: createSignal(asIdle),
              error: createSignal(""), memoGeneration: -1)

proc tracker*(feed: TestRunFeed): ActionTracker = feed.tracker
proc source*(feed: TestRunFeed): AgentHarborDataSource = feed.source

proc listen*(feed: TestRunFeed; listener: FeedListener): int =
  ## Calls `listener` after every change of the feed's data; returns the id
  ## `unlisten` takes.
  inc feed.nextListener
  feed.listeners.add (feed.nextListener, listener)
  feed.nextListener

proc unlisten*(feed: TestRunFeed; id: int) =
  var kept: seq[(int, FeedListener)]
  for (i, l) in feed.listeners:
    if i != id: kept.add (i, l)
  feed.listeners = kept

proc changed(feed: TestRunFeed) =
  inc feed.generation
  feed.revision.val = feed.revision.val + 1
  let listeners = feed.listeners
  for (_, l) in listeners: l()

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

proc settleState(feed: TestRunFeed) =
  if feed.state.val == asError: return
  if feed.platformsLoaded and feed.runsLoaded: feed.state.val = asReady

proc fail(feed: TestRunFeed; error: string) =
  feed.error.val = error
  feed.state.val = asError

proc runIndex(feed: TestRunFeed; id: string): int =
  for i, run in feed.runs:
    if run.id == id: return i
  -1

proc subscribed(feed: TestRunFeed; id: string): bool =
  for (runId, s) in feed.subscriptions:
    if runId == id and s.active: return true
  false

proc setLost(feed: TestRunFeed; id, reason: string) =
  var kept: seq[(string, string)]
  for (r, why) in feed.lost:
    if r != id: kept.add (r, why)
  if reason.len > 0: kept.add (id, reason)
  feed.lost = kept

proc follow(feed: TestRunFeed; id: string) =
  ## Subscribes to the run's events, once.
  if feed.subscribed(id): return
  let f = feed
  let token = feed.loadToken
  let subscription = feed.source.subscribeTestRun(id,
    proc(update: DataResult[TestRunUpdate]): ProgressDelivery =
      if token != f.loadToken or not update.ok: return pdUnchanged
      let u = update.value
      case u.kind
      of truLost:
        f.setLost(id, (if u.reason.len > 0: u.reason else: "the stream closed"))
        f.changed()
        pdApplied
      of truResumed:
        f.setLost(id, "")
        f.changed()
        pdApplied
      of truEvent:
        let i = f.runIndex(id)
        if i < 0: return pdUnchanged
        var event = u.event
        if event.testRunId.len == 0: event.testRunId = id
        if f.runs[i].applyTestRunEvent(event):
          f.changed()
          pdApplied
        else: pdUnchanged)
  feed.subscriptions.add (id, subscription)

proc readRuns(feed: TestRunFeed; token: int) =
  let f = feed
  feed.source.loadSessionTestRuns(feed.scope.sessionId,
    proc(answer: DataResult[seq[TestRunState]]) =
      if token != f.loadToken: return
      if not answer.ok:
        f.fail(answer.error)
        f.changed()
        return
      f.runs = answer.value
      f.runsLoaded = true
      for run in f.runs:
        if run.isActive: f.follow(run.id)
      f.settleState()
      f.changed())

proc close*(feed: TestRunFeed) =
  ## Cancels every subscription; what a surface's disposal does.
  for (_, s) in feed.subscriptions: s.cancel()
  feed.subscriptions = @[]
  if not feed.resets.isNil: feed.resets.cancel()
  feed.resets = nil

proc restart*(feed: TestRunFeed)

proc load*(feed: TestRunFeed) =
  ## Reads the platforms, their catalogs, the runs and the record; `asLoading`
  ## until the platforms and the runs have answered. An answer to an older
  ## `load` is ignored.
  inc feed.loadToken
  let token = feed.loadToken
  for (_, s) in feed.subscriptions: s.cancel()
  feed.subscriptions = @[]
  feed.platformsLoaded = false
  feed.runsLoaded = false
  feed.offers = @[]
  feed.catalogs = @[]
  feed.runs = @[]
  feed.verifications = @[]
  feed.lost = @[]
  # The data was just cleared: nothing memoized before this may be read.
  inc feed.generation
  feed.error.val = ""
  feed.state.val = asLoading
  let f = feed
  if feed.resets.isNil or not feed.resets.active:
    feed.resets = feed.source.subscribeResets(
      proc(reset: DataResult[StreamReset]): ProgressDelivery =
        if not reset.ok: return pdUnchanged
        f.restart()
        pdApplied)
  feed.source.loadTestPlatforms(proc(answer: DataResult[seq[PlatformOffer]]) =
    if token != f.loadToken: return
    if not answer.ok:
      f.fail(answer.error)
      f.changed()
      return
    f.offers = answer.value
    f.platformsLoaded = true
    for offer in f.offers:
      f.catalogs.add CatalogRead(platform: offer.platform)
    for i, offer in f.offers:
      let at = i
      f.source.loadTestCatalog(f.scope.sessionId, offer.platform.features,
        proc(c: DataResult[PlatformCatalog]) =
          if token != f.loadToken or at >= f.catalogs.len: return
          f.catalogs[at].loaded = true
          if c.ok:
            f.catalogs[at].catalog = c.value
            # The catalog is the offered platform's, whatever the answer
            # spells its platform as.
            f.catalogs[at].catalog.platform = f.catalogs[at].platform
          else:
            f.catalogs[at].error = c.error
          f.changed())
    f.settleState()
    f.changed())
  feed.readRuns(token)
  if feed.scope.taskId.len > 0:
    feed.source.loadReviewRecord(feed.scope, proc(answer: DataResult[TaskReview]) =
      if token != f.loadToken or not answer.ok: return
      for m in answer.value.record.milestones:
        for v in m.verifications:
          var entry = v
          if entry.milestoneId.len == 0: entry.milestoneId = m.id
          f.verifications.add entry
      f.changed())

proc restart*(feed: TestRunFeed) =
  ## Loads again, as after a source's reset.
  feed.load()

proc refreshRuns*(feed: TestRunFeed) =
  ## Reads the session's runs again (after a confirmed start), keeping the
  ## rest; subscribes to every run not finished.
  feed.readRuns(feed.loadToken)

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc generation*(feed: TestRunFeed): int =
  ## Tracked: a number that moves with every change of the feed's data and
  ## only then; a surface keys what it builds from the feed on it.
  discard feed.revision.val
  feed.generation

proc memoize(feed: TestRunFeed) =
  ## Builds the merged catalog, its index and each platform's listed ids,
  ## unless they were already built at this generation.
  if feed.memoGeneration == feed.generation: return
  var held: seq[PlatformCatalog]
  var seen = initHashSet[string]()
  feed.memoListed = initTable[string, HashSet[string]]()
  for c in feed.catalogs:
    let usable = c.loaded and c.error.len == 0
    if usable: held.add c.catalog
    # A platform's rule reads its first catalog, as `catalogOf` does.
    let key = platformKey(c.platform)
    if seen.containsOrIncl(key): continue
    if usable and c.catalog.state == csDiscovered:
      var ids = initHashSet[string]()
      for t in c.catalog.tests: ids.incl t.id
      feed.memoListed[key] = ids
  feed.memoTests = mergeCatalogs(held)
  feed.memoIndex = initTable[string, int]()
  for i, t in feed.memoTests: feed.memoIndex[t.id] = i
  feed.memoGeneration = feed.generation

proc offers*(feed: TestRunFeed): seq[PlatformOffer] =
  ## Tracked: the platforms the fleet offers, in its order.
  discard feed.revision.val
  feed.offers

proc catalogs*(feed: TestRunFeed): seq[CatalogRead] =
  ## Tracked: each offered platform's catalog read, in the offer's order.
  discard feed.revision.val
  feed.catalogs

proc runs*(feed: TestRunFeed): seq[TestRunState] =
  ## Tracked: the session's runs, oldest first.
  discard feed.revision.val
  feed.runs

proc run*(feed: TestRunFeed; id: string): TestRunState =
  ## Tracked: the run `id` (an empty state when the feed holds none).
  discard feed.revision.val
  let i = feed.runIndex(id)
  if i >= 0: feed.runs[i] else: TestRunState()

proc latestRun*(feed: TestRunFeed): TestRunState =
  ## Tracked: the newest run (an empty state when there is none).
  discard feed.revision.val
  if feed.runs.len > 0: feed.runs[^1] else: TestRunState()

proc offerOf*(feed: TestRunFeed; platform: string): PlatformOffer =
  ## The offer of the platform key `platform` (an empty offer when the fleet
  ## does not offer it).
  for offer in feed.offers:
    if platformKey(offer.platform) == platform: return offer
  PlatformOffer(platform: testPlatform(platform.split('+')))

proc catalogOf*(feed: TestRunFeed; platform: string): CatalogRead =
  for c in feed.catalogs:
    if platformKey(c.platform) == platform: return c
  CatalogRead(platform: testPlatform(platform.split('+')))

proc tests*(feed: TestRunFeed): seq[CatalogTest] =
  ## Tracked: every test any platform's catalog holds, once, in the order
  ## first seen (the offer's order, then each catalog's), with the platforms
  ## that hold it.
  ## Built once per generation.
  discard feed.revision.val
  feed.memoize()
  feed.memoTests

proc testOf*(feed: TestRunFeed; testId: string): CatalogTest =
  ## Tracked: the merged catalog's test `testId` (one with only its id and
  ## runner when no catalog holds it); a lookup.
  discard feed.revision.val
  feed.memoize()
  let i = feed.memoIndex.getOrDefault(testId, -1)
  if i >= 0: feed.memoTests[i] else: CatalogTest(id: testId, runner: runnerOf(testId))

proc joined*(feed: TestRunFeed): seq[JoinedVerification] =
  ## Tracked: the plan's Verification entries, each with the catalog test it
  ## names (`joinVerifications`), in the plan's order.
  discard feed.revision.val
  joinVerifications(feed.tests, feed.verifications)

proc joined*(feed: TestRunFeed; entry: VerificationEntry): JoinedVerification =
  ## The join's answer for one entry.
  joinVerifications(feed.tests, [entry])[0]

proc cellsFor*(feed: TestRunFeed; testId: string): seq[TestCell] =
  ## Tracked: one cell per offered platform, in the offer's order: the cell
  ## of the newest run that asked for the test on that platform, or not run.
  discard feed.revision.val
  for offer in feed.offers:
    let key = platformKey(offer.platform)
    var found = false
    for i in countdown(feed.runs.high, 0):
      if feed.runs[i].hasCell(key, testId):
        result.add feed.runs[i].cell(key, testId)
        found = true
        break
    if not found:
      result.add TestCell(testId: testId, platform: key, status: tsNotRun)

proc cellOf*(feed: TestRunFeed; testId, platform: string): TestCell =
  ## Tracked: the cell of `testId` on the platform key `platform`.
  for c in feed.cellsFor(testId):
    if c.platform == platform: return c
  TestCell(testId: testId, platform: platform, status: tsNotRun)

proc activeOn*(feed: TestRunFeed; platform: string): bool =
  ## Tracked: whether a run of the session is active on the platform.
  discard feed.revision.val
  for run in feed.runs:
    for p in run.platformRuns:
      if platformKey(p.platform) == platform and p.isActive: return true
  false

proc sending*(feed: TestRunFeed; testId, platform: string): bool =
  ## Tracked: whether a start that covers `testId` on `platform` is still
  ## being sent, from any surface over the same tracker.
  for entry in feed.tracker.submitting:
    let a = entry.action
    if a.kind != oaStartTestRun: continue
    if testId notin a.choices: continue
    for (key, value) in a.params:
      if key == "platform" and platformKey(value.split('+')) == platform: return true
  false

proc runSending*(feed: TestRunFeed; testId, platform: string): bool =
  ## Tracked: whether a Run (a start that records nothing) covering `testId`
  ## on `platform` is still being sent.
  for entry in feed.tracker.submitting:
    let a = entry.action
    if a.kind != oaStartTestRun or testId notin a.choices: continue
    var records = false
    for (key, value) in a.params:
      if key == "record" and value != $rmNone: records = true
    if records: continue
    for (key, value) in a.params:
      if key == "platform" and platformKey(value.split('+')) == platform: return true
  false

proc sendingOn*(feed: TestRunFeed; platform: string): bool =
  ## Tracked: whether any start naming `platform` is still being sent.
  for entry in feed.tracker.submitting:
    let a = entry.action
    if a.kind != oaStartTestRun: continue
    for (key, value) in a.params:
      if key == "platform" and platformKey(value.split('+')) == platform: return true
  false

proc notice*(feed: TestRunFeed): string =
  ## Tracked: `Lost the run's events; reconnecting…` while a run's stream is
  ## lost; "" otherwise.
  discard feed.revision.val
  if feed.lost.len > 0: StreamLostPrefix else: ""

proc lostReason*(feed: TestRunFeed): string =
  discard feed.revision.val
  if feed.lost.len > 0: feed.lost[0][1] else: ""

proc catalogAbsence(feed: TestRunFeed; testId, platform: string): string =
  ## `not discovered` unless the platform's catalog was read, discovered,
  ## and holds the test.
  feed.memoize()
  if platform in feed.memoListed and testId in feed.memoListed[platform]: ""
  else: NotDiscoveredText

proc runAbsence*(feed: TestRunFeed; testId, platform: string): string =
  ## Tracked: why Run cannot be pressed for `testId` on `platform`; "" when
  ## it can (see the module comment).
  discard feed.revision.val
  let served = runAbsence(feed.offers, platform.split('+'))
  if served.len > 0: return served
  let listed = feed.catalogAbsence(testId, platform)
  if listed.len > 0: return listed
  if feed.activeOn(platform): return RunInProgressOnPlatformText
  if feed.sending(testId, platform): return SendingText
  ""

proc recordAbsence*(feed: TestRunFeed; testId, platform: string): string =
  ## Tracked: why Record cannot be pressed for `testId` on `platform`; the
  ## run's reasons first, then the platform's recorders for the test's
  ## runner.
  let run = feed.runAbsence(testId, platform)
  if run == SendingText and feed.runSending(testId, platform): return RecordWaitsForRunText
  if run.len > 0: return run
  recordAbsence(feed.offerOf(platform), feed.testOf(testId).runner)

proc recordWaiting*(feed: TestRunFeed; testId, platform: string): bool =
  ## Tracked: whether Record on the cell waits behind its Run, still being
  ## sent (its words: `RecordWaitsForRunText`).
  feed.recordAbsence(testId, platform) == RecordWaitsForRunText

proc openMode*(feed: TestRunFeed; testId, platform: string; shiftHeld: bool): OpenMode =
  ## Tracked: what the open control does on the cell now (`openModeOf`); its
  ## recording modes are also blocked while a start covering the cell is
  ## being sent.
  let cell = feed.cellOf(testId, platform)
  var offerCell = cell
  if offerCell.runner.len == 0: offerCell.runner = feed.testOf(testId).runner
  result = openModeOf(offerCell, feed.offerOf(platform), shiftHeld)
  if result.kind != omOpenExisting and result.absence.len == 0:
    # A recording mode starts a run: the platform's reasons not to start
    # one (a run active there, a start still sending, …) are its too.
    result.absence = feed.recordAbsence(testId, platform)

# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

proc startRequest*(feed: TestRunFeed; tests, platforms: openArray[string];
                   record: RecordMode; reuse: ReusePolicy): OperatorAction =
  ## A start of `tests` on the platform keys `platforms` with the record mode
  ## and reuse given.
  startTestRun(feed.scope.sessionId, @tests, @platforms, $record,
               (if record != rmNone: $rpNever else: $reuse))

proc runRequest*(feed: TestRunFeed; tests, platforms: openArray[string];
                 reuse = rpCertified; record = rmNone): OperatorAction =
  ## The panel's Run: no recording unless `record` asks for one, and reuse
  ## as given (certified results by default). A request that records never
  ## reuses.
  feed.startRequest(tests, platforms, record, reuse)

proc recordRequest*(feed: TestRunFeed; tests, platforms: openArray[string]): OperatorAction =
  ## Record: `record=all`, `reuse=never` (a recorded request never reuses).
  feed.startRequest(tests, platforms, rmAll, rpNever)

proc cancelRequest*(feed: TestRunFeed; runId: string): OperatorAction =
  cancelTestRun(runId, feed.scope.sessionId)

proc submit*(feed: TestRunFeed; action: OperatorAction;
             done: proc(entry: TrackedAction) {.closure.} = nil): bool =
  ## Sends `action` through the shared tracker. False, and nothing is sent,
  ## while the same request is still being sent. A confirmed start or
  ## cancel makes the feed read the session's runs again.
  let f = feed
  feed.tracker.submit(feed.source, action, proc(entry: TrackedAction) =
    if entry.status == astConfirmed and
        entry.action.kind in {oaStartTestRun, oaCancelTestRun}:
      f.refreshRuns()
    if not done.isNil: done(entry))

proc platformsOf*(action: OperatorAction): seq[string] =
  ## The platform keys a start names.
  for (key, value) in action.params:
    if key == "platform": result.add platformKey(value.split('+'))

proc distinctTests*(tests: openArray[CatalogTest]): seq[string] =
  ## The ids, once each, in order.
  var seen = initHashSet[string]()
  for t in tests:
    if not seen.containsOrIncl(t.id): result.add t.id
