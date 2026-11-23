## The session activity timeline's viewmodel (`SessionTimelineVM`), over the
## seam's production sources: its states (loading, empty, error, a session
## that cannot be loaded), the lines it publishes and their roles, drill-down
## to level 3, the reader's state across new events and restarts, the count
## of unseen items, the anchor a host keeps still, the filter, and the
## invented timelines its static stories show (`synthetic_timelines.nim`).
##
## No test doubles: the sources are the seam's own -- `TimelineDataSource`
## (given events, and frames the test sends through it), `PendingDataSource`,
## `FailingDataSource` and `PlaybackDataSource` over the synthetic
## `session-run` scenario on IsoNim's `TestClock`. Expected lines are written
## out by hand from the events each test sends, never computed through the
## fold.

import std/[json, sequtils, sets, strutils, unittest]
import isonim/core/[owner, signals, clock]
import nim_agents_isonim_viewmodels
import nim_agents/agent_harbor/trace_links

const
  Session = "5ca1ab1e-0f01-4f00-8000-00000000f001"
  Other = "5ca1ab1e-0f02-4f00-8000-00000000f002"
  Times = " \xC3\x97"
  Minus = "\xE2\x88\x92"

proc stamp(seconds: int; body: JsonNode): JsonNode =
  result = body.copy
  result["timestamp"] = %(int64(seconds) * 1_000_000)

proc sourceWith(events: openArray[JsonNode]): TimelineDataSource =
  newTimelineDataSource(@[(Session, @events)], label = "test timeline")

proc texts(vm: SessionTimelineVM): seq[string] =
  for line in vm.lines: result.add line.text

proc topTexts(vm: SessionTimelineVM): seq[string] =
  for line in vm.lines:
    if line.indent == 0: result.add line.text

proc lineOf(vm: SessionTimelineVM; text: string): TimelineLine =
  for line in vm.lines:
    if line.text == text: return line
  doAssert false, "no line " & text & " in " & $vm.texts

proc basics(): seq[JsonNode] =
  @[stamp(1, statusEvent("running")),
    stamp(2, userInput("Add jitter.")),
    stamp(3, fileRead("a.py")), stamp(4, fileRead("b.py")),
    stamp(5, commandCall("c1", "pytest -q")),
    stamp(6, toolResult("c1", "runCmd", 1, "1 failed",
      commandTrace([tracedProcess(7, 6, ["pytest", "-q"], 0, 900, 1, stdout = "F")],
                   "F", %*{"PATH": "/usr/bin", "API_TOKEN": "invented"}))),
    stamp(7, commandCall("c2", "ruff check")),
    stamp(8, toolResult("c2", "runCmd", 0, "ok"))]

suite "states":
  test "loading, error, a session the source does not hold, empty":
    createRoot proc(disposeRoot: proc()) =
      let pending = newSessionTimelineVM(newPendingDataSource(), Session)
      check pending.state.val == asIdle
      pending.load()
      check pending.state.val == asLoading
      check pending.notice == LoadingNotice
      check pending.lines.len == 0
      let failing = newSessionTimelineVM(newFailingDataSource("connection refused"), Session)
      failing.load()
      check failing.state.val == asError
      check failing.error.val == "connection refused"
      check failing.unresolvable.val == ""
      check failing.notice == ""
      let unknown = newSessionTimelineVM(sourceWith([]), Other)
      unknown.load()
      check unknown.state.val == asError
      check unknown.error.val == ""
      check unknown.unresolvable.val.startsWith("no session " & Other)
      check unknown.notice == UnresolvablePrefix & unknown.unresolvable.val
      let empty = newSessionTimelineVM(sourceWith([stamp(1, statusEvent("running"))]), Session)
      empty.load()
      check empty.state.val == asReady
      check empty.isEmpty
      check empty.notice == EmptyNotice
      check empty.statusLabel == "running"
      for vm in [pending, failing, unknown, empty]: vm.dispose()
      disposeRoot()

suite "lines":
  test "level 0: a turn, a group, a failed command group, roles":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      check vm.topTexts == @["Add jitter.", "Read 2 files",
                             "Ran 2 shell commands (1 failed)"]
      let lines = vm.lines
      check lines[0].kind == tlkTurn and lines[0].textRole == "label"
      check lines[1].kind == tlkGroup and lines[1].glyph == "\xE2\x96\xB8"
      check lines[2].failed == 1 and lines[2].count == 2
      check lines[2].parts.mapIt(it.role) == @["body", "error"]
      check lines.allIt(it.level == 0)
      vm.dispose()
      disposeRoot()

  test "drill-down: each toggle and step moves exactly one level, to the trace":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      let group = vm.lineOf("Ran 2 shell commands (1 failed)")
      vm.setFocus(group.id)
      vm.stepIn()
      # Level 1: the group's commands, the failed one with its exit code.
      check vm.texts == @["Add jitter.", "Read 2 files", "Ran 2 shell commands (1 failed)",
                          "Ran pytest -q exit 1", "Ran ruff check"]
      let failed = vm.lineOf("Ran pytest -q exit 1")
      check failed.level == 1 and failed.indent == 1
      check vm.focus.val == failed.id
      vm.stepIn()
      # Level 2: its facts, arguments, output and its trace line.
      let details = vm.lines.filterIt(it.level == 2)
      check details.mapIt(it.text) == @["Exit code: 1",
        "Arguments: {\"command\":\"pytest -q\"}", "1 failed",
        "Command trace: 1 process, stage 1 failed"]
      check details[1].copyText == details[1].text
      check details[3].kind == tlkTrace and details[3].expandable
      check vm.focus.val == details[0].id
      vm.focusNext()
      vm.focusNext()
      vm.focusNext()
      check vm.focus.val == "trace:" & failed.id
      vm.stepIn()
      # Level 3: the process, its facts, its output; the environment redacted.
      check vm.lines.filterIt(it.level == 3).mapIt(it.text) == @["pytest -q",
        "pid 7 \xC2\xB7 parent 6 \xC2\xB7 exit 1 \xC2\xB7 0.0 s to 0.9 s \xC2\xB7 /usr/bin/pytest \xC2\xB7 /work/upload-client",
        "F", "Environment: PATH=/usr/bin \xC2\xB7 API_TOKEN=[private]", "Raw output", "F"]
      # Out, one level at a time; the focus goes to the line it closed.
      vm.stepOut()
      check vm.focus.val == "trace:" & failed.id
      check vm.lines.filterIt(it.level == 3).len == 0
      vm.stepOut()
      check vm.focus.val == failed.id
      check vm.lines.filterIt(it.level == 2).len == 0
      vm.stepOut()
      check vm.focus.val == group.id
      check vm.lines.len == 3
      vm.dispose()
      disposeRoot()

  test "expand all opens every group; collapse all closes everything":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      vm.expandAll()
      check vm.lines.len == 3 + 2 + 2
      vm.toggle(vm.lineOf("Ran ruff check").id)
      vm.setFocus(vm.lines[^1].id)
      vm.collapseAll()
      check vm.lines.len == 3
      check vm.focus.val == vm.lines[2].id
      vm.dispose()
      disposeRoot()

  test "a command without a trace says so; an edit group shows its totals":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith([
        stamp(1, commandCall("c1", "make")), stamp(2, toolResult("c1", "runCmd", 0, "")),
        stamp(3, fileEdit("a.py", 3, 1, "x")), stamp(4, fileEdit("b.py", 2, 2, "y"))]), Session)
      vm.load()
      check vm.topTexts == @["Ran make", "Edited 2 files +5 " & Minus & "3"]
      check vm.lines[1].parts.mapIt(it.role) == @["body", "added", "removed"]
      vm.toggle(vm.lines[0].id)
      check vm.lines.anyIt(it.kind == tlkTrace and it.text == NoTraceText and
                           not it.expandable)
      vm.dispose()
      disposeRoot()

  test "the filter keeps the lines that match":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith(basics()), Session)
      vm.load()
      vm.setFilter("ruff")
      check vm.topTexts == @["Ran 2 shell commands (1 failed)"]
      check vm.matchCount == 1
      vm.setFilter("")
      check vm.matchCount == 3
      vm.dispose()
      disposeRoot()

  test "one fault is red once, whatever the filter keeps or the reader opens":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith([
        stamp(1, statusEvent("running")), stamp(2, userInput("Upgrade it.")),
        stamp(3, agentFailure("the upgrade breaks the tests; stopping")),
        stamp(4, statusEvent("failed", "The agent stopped."))]), Session)
      vm.load()
      check vm.lines.mapIt(it.textRole) == @["label", "error", "ended"]
      # The filter hides the failure; its ending still repeats it.
      vm.setFilter("agent stopped")
      check vm.topTexts == @["Status: failed The agent stopped."]
      check vm.lines.mapIt(it.textRole) == @["ended"]
      check vm.lines[0].parts[0].role == "ended"
      vm.setFilter("")
      # Opened, the ending's own line keeps the role; its details do not take it.
      let ended = newSessionTimelineVM(sourceWith([
        stamp(1, agentFailure("the upgrade breaks the tests; stopping")),
        stamp(2, %*{"type": "session_ended", "outcome": "failed",
                    "reason": "The agent stopped.", "exitCode": 1})]), Session)
      ended.load()
      let ending = ended.lines[^1]
      check ending.expandable
      check ending.textRole == "ended"
      ended.toggle(ending.id)
      check ended.lines.len > 2
      check ended.lines.filterIt(it.id == ending.id).mapIt(it.textRole) == @["ended"]
      check ended.lines[2 .. ^1].allIt(it.textRole != "ended")
      ended.dispose()
      # A failed ending with no failure before it is the fault, in red.
      let alone = newSessionTimelineVM(sourceWith([
        stamp(1, userInput("Upgrade it.")),
        stamp(2, statusEvent("failed", "The agent stopped."))]), Session)
      alone.load()
      check alone.lines.mapIt(it.textRole) == @["label", "error"]
      alone.dispose()
      vm.dispose()
      disposeRoot()

  test "a line that names a file says which part is its path":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith([
        stamp(1, userInput("Go.")), stamp(2, fileRead("src/upload/retry/client.py")),
        stamp(3, commandCall("c1", "pytest -q"))]), Session)
      vm.load()
      check vm.lines.mapIt(it.path) == @["", "src/upload/retry/client.py", ""]
      check vm.lines[1].parts[0].text == "Read src/upload/retry/client.py"
      vm.dispose()
      disposeRoot()

  test "a wait the server names a question is drawn as one":
    createRoot proc(disposeRoot: proc()) =
      let kind = proc(request, value: string): JsonNode =
        %*{"type": "session_awaiting_input_kind", "request": request, "kind": value}
      let vm = newSessionTimelineVM(sourceWith([
        stamp(1, userInput("Go.")),
        stamp(2, awaitingInput("claude-stop-hook")),
        stamp(2, kind("claude-stop-hook", "question_pending"))]), Session)
      vm.load()
      check vm.lines.mapIt(it.itemKind) == @["operator", "question"]
      check vm.lines[^1].textRole == "warning"
      vm.dispose()
      disposeRoot()

suite "following a session":
  test "only this session's frames are folded, and none twice":
    createRoot proc(disposeRoot: proc()) =
      let source = sourceWith(basics())
      let vm = newSessionTimelineVM(source, Session)
      vm.load()
      check vm.feeds.frames.subscribed
      let before = vm.texts
      # Another session's events, whatever their place in its own history
      # (unknown, early, or later than anything this session holds).
      for ordinal in [0, 1, 99]:
        discard source.sendFrame(eventFrame(Other, stamp(9, agentReply("other session")), ordinal))
      check vm.texts == before
      # An event the history already held (by its place in the history).
      discard source.sendFrame(eventFrame(Session, stamp(4, fileRead("b.py")), 4))
      check vm.texts == before
      discard source.sendFrame(eventFrame(Session, stamp(9, agentReply("Done.")), 9))
      check vm.topTexts[^1] == "Done."
      vm.dispose()
      disposeRoot()

  test "new items while not following are counted; following again clears them":
    createRoot proc(disposeRoot: proc()) =
      let source = sourceWith(basics())
      let vm = newSessionTimelineVM(source, Session)
      vm.load()
      discard source.sendFrame(eventFrame(Session, stamp(9, fileRead("c.py")), 9))
      check vm.unseen.val == 0
      vm.setFollow(false)
      discard source.sendFrame(eventFrame(Session, stamp(10, fileRead("d.py")), 10))
      discard source.sendFrame(eventFrame(Session, stamp(11, fileRead("e.py")), 11))
      check vm.unseen.val == 2
      # A result changes a line in place: nothing new to see.
      discard source.sendFrame(eventFrame(Session, stamp(12, commandCall("c3", "make")), 12))
      discard source.sendFrame(eventFrame(Session,
        stamp(13, toolResult("c3", "runCmd", 0, "")), 13))
      check vm.unseen.val == 3
      vm.jumpToLatest()
      check vm.unseen.val == 0
      check vm.follow.val
      vm.dispose()
      disposeRoot()

  test "the anchor holds the reader's line, and follows it into a group":
    createRoot proc(disposeRoot: proc()) =
      let source = sourceWith([stamp(1, fileRead("a.py")), stamp(2, agentReply("ok")),
                               stamp(3, commandCall("c1", "make"))])
      let vm = newSessionTimelineVM(source, Session)
      vm.load()
      let command = vm.lineOf("Ran make")
      vm.readAt(command.id)
      check vm.anchor == ""
      vm.setFollow(false)
      check vm.anchor == command.id
      discard source.sendFrame(eventFrame(Session, stamp(4, commandCall("c2", "make test")), 4))
      check vm.anchor == "group:" & command.id
      vm.dispose()
      disposeRoot()

  test "focus and open lines survive new events":
    createRoot proc(disposeRoot: proc()) =
      let source = sourceWith(basics())
      let vm = newSessionTimelineVM(source, Session)
      vm.load()
      let group = vm.lineOf("Read 2 files")
      vm.toggle(group.id)
      vm.setFocus(vm.lineOf("Read b.py").id)
      discard source.sendFrame(eventFrame(Session, stamp(9, fileRead("c.py")), 9))
      discard source.sendFrame(eventFrame(Session, stamp(10, fileRead("d.py")), 10))
      check vm.lineOf("Read 2 files").expanded
      check vm.lines.filterIt(it.focused).mapIt(it.text) == @["Read b.py"]
      check vm.topTexts[^1] == "Read 2 files"
      # A group that grows under the reader stays open: its id is its
      # first item's, not its newest's.
      let grown = vm.lines.filterIt(it.text == "Read 2 files")[^1]
      vm.toggle(grown.id)
      discard source.sendFrame(eventFrame(Session, stamp(11, fileRead("e.py")), 11))
      check vm.lineOf("Read 3 files").expanded
      check vm.lineOf("Read 3 files").id == grown.id
      check vm.lines.filterIt(it.level == 1).mapIt(it.text) ==
        @["Read a.py", "Read b.py", "Read c.py", "Read d.py", "Read e.py"]
      vm.dispose()
      disposeRoot()

suite "over the session-run playback":
  proc lateTexts(moment: string): seq[string] =
    ## The lines of a viewmodel loaded only once the playback stood at
    ## `moment`, with every line opened.
    var shown: seq[string]
    createRoot proc(disposeRoot: proc()) =
      let source = newPlaybackDataSource(sessionRunScenario(), newTestClock(0))
      doAssert source.seekMoment(moment)
      let vm = newSessionTimelineVM(source, JitterSessionId)
      vm.load()
      for _ in 0 .. 3:
        for line in vm.lines:
          if line.expandable and not line.expanded: vm.toggle(line.id)
      shown = vm.texts
      vm.dispose()
      disposeRoot()
    shown

  test "a viewmodel loaded late shows what one that followed shows, details included":
    var followed: seq[string]
    createRoot proc(disposeRoot: proc()) =
      let source = newPlaybackDataSource(sessionRunScenario(), newTestClock(0))
      let vm = newSessionTimelineVM(source, JitterSessionId)
      vm.load()
      doAssert source.seekMoment("command-fails")
      for _ in 0 .. 3:
        for line in vm.lines:
          if line.expandable and not line.expanded: vm.toggle(line.id)
      followed = vm.texts
      vm.dispose()
      disposeRoot()
    let late = lateTexts("command-fails")
    check late == followed
    check "Command trace: 3 processes, stage 1 failed" in late
    check "Environment: PATH=/usr/bin \xC2\xB7 UPLOAD_CLIENT_ENV=test \xC2\xB7 UPLOAD_API_TOKEN=[private]" in late

  test "the other session's events never show":
    createRoot proc(disposeRoot: proc()) =
      let source = newPlaybackDataSource(sessionRunScenario(), newTestClock(0))
      let vm = newSessionTimelineVM(source, JitterSessionId)
      vm.load()
      while source.step(): discard
      vm.expandAll()
      let all = vm.texts.join("\n")
      check "log.py" notin all
      check "ruff check src/upload" notin all
      check "Logging tidied." notin all
      check vm.statusLabel == "completed"
      vm.dispose()
      disposeRoot()

  test "a seek back keeps the reader's open lines and focus where they still exist":
    createRoot proc(disposeRoot: proc()) =
      let source = newPlaybackDataSource(sessionRunScenario(), newTestClock(0))
      let vm = newSessionTimelineVM(source, JitterSessionId)
      vm.load()
      doAssert source.seekMoment("edits-grouped")
      let reads = vm.lineOf("Read 4 files")
      let shell = vm.lineOf("Ran 2 shell commands (1 failed)")
      vm.toggle(reads.id)
      vm.toggle(shell.id)
      vm.setFocus(vm.lineOf("Read tests/test_client.py").id)
      vm.setFollow(false)
      let before = vm.texts
      doAssert source.seekMoment("command-running")
      check source.resets == 1
      check vm.isExpanded(reads.id)
      check vm.lineOf("Read 4 files").expanded
      check vm.lines.filterIt(it.focused).mapIt(it.text) == @["Read tests/test_client.py"]
      check not vm.follow.val
      # The seek rebuilt the timeline from the first frame and delivered its
      # events again while the reader did not follow: the count is what a
      # viewmodel loaded at the first frame and stepped here unfollowed
      # shows -- the instruction, two thoughts, four reads, three searches,
      # the model request and two commands (13), not the 13 plus what it
      # counted before the seek.
      check vm.unseen.val == 13
      doAssert source.seekMoment("edits-grouped")
      check vm.texts == before
      vm.dispose()
      disposeRoot()

  test "the header's status follows the session":
    createRoot proc(disposeRoot: proc()) =
      let source = newPlaybackDataSource(sessionRunScenario(), newTestClock(0))
      let vm = newSessionTimelineVM(source, JitterSessionId)
      vm.load()
      var seen: seq[string]
      for moment in ["instruction", "agent-asks", "answered", "hook-repeats",
                     "agent-replies", "session-completes"]:
        doAssert source.seekMoment(moment)
        seen.add vm.statusLabel
      check seen == @["running", "needs input", "running", "needs input",
                      "running", "completed"]
      vm.dispose()
      disposeRoot()

suite "the invented timelines":
  test "every invented timeline builds, with its reader state":
    for name in SyntheticTimelineNames:
      createRoot proc(disposeRoot: proc()) =
        let vm = newSyntheticTimelineVM(name)
        checkpoint name
        case name
        of "loading": check vm.state.val == asLoading
        of "error":
          check vm.state.val == asError
          check vm.error.val == TimelineErrorText
        of "unresolvable":
          check vm.state.val == asError
          check vm.unresolvable.val.len > 0
        of "empty": check vm.isEmpty
        else:
          check vm.state.val == asReady
          check vm.lines.len > 0
        case name
        of "group-open":
          check vm.lineOf("Ran 3 shell commands (1 failed)").expanded
        of "details":
          check vm.lines.anyIt(it.level == 2 and it.text.startsWith("@@ -38,6"))
          check vm.lines.anyIt(it.level == 2 and it.text == "1 failed, 17 passed in 14.1s")
        of "command-trace":
          let traces = vm.lines.filterIt(it.kind == tlkTrace)
          check traces.mapIt(it.text) == @["Command trace: 1 process",
            "Command trace: 3 processes, stage 1 failed", "Command trace: 2 processes",
            "Command trace: 2 processes", NoTraceText]
          check traces.mapIt(it.expanded) == @[false, true, true, true, false]
          check vm.lines.anyIt(it.level == 3 and "running" in it.text)
          check vm.lines.anyIt(it.text == "UPLOAD_API_TOKEN=[private]" or
            "UPLOAD_API_TOKEN=[private]" in it.text)
        of "running":
          let shell = vm.lineOf("Ran 2 shell commands Ran pytest -q tests/integration --slow")
          check shell.running == 1
          check vm.runningLine.command == "pytest -q tests/integration --slow"
        of "needs-input":
          check vm.statusLabel == "needs input"
          check vm.lines[^1].textRole == "warning"
        of "failed":
          check vm.statusLabel == "failed"
          # One fault is red once: the failure the agent stopped on; the
          # session's failed status after it is drawn as an ending.
          check vm.lines.filterIt(it.textRole == "error").mapIt(it.text) ==
            @["error: the HTTP library's new API breaks every upload test; stopping"]
          check vm.lines[^1].text == "Status: failed The agent stopped: the upgrade breaks the upload tests."
          check vm.lines[^1].textRole == "ended"
        of "long":
          check vm.items.len >= 300
          check vm.lines.filterIt(it.kind == tlkTurn).len == 12
          check vm.lines.filterIt(it.kind == tlkGap).mapIt(it.text) ==
            @["10 min later", "10 min later"]
        of "reading-back":
          check not vm.follow.val
          check vm.unseen.val > 0
          check vm.anchor.startsWith("group:")
        of "focused":
          check vm.lines.filterIt(it.focused).mapIt(it.text) == @["Searched 2 times"]
        of "every-kind":
          var kinds = initHashSet[string]()
          for item in vm.items: kinds.incl $item.kind
          for kind in ["operator", "thought", "agent", "read", "plan", "search",
                       "model", "shell", "harness", "edit", "delete", "tool",
                       "question", "resumed", "status", "failure", "completed"]:
            checkpoint kind
            check kind in kinds
          check vm.lines.allIt(it.kind != tlkGroup)
        else: discard
        vm.dispose()
        disposeRoot()

  test "the invented timelines hold invented data only":
    for name in SyntheticTimelineNames:
      let timeline = syntheticTimeline(name)
      check timeline.sessionId.startsWith("5ca1ab1e-")
      for event in timeline.events & timeline.later:
        let text = $event
        for marker in ["/home/", "/Users/", "metacraft"]:
          if marker in text:
            checkpoint name & ": " & marker & " in " & text
            fail()
    expect ValueError: discard syntheticTimeline("no-such-timeline")

# ---------------------------------------------------------------------------
# Links in an agent's messages, and the session's test runs
# ---------------------------------------------------------------------------
#
# These read through `TraceLinkSource` (`synthetic_test_runs.nim`), the
# prototypes' scripted source for trace links: it serves the session's
# messages like `TimelineDataSource`, plus their link spans and the
# session's test runs, which no other source in this repository serves. The
# control for each line is the same events through `TimelineDataSource`,
# which serves neither.

proc linkedTimeline(fixture: string; origin = TestRunsServer): SessionTimelineVM =
  result = newSessionTimelineVM(traceLinkFixture(fixture), TestRunsSessionId,
                                serverOrigin = origin)
  result.load()

proc plainTimeline(fixture: string): SessionTimelineVM =
  ## The same messages with no links served and no server known.
  let source = traceLinkFixture(fixture)
  result = newSessionTimelineVM(newTimelineDataSource(@[(TestRunsSessionId, source.sessionEvents)]),
                                TestRunsSessionId)
  result.load()

proc agentLine(vm: SessionTimelineVM): TimelineLine =
  for line in vm.lines:
    if line.itemKind == "agent": return line

proc linkKinds(line: TimelineLine): seq[string] =
  for p in line.parts[0].links:
    result.add $p.kind & (if p.kind == lpTrace: ":" & $p.reference.kind else: "") &
      (if p.reason.len > 0: "!" else: "")

proc joined(line: TimelineLine): string =
  for p in line.parts[0].links: result.add p.text

suite "links in an agent's messages":
  test "test_session_timeline_vm_link_leaves_text_copy_and_path_unchanged":
    createRoot proc(disposeRoot: proc()) =
      let linked = linkedTimeline("link")
      let plain = plainTimeline("link")
      check linked.state.val == asReady and plain.state.val == asReady
      let a = linked.agentLine
      let b = plain.agentLine
      check a.text == LinkText
      check a.text == b.text
      check a.copyText == b.copyText
      check a.path == b.path
      check a.parts.len == b.parts.len
      for i in 0 ..< a.parts.len:
        check a.parts[i].text == b.parts[i].text
        check a.parts[i].role == b.parts[i].role
      check a.textRole == b.textRole
      # Every other line is the same too.
      check linked.texts == plain.texts
      # The control serves no link spans: its line has no file link.
      check "file" in a.linkKinds and "file" notin b.linkKinds
      check a.joined == a.parts[0].text
      check a.linkKinds == @["text", "file", "text", "trace:agent-harbor", "text"]
      var names: seq[string]
      for p in a.parts[0].links:
        if linkName(p).len > 0: names.add linkName(p)
      check names == @["File src/relay/metrics.py", "Trace " & OneTraceId]
      linked.dispose()
      plain.dispose()
      disposeRoot()

  test "the https form is a trace on the session's server only; another origin stays a plain link":
    createRoot proc(disposeRoot: proc()) =
      let vm = linkedTimeline("many-links")
      let line = vm.agentLine
      check line.joined == manyLinksText()
      check line.linkKinds == @["text", "trace:agent-harbor", "text", "trace:agent-harbor",
                                "text", "url", "text"]
      check line.parts[0].links[3].reference.id == SecondTraceId
      check line.parts[0].links[3].reference.query == "at=frame-118"
      let unknown = linkedTimeline("many-links", origin = "")
      check unknown.agentLine.linkKinds == @["text", "trace:agent-harbor", "text", "url", "text",
                                             "url", "text"]
      vm.dispose()
      unknown.dispose()
      disposeRoot()

  test "a malformed trace link stays text, saying why; a recording link is its own kind":
    createRoot proc(disposeRoot: proc()) =
      let bad = linkedTimeline("malformed")
      let line = bad.agentLine
      check line.joined == malformedText()
      var reasons: seq[string]
      for p in line.parts[0].links:
        check p.kind != lpTrace
        if p.reason.len > 0: reasons.add p.reason
      check reasons.len == 4
      check reasons[0] == "Not a trace link: the trace id is empty"
      let local = linkedTimeline("local-recording")
      let l = local.agentLine
      check l.linkKinds == @["text", "trace:local-recording", "text", "trace:agent-harbor", "text"]
      check linkName(l.parts[0].links[1]) == "Recording test_queue_bound_holds"
      check l.parts[0].links[1].reference.query == "mode=refresh"
      bad.dispose()
      local.dispose()
      disposeRoot()

  test "file links of each kind, named by their target":
    createRoot proc(disposeRoot: proc()) =
      let vm = linkedTimeline("file-links")
      let line = vm.agentLine
      check line.joined == FileLinksText
      var files: seq[string]
      for p in line.parts[0].links:
        if p.kind == lpFile:
          files.add p.text & " -> " & linkName(p) & " (" & fileLinkTitle(p.targets) & ")"
      check files == @[
        "src/relay/queue.py -> File src/relay/queue.py (Open src/relay/queue.py:31)",
        "src/relay/flow.py -> File src/relay/flow.py (Several files match; choose one)",
        "src/relay/ -> File src/relay (src/relay is a directory; nothing to open)",
        "docs/missing.md -> File docs/missing.md (File not found in this session)",
        "crates/relay-codec/src/transports/websocket/framing/compression/window.rs -> " &
          "File crates/relay-codec/src/transports/websocket/framing/compression/window.rs " &
          "(Open crates/relay-codec/src/transports/websocket/framing/compression/window.rs)"]
      vm.dispose()
      disposeRoot()

  test "a message with no link carries none":
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTimelineVM(sourceWith([stamp(1, agentReply("Nothing to link here."))]),
                                    Session, serverOrigin = TestRunsServer)
      vm.load()
      check vm.agentLine.text == "Nothing to link here."
      check not vm.agentLine.hasLinks
      vm.dispose()
      disposeRoot()

suite "the session's test runs":
  test "test_session_timeline_vm_test_run_summary_lines":
    createRoot proc(disposeRoot: proc()) =
      let vm = linkedTimeline("summary")
      var runs: seq[TimelineLine]
      for line in vm.lines:
        if line.itemKind == "test-run": runs.add line
      check runs.len == 2
      check runs[0].text == "Ran 1 test on 2 platforms: 1 failed"
      check runs[0].state == tisFailed
      check runs[0].textRole == "error" and runs[0].parts.len == 1
      check runs[1].text == "Ran 2 tests on 1 platform: 1 passed, 1 failed"
      check runs[0].id == "test-run:run-7"
      check runs[0].indent == 0 and runs[0].expandable
      # Never a member of a group, and the timeline's other lines unchanged.
      for line in vm.lines:
        if line.kind == tlkGroup:
          for item in vm.items:
            check item.kind != tikTestRun or item.id notin line.id
      let plain = plainTimeline("summary")
      var others: seq[string]
      for line in vm.lines:
        if line.itemKind != "test-run": others.add line.text
      check others == plain.texts
      vm.toggle(runs[0].id)
      var details: seq[string]
      for line in vm.lines:
        if line.kind == tlkDetail and line.id.startsWith("detail:test-run:run-7"):
          details.add line.text
      check details == @["failed test_oldest_frame_is_shed (Linux x86-64 passed \xC2\xB7 Windows x86-64 failed)"]
      vm.dispose()
      plain.dispose()
      disposeRoot()

  test "a run still active is followed, and its line moves with its events":
    createRoot proc(disposeRoot: proc()) =
      let source = traceLinkFixture("summary")
      var run = newTestRunState("run-9", @[LinuxX86], @["reprobuild"], relayTests()[0 .. 1])
      run.startedMs = 8_000
      run.foldEvents([runStartedEvent("run-9", LinuxX86, "reprobuild", "pytest")])
      source.runs.add run
      let vm = newSessionTimelineVM(source, TestRunsSessionId, serverOrigin = TestRunsServer)
      vm.load()
      proc lineOf(vm: SessionTimelineVM): TimelineLine =
        for line in vm.lines:
          if line.id == "test-run:run-9": return line
      check vm.lineOf.text == "Running 2 tests on 1 platform"
      check vm.lineOf.state == tisRunning
      discard source.sendEvent(testFinishedEvent("run-9", LinuxX86, relayTests()[0].id, "passed", 9))
      check vm.lineOf.text == "Running 2 tests on 1 platform: 1 passed"
      discard source.sendEvent(testFinishedEvent("run-9", LinuxX86, relayTests()[1].id, "failed", 9))
      discard source.sendEvent(runFinishedEvent("run-9", LinuxX86))
      check vm.lineOf.text == "Ran 2 tests on 1 platform: 1 passed, 1 failed"
      check vm.lineOf.state == tisFailed
      vm.dispose()
      # Disposed: an event no longer reaches it.
      check source.sendEvent(diagnosticEvent("run-9", LinuxX86, "info", "late")) == newSeq[ProgressDelivery]()
      disposeRoot()
