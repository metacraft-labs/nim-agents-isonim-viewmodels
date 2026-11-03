## The data-source seam of the Agent Harbor viewmodels.
##
## Every Agent Harbor viewmodel in this package reads its data through an
## `AgentHarborDataSource`, never from a client or a file directly. Three
## kinds of source implement it:
##
## - the fixture source (`fixture_source.nim`), which replays data captured
##   from a real fleet and from real tool runs, so prototypes and tests are
##   deterministic;
## - the state sources below (`newPendingDataSource`, `newFailingDataSource`,
##   `newSnapshotDataSource`), which produce the states no capture can show:
##   a load that has not answered, a load that failed, an empty or synthetic
##   fleet;
## - later, a live source over `nim-agent-harbor`'s typed client. It answers
##   the same calls from the network; a viewmodel built on this seam does not
##   change when it is swapped in.
##
## Each load is asynchronous by contract: the source calls `done` exactly once,
## possibly before the load call returns (the fixture source does), possibly
## much later (a live source will), and possibly never (the pending source,
## which is what a hung server looks like). A viewmodel must therefore show a
## loading state between the call and the answer, and must not assume the
## answer arrives inside the call.
##
## Base methods answer with an error naming the missing capability, so a
## source that serves only part of the surface fails loudly and visibly
## rather than rendering an empty panel that looks like an empty fleet.

import ./records

export records

type
  DataResult*[T] = object
    ## The answer to one load: a value, or the reason there is none.
    ok*: bool
    value*: T
    error*: string

  PlanFile* = object
    ## A milestone plan of a running campaign: the file's own text, unparsed.
    name*: string          ## file name, e.g. `….milestones.org`
    campaign*: string      ## human label of the campaign it plans
    text*: string

  BranchDiff* = object
    ## A branch's change against its base, as `git diff` prints it.
    name*: string
    repository*: string    ## repository label (not a URL)
    baseRef*: string
    headRef*: string
    baseCommit*: string
    headCommit*: string
    filesChanged*: int
    insertions*: int
    deletions*: int
    unifiedDiff*: string   ## the patch text (https://git-scm.com/docs/diff-format)

  TestRunCapture* = object
    ## One test run, kept in two shapes: the events the runner emitted
    ## (`ct test run --events` JSON lines) and the same run in the test-run
    ## event shape Agent Harbor's front-ends consume.
    name*: string
    description*: string
    runnerEventsJsonl*: string
    testRunEventsJson*: string

  ScenarioRunCapture* = object
    ## What an Agent Harbor server served while an agent ran a scenario file:
    ## the session as listed, and the session's event stream.
    name*: string
    scenario*: string      ## scenario file name
    sessionJson*: string
    eventsJson*: string

  FleetCallback* = proc(answer: DataResult[FleetSnapshot]) {.closure.}
  LifecycleCallback* = proc(answer: DataResult[seq[LifecycleFrame]]) {.closure.}
  EventsCallback* = proc(answer: DataResult[SessionEventHistory]) {.closure.}
  PlansCallback* = proc(answer: DataResult[seq[PlanFile]]) {.closure.}
  DiffsCallback* = proc(answer: DataResult[seq[BranchDiff]]) {.closure.}
  TestRunsCallback* = proc(answer: DataResult[seq[TestRunCapture]]) {.closure.}
  ScenarioRunsCallback* = proc(answer: DataResult[seq[ScenarioRunCapture]]) {.closure.}

  AgentHarborDataSource* = ref object of RootObj
    ## The interface. `label` names the source in a panel's chrome ("fleet
    ## snapshot, 2026-11-03 18:40 UTC", "live: <server>").
    label*: string

proc success*[T](value: T): DataResult[T] =
  DataResult[T](ok: true, value: value)

proc failure*[T](error: string): DataResult[T] =
  DataResult[T](ok: false, error: error)

proc unsupported(source: AgentHarborDataSource; what: string): string =
  "the data source '" & source.label & "' does not provide " & what

method loadFleet*(source: AgentHarborDataSource; done: FleetCallback) {.base.} =
  ## The session listing (`GET /api/v1/sessions`).
  done(failure[FleetSnapshot](source.unsupported("the session list")))

method loadLifecycle*(source: AgentHarborDataSource;
                      done: LifecycleCallback) {.base.} =
  ## The lifecycle feed, as frames (`GET /api/v1/session-lifecycle/events`).
  done(failure[seq[LifecycleFrame]](source.unsupported("the lifecycle feed")))

method loadSessionEvents*(source: AgentHarborDataSource; sessionId: string;
                          done: EventsCallback) {.base.} =
  ## One session's event history (`GET /api/v1/sessions/{id}/events/history`).
  done(failure[SessionEventHistory](source.unsupported("session events")))

method loadPlans*(source: AgentHarborDataSource; done: PlansCallback) {.base.} =
  done(failure[seq[PlanFile]](source.unsupported("campaign plans")))

method loadDiffs*(source: AgentHarborDataSource; done: DiffsCallback) {.base.} =
  done(failure[seq[BranchDiff]](source.unsupported("branch diffs")))

method loadTestRuns*(source: AgentHarborDataSource;
                     done: TestRunsCallback) {.base.} =
  done(failure[seq[TestRunCapture]](source.unsupported("test runs")))

method loadScenarioRuns*(source: AgentHarborDataSource;
                         done: ScenarioRunsCallback) {.base.} =
  done(failure[seq[ScenarioRunCapture]](source.unsupported("scenario runs")))

# ---------------------------------------------------------------------------
# State sources: the states no capture shows
# ---------------------------------------------------------------------------

type
  PendingDataSource* = ref object of AgentHarborDataSource
    ## Never answers: a server that accepted the request and has not replied.
    ## Holds the callbacks so a test can prove none was called.
    pendingFleet*: seq[FleetCallback]

  FailingDataSource* = ref object of AgentHarborDataSource
    ## Answers every load with the same error.
    error*: string

  SnapshotDataSource* = ref object of AgentHarborDataSource
    ## Answers the session list with a given snapshot (an empty fleet, or a
    ## synthetic one larger than any capture).
    snapshot*: FleetSnapshot

proc newPendingDataSource*(label = "waiting for the server"): PendingDataSource =
  PendingDataSource(label: label)

method loadFleet*(source: PendingDataSource; done: FleetCallback) =
  source.pendingFleet.add(done)

method loadLifecycle*(source: PendingDataSource; done: LifecycleCallback) =
  discard

method loadSessionEvents*(source: PendingDataSource; sessionId: string;
                          done: EventsCallback) =
  discard

proc newFailingDataSource*(error: string;
                           label = "unreachable server"): FailingDataSource =
  FailingDataSource(label: label, error: error)

method loadFleet*(source: FailingDataSource; done: FleetCallback) =
  done(failure[FleetSnapshot](source.error))

method loadLifecycle*(source: FailingDataSource; done: LifecycleCallback) =
  done(failure[seq[LifecycleFrame]](source.error))

method loadSessionEvents*(source: FailingDataSource; sessionId: string;
                          done: EventsCallback) =
  done(failure[SessionEventHistory](source.error))

proc newSnapshotDataSource*(snapshot: FleetSnapshot;
                            label = "synthetic fleet"): SnapshotDataSource =
  SnapshotDataSource(label: label, snapshot: snapshot)

method loadFleet*(source: SnapshotDataSource; done: FleetCallback) =
  done(success(source.snapshot))
