## The fixture implementation of `AgentHarborDataSource`: it replays a
## fixture set -- a `manifest.json` and the files it lists -- captured from a
## real fleet and real tool runs, or synthesized in the same shapes.
##
## Two fixture sets exist:
##
## - the **synthetic** set, committed under `fixtures/agent-harbor/` in this
##   repository. Every name, id, prompt, repository and host in it is
##   invented; only the shapes are real (today's Agent Harbor wire types).
##   It is what public CI builds and tests against.
## - the **private** set of captured real data (a fleet snapshot, campaign
##   plans, branch diffs, test runs, scenario runs). It never enters this
##   repository; in a workspace it sits at
##   `../codetracer-pm/design/agent-harbor-front-end/fixtures`.
##
## Which set is embedded is decided at compile time, first match wins:
##
## 1. `-d:agentHarborFixtures=<dir>`;
## 2. the `AGENT_HARBOR_FIXTURES` environment variable: a directory, or the
##    word `synthetic` to force the committed set;
## 3. the private set, when its `manifest.json` exists beside this checkout;
## 4. the synthetic set.
##
## `AgentHarborFixtureSet` says which one a build embedded, so a story or a
## test can name it.
##
## The files are embedded at compile time (`staticRead`), so the same binary
## or JS bundle answers identically on every run, with no file system or
## network at run time. That is what lets a StoryBook bundle and a native unit
## test read the very same bytes. The manifest lists every file; this module
## reads exactly the files it names and fails to compile if one is missing, so
## a fixture set and its manifest cannot drift apart unnoticed.

import std/[json, os, strutils, tables]
import ./data_source

export data_source

const
  agentHarborFixtures {.strdefine.} = ""
    ## A fixture directory to embed instead of the default choice.
  repositoryRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  syntheticFixtureRoot = repositoryRoot / "fixtures" / "agent-harbor"
  privateFixtureRoot = repositoryRoot.parentDir / "codetracer-pm" / "design" /
    "agent-harbor-front-end" / "fixtures"

proc shellQuoted(path: string): string {.compileTime.} =
  ## POSIX single quoting, written out because `os.quoteShell` is not
  ## available when this module is compiled for the JS target.
  "'" & path.replace("'", "'\\''") & "'"

proc chooseFixtureRoot(): string {.compileTime.} =
  let fromEnv = getEnv("AGENT_HARBOR_FIXTURES")
  if agentHarborFixtures.len > 0:
    agentHarborFixtures
  elif fromEnv == "synthetic":
    syntheticFixtureRoot
  elif fromEnv.len > 0:
    fromEnv
  elif gorgeEx("test -f " & shellQuoted(privateFixtureRoot / "manifest.json")).exitCode == 0:
    privateFixtureRoot
  else:
    syntheticFixtureRoot

const
  fixtureRoot = chooseFixtureRoot()
  AgentHarborFixtureRoot* = fixtureRoot
    ## The directory the embedded fixture set was read from, at compile time.
  manifestText = staticRead(fixtureRoot / "manifest.json")
  AgentHarborFixtureSet* = parseJson(manifestText){"fixtureSet"}.getStr("unlabelled")
    ## `private` or `synthetic`: the `fixtureSet` the embedded manifest
    ## declares.

proc readFixtureFiles(): seq[(string, string)] {.compileTime.} =
  let manifest = parseJson(manifestText)
  for path, _ in manifest["files"].pairs:
    result.add((path, staticRead(fixtureRoot / path)))

const fixtureFiles = readFixtureFiles()

type
  FixtureDataSource* = ref object of AgentHarborDataSource
    ## Serves the committed captures. `failSessions` makes chosen sessions'
    ## event loads fail, for a story of a partially reachable fleet.
    manifest: JsonNode
    files: Table[string, string]
    capturedAtMs*: int64
    failSessions*: seq[string]

proc newFixtureDataSource*(): FixtureDataSource =
  result = FixtureDataSource(manifest: parseJson(manifestText))
  for (path, text) in fixtureFiles:
    result.files[path] = text
  result.capturedAtMs = parseIsoMs(result.manifest{"capturedAt"}.getStr)
  result.label = result.manifest{"fleet", "label"}.getStr("fleet snapshot")

proc fixtureText*(source: FixtureDataSource; path: string): string =
  ## The embedded text of one manifest file; raises `KeyError` for a path the
  ## manifest does not list.
  source.files[path]

proc fixturePaths*(source: FixtureDataSource): seq[string] =
  for path in source.files.keys: result.add(path)

proc manifest*(source: FixtureDataSource): JsonNode = source.manifest

proc capturedSessionIds*(source: FixtureDataSource): seq[string] =
  ## Sessions whose event history was captured, in manifest order.
  let events = source.manifest{"fleet", "events"}
  if not events.isNil:
    for id, _ in events.pairs: result.add(id)

template answer[T](done: untyped; body: untyped) =
  ## Runs `body` to build the value and answers once, turning a decoding
  ## failure into an error answer rather than an exception in the caller.
  var outcome: DataResult[T]
  try:
    let value: T = block:
      body
    outcome = success[T](value)
  except CatchableError as error:
    outcome = failure[T]("fixture decoding failed: " & error.msg)
  done(outcome)

method loadFleet*(source: FixtureDataSource; done: FleetCallback) =
  answer[FleetSnapshot](done):
    let path = source.manifest{"fleet", "sessions"}.getStr
    var snapshot = fleetSnapshotFromJson(parseJson(source.files[path]),
                                         source.capturedAtMs, source.label)
    # The label table: what the set knows of each session besides the wire
    # listing (its name, workspace, branch, initiative), for the sessions
    # whose listing withholds them.
    let labelsPath = source.manifest{"fleet", "labels"}
    if not labelsPath.isNil and labelsPath.getStr.len > 0:
      var labels = initTable[string, SessionLabel]()
      for (id, label) in sessionLabelsFromJson(parseJson(source.files[labelsPath.getStr])):
        labels[id] = label
      for session in snapshot.sessions.mitems:
        if session.id in labels: session.applyLabel(labels[session.id])
    # A failed session's reason, from its captured history: the listing's
    # recent events rarely carry the exit line a front-end shows.
    let histories = source.manifest{"fleet", "events"}
    for session in snapshot.sessions.mitems:
      if session.category == fcFailed and not histories.isNil and
          histories.hasKey(session.id):
        let history = sessionEventHistoryFromJson(session.id,
          parseJson(source.files[histories[session.id].getStr]))
        session.failureReason = failureReasonOf(history.events)
    snapshot

method loadLifecycle*(source: FixtureDataSource; done: LifecycleCallback) =
  answer[seq[LifecycleFrame]](done):
    parseLifecycleSse(source.files[source.manifest{"fleet", "lifecycle"}.getStr])

method loadSessionEvents*(source: FixtureDataSource; sessionId: string;
                          done: EventsCallback) =
  if sessionId in source.failSessions:
    done(failure[SessionEventHistory]("the server did not answer for session " &
                                      sessionId))
    return
  let path = source.manifest{"fleet", "events", sessionId}
  if path.isNil:
    done(failure[SessionEventHistory]("no events were captured for session " &
                                      sessionId))
    return
  answer[SessionEventHistory](done):
    sessionEventHistoryFromJson(sessionId, parseJson(source.files[path.getStr]))

method loadPlans*(source: FixtureDataSource; done: PlansCallback) =
  answer[seq[PlanFile]](done):
    var plans: seq[PlanFile]
    for entry in source.manifest{"plans"}.getElems:
      plans.add(PlanFile(name: entry{"name"}.getStr,
                         campaign: entry{"campaign"}.getStr,
                         text: source.files[entry{"file"}.getStr]))
    plans

method loadDiffs*(source: FixtureDataSource; done: DiffsCallback) =
  answer[seq[BranchDiff]](done):
    var diffs: seq[BranchDiff]
    for entry in source.manifest{"diffs"}.getElems:
      diffs.add(BranchDiff(name: entry{"name"}.getStr,
                           repository: entry{"repository"}.getStr,
                           baseRef: entry{"baseRef"}.getStr,
                           headRef: entry{"headRef"}.getStr,
                           baseCommit: entry{"baseCommit"}.getStr,
                           headCommit: entry{"headCommit"}.getStr,
                           filesChanged: entry{"filesChanged"}.getInt,
                           insertions: entry{"insertions"}.getInt,
                           deletions: entry{"deletions"}.getInt,
                           unifiedDiff: source.files[entry{"file"}.getStr]))
    diffs

method loadTestRuns*(source: FixtureDataSource; done: TestRunsCallback) =
  answer[seq[TestRunCapture]](done):
    var runs: seq[TestRunCapture]
    for entry in source.manifest{"testRuns"}.getElems:
      runs.add(TestRunCapture(
        name: entry{"name"}.getStr,
        description: entry{"description"}.getStr,
        runnerEventsJsonl: source.files[entry{"runnerEvents"}.getStr],
        testRunEventsJson: source.files[entry{"testRunEvents"}.getStr]))
    runs

method loadScenarioRuns*(source: FixtureDataSource;
                         done: ScenarioRunsCallback) =
  answer[seq[ScenarioRunCapture]](done):
    var runs: seq[ScenarioRunCapture]
    for entry in source.manifest{"scenarioRuns"}.getElems:
      runs.add(ScenarioRunCapture(
        name: entry{"name"}.getStr,
        scenario: entry{"scenario"}.getStr,
        sessionJson: source.files[entry{"session"}.getStr],
        eventsJson: source.files[entry{"events"}.getStr]))
    runs
