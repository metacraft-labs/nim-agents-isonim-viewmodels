## Invented session timelines for the static stories of the session activity
## timeline (`session_timeline_vm.nim`), as `synthetic_fleet.nim` holds the
## invented fleets: one session's events each, every name, path, command and
## line in them invented. Each one shows a state of the timeline no single
## playback moment shows:
##
## - `populated`: the default, a session with every group kind;
## - `short`: a few lines and no group;
## - `every-kind`: one event of each kind, none grouped;
## - `group-open`: `populated` with its shell group open;
## - `details`: an edit's diff, a command's output and a tool's redacted
##   arguments open;
## - `command-trace`: the command traces open -- a single command, a
##   three-stage pipeline with a failing stage, a long-running child, a child
##   that outlives its parent -- and a command that has no trace;
## - `running`: a command still running inside a group, and a streaming
##   thought;
## - `needs-input`: the agent waits on a question;
## - `failed`: a failed command in a group, and the failure the agent
##   stopped on;
## - `long`: about four hundred events over twelve turns, with gaps;
## - `reading-back`: the reader scrolled away and new lines arrived;
## - `focused`: a focused line;
## - `long-names`: long paths, commands and lines;
## - `empty`, `loading`, `error`, `unresolvable`: the states without lines;
## - `against-cards`: `populated` again, for a story that draws it beside the
##   card feed.
##
## `syntheticTimelineSource` serves one (a `TimelineDataSource` holding its
## events, or the pending and failing sources for loading and error), and
## `newSyntheticTimelineVM` builds the viewmodel a story shows, loaded, with
## the reader's state the fixture names already set.

import std/[json, strutils]
import ./data_source
import ./session_events
import ./session_timeline_vm

export session_timeline_vm

const
  SyntheticTimelineNames* = ["populated", "short", "every-kind", "group-open",
    "details", "command-trace", "running", "needs-input", "failed", "long",
    "reading-back", "focused", "long-names", "empty", "loading", "error",
    "unresolvable", "against-cards"]
    ## Every invented timeline, by name.
  TimelineSessionId* = "5ca1ab1e-0e01-4e00-8000-00000000e001"
    ## The session every invented timeline shows.
  TimelineErrorText* = "GET /api/v1/sessions/" & TimelineSessionId &
    "/events/history failed: the server closed the connection"
    ## The `error` timeline's reason.

type
  SyntheticTimeline* = object
    name*: string
    sessionId*: string
    events*: seq[JsonNode]
      ## The session's events, oldest first, stamped (µs since its start).
    later*: seq[JsonNode]
      ## Events that arrive after the reader scrolled away (`reading-back`).

  Events = object
    seconds: int
    list: seq[JsonNode]

proc add(e: var Events; body: JsonNode; after = 3) =
  ## `body`, `after` seconds after the event before it.
  e.seconds += after
  var event = body.copy
  event["timestamp"] = %(int64(e.seconds) * 1_000_000)
  e.list.add event

proc command(e: var Events; id, cmd: string; exitCode: int; output: string;
             trace: JsonNode = nil) =
  e.add commandCall(id, cmd)
  e.add toolResult(id, "runCmd", exitCode, output, trace)

proc populated(): seq[JsonNode] =
  ## Every group kind, and each break.
  var e: Events
  e.add statusEvent("running")
  e.add userInput("Make the upload client retry with jitter.")
  e.add thoughtEvent("Read the client and its tests before changing anything.")
  for path in ["src/upload/client.py", "src/upload/backoff.py",
               "tests/test_client.py", "tests/test_backoff.py"]:
    e.add fileRead(path)
  e.add searchCall("s1", "grep", "retry", "src/upload")
  e.add toolResult("s1", "grep", 0, "src/upload/client.py:41: for attempt in range(retries):")
  e.add modelRequest("invented-model-large", 12)
  e.add searchCall("s2", "rg", "time.sleep", "src")
  e.add toolResult("s2", "rg", 0, "src/upload/backoff.py:22: time.sleep(delay)")
  e.command("c1", "pytest -q tests/test_backoff.py", 0, "6 passed in 0.4s")
  e.command("c2", "pytest -q", 1, "1 failed, 17 passed in 14.1s")
  e.command("c3", "ruff check src/upload", 0, "All checks passed!")
  e.add agentQuestion("Use full jitter or equal jitter?", ["Full jitter", "Equal jitter"])
  e.add(userInput("Full jitter."), after = 30)
  e.add(sessionResumed(), after = 0)
  e.add fileEdit("src/upload/backoff.py", 18, 4, "Draw each delay up to the cap.")
  e.add diffEvent("src/upload/client.py", 10, 6,
    "@@ -38,6 +38,10 @@\n-        time.sleep(base * 2 ** attempt)\n" &
    "+        time.sleep(backoff.full_jitter(base, attempt, cap))\n")
  e.add fileEdit("tests/test_backoff.py", 12, 2, "Seed the jitter in tests.")
  for _ in 1 .. 3: e.add awaitingInput("claude-stop-hook")
  e.add agentReply("Retries now back off with full jitter; 18 tests pass.")
  e.list

proc short(): seq[JsonNode] =
  var e: Events
  e.add statusEvent("running")
  e.add userInput("What does the upload client do when the server returns 429?")
  e.add thoughtEvent("The answer is in the retry loop.")
  e.add fileRead("src/upload/client.py")
  e.add agentReply("It waits for the Retry-After header's delay, then retries up to five times.")
  e.list

proc everyKind(): seq[JsonNode] =
  ## One of each kind, separated so that none groups.
  var e: Events
  e.add statusEvent("running")
  e.add userInput("Show every kind of line.")
  e.add thoughtEvent("A thought.")
  e.add agentReply("An agent message.")
  e.add fileRead("src/upload/client.py")
  e.add planEvent([("Read", "completed"), ("Edit", "in_progress"), ("Test", "pending")], false)
  e.add searchCall("s1", "grep", "retry", "src")
  e.add toolResult("s1", "grep", 0, "src/upload/client.py:41")
  e.add modelRequest("invented-model-large", 8)
  e.command("c1", "pytest -q", 0, "18 passed")
  e.add harnessEvent("sub_agent", "A reviewer sub-agent started.")
  e.add fileEdit("src/upload/backoff.py", 3, 1, "One edit.")
  e.add harnessEvent("delegation", "Delegated the docs to a second agent.")
  e.add fileDeleted("src/upload/legacy_retry.py")
  e.add harnessEvent("orchestration", "Handed the review to the lead agent.")
  e.add toolCall("t1", "fetchDocs", %*{"url": "https://docs.example.invalid/retry",
                                       "api_token": "invented-not-a-secret"})
  e.add toolResult("t1", "fetchDocs", 0, "Retry-After: seconds or an HTTP date.")
  e.add agentQuestion("Keep the old behaviour behind a flag?", ["Yes", "No"])
  e.add sessionResumed()
  e.add awaitingInput("claude-stop-hook")
  e.add logLine("error: a failure the agent stops on", "error")
  e.add statusEvent("completed", "Every kind shown.")
  e.list

proc traces(): seq[JsonNode] =
  ## The command-trace states.
  var e: Events
  e.add statusEvent("running")
  e.add userInput("Run the checks and show me what ran.")
  e.command("single", "pytest -q tests/test_backoff.py", 0, "6 passed in 0.4s",
    commandTrace([tracedProcess(6101, 6100, ["pytest", "-q", "tests/test_backoff.py"],
                                0, 420, 0, stdout = "......\n6 passed in 0.4s\n",
                                exe = "/usr/bin/python3")],
                 "6 passed in 0.4s\n", %*{"PATH": "/usr/bin"}))
  e.command("pipeline", "pytest -q | tee test.log | tail -n 5", 1, "1 failed, 17 passed",
    commandTrace([
      tracedProcess(6202, 6201, ["pytest", "-q"], 0, 14_200, 1,
                    stdout = "FAILED tests/test_client.py::test_retry_waits_with_jitter\n",
                    stderr = "AssertionError: delay 0.0 not in (0.0, 2.0]\n",
                    exe = "/usr/bin/python3"),
      tracedProcess(6203, 6201, ["tee", "test.log"], 0, 14_210, 0),
      tracedProcess(6204, 6201, ["tail", "-n", "5"], 2, 14_215, 0,
                    stdout = "1 failed, 17 passed in 14.1s\n")],
      "1 failed, 17 passed in 14.1s\n",
      %*{"PATH": "/usr/bin", "UPLOAD_API_TOKEN": "invented-not-a-secret",
         "PYTHONHASHSEED": "0"}))
  e.command("server", "make serve-fixture & make smoke", 0, "smoke passed",
    commandTrace([
      tracedProcess(6302, 6301, ["make", "serve-fixture"], 0,
                    stdout = "listening on 127.0.0.1:8081\n"),
      tracedProcess(6303, 6301, ["make", "smoke"], 100, 3_400, 0,
                    stdout = "smoke passed\n")],
      "smoke passed\n", %*{"PATH": "/usr/bin"}))
  e.command("daemon", "nohup ./scripts/watch.sh &", 0, "",
    commandTrace([
      tracedProcess(6402, 6401, ["nohup", "./scripts/watch.sh"], 0, 30, 0),
      tracedProcess(6403, 6402, ["inotifywait", "-m", "src"], 20,
                    stdout = "src/ MODIFY client.py\n")],
      "", %*{"PATH": "/usr/bin"}))
  e.command("untraced", "git status --short", 0, " M src/upload/backoff.py")
  e.list

proc running(): seq[JsonNode] =
  var e: Events
  e.add statusEvent("running")
  e.add userInput("Run the slow integration tests.")
  e.command("c1", "pytest -q tests/unit", 0, "42 passed")
  e.add commandCall("c2", "pytest -q tests/integration --slow")
  e.add thoughtEvent("While the integration tests run, look at the timeout handling.")
  e.list

proc needsInput(): seq[JsonNode] =
  var e: Events
  e.add statusEvent("running")
  e.add userInput("Make retries configurable.")
  e.add fileRead("src/upload/config.py")
  e.add fileRead("src/upload/client.py")
  e.add agentQuestion("Read the retry count from the config file or from an environment variable?",
                      ["Config file", "Environment variable"])
  e.list

proc failedRun(): seq[JsonNode] =
  var e: Events
  e.add statusEvent("running")
  e.add userInput("Upgrade the HTTP library and run the tests.")
  e.command("c1", "pip install -U invented-http", 0, "Installed invented-http 3.0")
  e.command("c2", "pytest -q", 1, "12 failed, 6 passed")
  e.command("c3", "pytest -q --lf", 1, "12 failed")
  e.add agentFailure("the HTTP library's new API breaks every upload test; stopping")
  e.add statusEvent("failed", "The agent stopped: the upgrade breaks the upload tests.")
  e.list

proc longRun(): seq[JsonNode] =
  ## About four hundred events over twelve turns, with two long gaps.
  var e: Events
  e.add statusEvent("running")
  for turn in 1 .. 12:
    e.add(userInput("Turn " & $turn & ": continue with the next part of the upload rewrite."),
          after = (if turn in [5, 9]: 600 else: 20))
    e.add thoughtEvent("Plan for part " & $turn & ".")
    for f in 1 .. 6: e.add fileRead("src/upload/part" & $turn & "/module" & $f & ".py")
    e.add thoughtEvent("Search for the callers.")
    for s in 1 .. 4:
      e.add searchCall("s" & $turn & "-" & $s, "grep", "part" & $turn, "src")
      e.add toolResult("s" & $turn & "-" & $s, "grep", 0, "src/upload/part" & $turn & ".py:1")
    for c in 1 .. 5:
      e.command("c" & $turn & "-" & $c, "pytest -q tests/part" & $turn & "/test_" & $c & ".py",
                (if c == 3 and turn mod 4 == 0: 1 else: 0), "ok")
    for f in 1 .. 4:
      e.add fileEdit("src/upload/part" & $turn & "/module" & $f & ".py", f * 3, f, "Part " & $turn & ".")
    e.add planEvent([("Part " & $turn, "completed"), ("Next part", "pending")], true)
    for _ in 1 .. 2: e.add awaitingInput("claude-stop-hook")
    e.add agentReply("Part " & $turn & " is done.")
  e.list

proc longNames(): seq[JsonNode] =
  var e: Events
  e.add statusEvent("running")
  e.add userInput("Rename the retry helpers in the deeply nested compatibility layer and " &
                  "re-run every test that touches them, including the slow ones.")
  e.add fileRead("src/upload/compatibility/legacy_transport_adapters/" &
                 "http_one_point_one/retry_with_exponential_backoff_and_full_jitter.py")
  e.add fileRead("tests/upload/compatibility/legacy_transport_adapters/" &
                 "http_one_point_one/test_retry_with_exponential_backoff_and_full_jitter.py")
  e.command("c1", "pytest -q tests/upload/compatibility/legacy_transport_adapters " &
                  "--deselect tests/upload/compatibility/test_slow_paths.py::test_rate_limited_upload_retries",
            0, "211 passed")
  e.add fileEdit("src/upload/compatibility/legacy_transport_adapters/" &
                 "http_one_point_one/retry_with_exponential_backoff_and_full_jitter.py",
                 120, 87, "Renamed the helpers.")
  e.add agentReply("Renamed retry_with_exponential_backoff_and_full_jitter to full_jitter_retry " &
                   "in all forty-one modules of the compatibility layer; every test passes.")
  e.list

proc syntheticTimeline*(name: string): SyntheticTimeline =
  ## The invented timeline named `name`. Raises `ValueError` for an unknown
  ## name.
  result = SyntheticTimeline(name: name, sessionId: TimelineSessionId)
  case name
  of "populated", "group-open", "details", "focused", "against-cards":
    result.events = populated()
  of "short": result.events = short()
  of "every-kind": result.events = everyKind()
  of "command-trace": result.events = traces()
  of "running": result.events = running()
  of "needs-input": result.events = needsInput()
  of "failed": result.events = failedRun()
  of "long": result.events = longRun()
  of "reading-back":
    let all = populated()
    result.events = all[0 ..< 12]
    result.later = all[12 .. ^1]
  of "long-names": result.events = longNames()
  of "empty", "loading", "error", "unresolvable": discard
  else: raise newException(ValueError, "no invented timeline named " & name)

proc syntheticTimelineSource*(timeline: SyntheticTimeline): AgentHarborDataSource =
  ## A source that serves `timeline`: pending for `loading`, failing for
  ## `error`, one that does not hold the session for `unresolvable`, and its
  ## events otherwise.
  case timeline.name
  of "loading": newPendingDataSource()
  of "error": newFailingDataSource(TimelineErrorText)
  of "unresolvable":
    newSnapshotDataSource(FleetSnapshot(), label = "invented session list")
  else:
    newTimelineDataSource(@[(timeline.sessionId, timeline.events)],
                          label = "invented timeline: " & timeline.name)

proc firstLine(vm: SessionTimelineVM; kind: TimelineLineKind;
               itemKind = ""): TimelineLine =
  for line in vm.lines:
    if line.kind == kind and (itemKind.len == 0 or line.itemKind == itemKind):
      return line

proc newSyntheticTimelineVM*(name: string): SessionTimelineVM =
  ## The viewmodel a static story of `name` shows: loaded over
  ## `syntheticTimelineSource`, with the reader's state the timeline names
  ## set (open lines, focus, scrolled away with new lines). Call inside a
  ## reactive root.
  let timeline = syntheticTimeline(name)
  let source = syntheticTimelineSource(timeline)
  result = newSessionTimelineVM(source, timeline.sessionId)
  result.load()
  let vm = result
  case name
  of "group-open":
    vm.toggle(vm.firstLine(tlkGroup, "shell").id)
  of "details":
    for kind in ["edit", "shell"]:
      let group = vm.firstLine(tlkGroup, kind)
      vm.toggle(group.id)
    for line in vm.lines:
      if line.kind == tlkItem and line.level == 1 and
          (line.itemKind == "edit" and "client.py" in line.text or
           line.itemKind == "shell" and line.state == tisFailed):
        vm.toggle(line.id)
  of "command-trace":
    vm.toggle(vm.firstLine(tlkGroup, "shell").id)
    for line in vm.lines:
      if line.kind == tlkItem and line.itemKind == "shell": vm.toggle(line.id)
    for line in vm.lines:
      if line.kind == tlkTrace and line.expandable and
          ("failed" in line.text or "2 processes" in line.text):
        vm.toggle(line.id)
  of "running":
    vm.toggle(vm.firstLine(tlkGroup, "shell").id)
  of "focused":
    vm.setFocus(vm.firstLine(tlkGroup, "search").id)
  of "reading-back":
    vm.setFollow(false)
    vm.readAt(vm.firstLine(tlkGroup, "read").id)
    let snapshot = TimelineDataSource(source)
    for i, event in timeline.later:
      discard snapshot.sendFrame(eventFrame(timeline.sessionId, event,
                                            timeline.events.len + i + 1))
  else: discard
