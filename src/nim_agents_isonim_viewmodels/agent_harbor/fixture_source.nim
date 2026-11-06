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
## Nim does not track inputs 2 and 3: a `nim c -r` with an unchanged command
## line and sources re-runs the previous binary. Inside this checkout the
## repo-root `config.nims` keys the nimcache on them (its FIXTURE SETS
## paragraph), so a switch rebuilds. A consumer that compiles this module with
## `-r` from elsewhere and switches sets through them needs the same, or
## `-d:agentHarborFixtures`, which is part of the command line.
##
## The files are embedded at compile time (`staticRead`), so the same binary
## or JS bundle answers identically on every run, with no file system or
## network at run time. That is what lets a StoryBook bundle and a native unit
## test read the very same bytes. The manifest lists every file; this module
## reads exactly the files it names and fails to compile if one is missing, so
## a fixture set and its manifest cannot drift apart unnoticed.

import std/[json, os, strutils, tables]
import nim_agents/agent_harbor/session_replay
import ./data_source

export data_source

const
  agentHarborFixtures {.strdefine.} = ""
    ## A fixture directory to embed instead of the default choice.
  repositoryRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  syntheticFixtureRoot = repositoryRoot / "fixtures" / "agent-harbor"
  privateFixtureRoot = repositoryRoot.parentDir / "codetracer-pm" / "design" /
    "agent-harbor-front-end" / "fixtures"
    ## The repo-root `config.nims` names the same path in its nimcache key.

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

# ---------------------------------------------------------------------------
# The working set and the initiatives
# ---------------------------------------------------------------------------
#
# A fixture set's `workingSets` name, each, the sessions an operator works
# with -- the ones a front-end shows as tabs -- among its captured sessions,
# and state what no server serves yet: the front-end each session was started
# from and the plan it was launched for. The plans' `initiative` entries name
# the initiative a server would list for each plan. Every set is coherent --
# never real and invented data in one story:
#
# - `scenario`: scenario runs (each shown at a stated moment of its history:
#   its end, right after the agent's first question, or after a number of
#   events) and the INVENTED plans they are launched for;
# - `real`: sessions of the fleet snapshot and the REAL plans, associated
#   only where the association is known (Agent Harbor reports none yet).
#
# `workingSet` and `initiativesOf` assemble these into the records a live
# source would decode from the wire, so the viewmodels cannot tell the two
# apart.

type
  WorkingSetKind* = enum
    wsScenario = "scenario"
    wsReal = "real"

proc planIsInvented(entry: JsonNode): bool =
  entry{"visibility"}.getStr == "invented"

proc planMatches(entry: JsonNode; kind: WorkingSetKind): bool =
  ## Which plans a set may hold: invented ones for the scenario set, real
  ## ones for the real set. The synthetic fixture set's plans are all
  ## invented and stand in for both.
  let visibility = entry{"visibility"}.getStr
  if visibility == "synthetic": true
  elif kind == wsScenario: visibility == "invented"
  else: visibility != "invented"

const
  WorkingSetSpacingMs = 7 * 60_000'i64
    ## Scenario runs carry no wall-clock time of their own (their events are
    ## timed from the run's start); they are placed this far apart before the
    ## capture's instant, the first entry earliest, so a front-end that
    ## orders by launch shows them in working-set order and ages read as a
    ## working day.

proc planInitiativeIds(source: FixtureDataSource): Table[string, (string, string)] =
  ## Plan file name -> (initiative id, campaign title).
  for entry in source.manifest{"plans"}.getElems:
    let id = entry{"initiative", "id"}.getStr
    if id.len > 0:
      result[entry{"name"}.getStr] = (id, entry{"campaign"}.getStr)

proc scenarioRunEntry(source: FixtureDataSource; name: string): JsonNode =
  for entry in source.manifest{"scenarioRuns"}.getElems:
    if entry{"name"}.getStr == name: return entry
  raise newException(KeyError, "the working set names a scenario run the set does not hold: " & name)

proc workingSet*(source: FixtureDataSource;
                 kind = wsScenario): FleetSnapshot =
  ## The working set `kind` as a snapshot, in working-set order. Raises
  ## `KeyError` / `ValueError` when the manifest names what the set lacks,
  ## or a plan the set may not hold.
  result = FleetSnapshot(capturedAtMs: source.capturedAtMs,
                         sourceLabel: (if kind == wsScenario: "scenario runs"
                                       else: "fleet sessions"))
  let plans = source.planInitiativeIds
  var planEntries = initTable[string, JsonNode]()
  for entry in source.manifest{"plans"}.getElems: planEntries[entry{"name"}.getStr] = entry
  var fleet: FleetSnapshot
  var fleetLoaded = false
  let entries = source.manifest{"workingSets", $kind}.getElems
  for i, entry in entries:
    var session: FleetSession
    case entry{"from"}.getStr
    of "scenario":
      let run = source.scenarioRunEntry(entry{"scenarioRun"}.getStr)
      let listed = fleetSessionFromJson(parseJson(source.files[run{"session"}.getStr]))
      let events = eventsOldestFirst(parseJson(source.files[run{"events"}.getStr]))
      let at = entry{"at"}
      let count =
        if at.isNil or (at.kind == JString and at.getStr == "end"): events.len
        elif at.kind == JInt: at.getInt
        elif at.kind == JString and at.getStr == "question":
          let questions = questionIndexes(events)
          if questions.len == 0:
            raise newException(ValueError, "scenario run " & run{"name"}.getStr &
                               " has no question to stop at")
          questions[0] + 1
        else:
          raise newException(ValueError, "unknown working-set moment " & $at)
      let startMs = source.capturedAtMs - int64(entries.len - i) * WorkingSetSpacingMs
      session = sessionAt(listed, events, count, startMs)
      # A scenario runs in a throw-away scratch workspace whose name is an id.
      session.workspaceName = ""
      session.labelSource = "scenario run " & run{"scenario"}.getStr
    of "fleet":
      if not fleetLoaded:
        source.loadFleet proc(answer: DataResult[FleetSnapshot]) =
          if not answer.ok: raise newException(ValueError, answer.error)
          fleet = answer.value
        fleetLoaded = true
      let id = entry{"sessionId"}.getStr
      var found = false
      for candidate in fleet.sessions:
        if candidate.id == id:
          session = candidate
          found = true
          break
      if not found:
        raise newException(KeyError, "the working set names a session the snapshot lacks: " & id)
    else:
      raise newException(ValueError, "unknown working-set source " & entry{"from"}.getStr)
    session.originFrontEnd = entry{"origin"}.getStr
    let plan = entry{"plan"}.getStr
    if plan.len > 0:
      if plan notin plans:
        raise newException(KeyError, "the working set names a plan with no initiative: " & plan)
      if not planEntries[plan].planMatches(kind):
        raise newException(ValueError, "the " & $kind & " working set names a plan it may not hold: " & plan)
      (session.planId, session.initiative) = plans[plan]
    result.sessions.add session
  result.total = result.sessions.len

proc initiativesOf*(source: FixtureDataSource; kind: WorkingSetKind): seq[Initiative] =
  ## The initiatives of the working set `kind`: its plans (invented for the
  ## scenario set, real for the real set), each with the set's sessions
  ## launched for it.
  var sessionPlans: seq[(string, string)]
  if not source.manifest{"workingSets", $kind}.isNil:
    for session in source.workingSet(kind).sessions:
      sessionPlans.add (session.id, session.planId)
  for entry in source.manifest{"plans"}.getElems:
    let meta = entry{"initiative"}
    if meta.isNil or meta{"id"}.getStr.len == 0 or not entry.planMatches(kind): continue
    block:
      let text = source.files[entry{"file"}.getStr]
      var initiative = Initiative(
        id: meta{"id"}.getStr, title: entry{"campaign"}.getStr,
        repository: meta{"repository"}.getStr, manager: meta{"manager"}.getStr,
        planPath: entry{"name"}.getStr,
        executiveSummary: planExecutiveSummary(text),
        progress: parseMilestoneFile(entry{"name"}.getStr, text))
      for (id, plan) in sessionPlans:
        if plan == initiative.id: initiative.sessionIds.add id
      # Through the proposed wire shape and back: what a live source would
      # decode is exactly what the views get.
      result.add initiativeFromJson(initiative.toJson)

method loadInitiatives*(source: FixtureDataSource; done: InitiativesCallback) =
  ## The real plans (the fixture source stands for a real server).
  answer[seq[Initiative]](done):
    source.initiativesOf(wsReal)

proc newWorkingSetDataSource*(kind = wsScenario;
                              fixtures = newFixtureDataSource()): SnapshotDataSource =
  ## The working set `kind` and its initiatives, served the way a live server
  ## would serve an operator's sessions and running plans: the scenario set
  ## (scenario runs and the invented plans they are launched for) or the real
  ## set (fleet sessions and the real plans). Never a mixture.
  let label = (if kind == wsScenario: "scenario runs with invented plans"
               else: "real fleet sessions and plans, ") &
              (if kind == wsReal: fixtures.label.replace("fleet snapshot, ", "") else: "")
  newSnapshotDataSource(fixtures.workingSet(kind), label, fixtures.initiativesOf(kind))
