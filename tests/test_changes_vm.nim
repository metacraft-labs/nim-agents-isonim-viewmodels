## The Changes viewmodel (`ChangesVM`): the four tabs in the reviewer's order
## and the tab it opens on (the milestone's "tab order"), the reader's state
## across restarts, the Spec Changes tiers and approval states, the Tests,
## Implementation Details and Code tabs, a task with no plan, the load
## states, and the writes that go through the scripted action seam.
##
## Test doubles, and why each is justified:
##
## - `ScriptedActionSource` (through `changesFixture`) is the prototypes'
##   production source for a change: the review-record and base-relative
##   diff reads are not served yet and the prototypes may not write to a
##   server, so every story reads and writes through it. Its record is what
##   the write tests read.
## - `ReadOnlyChanges` serves the same change and leaves `submitAction` to
##   the base: a source with no way to send an action, which must never show
##   one as sent.
## - `HeldFiles` is the same scripted source with its file reads held until
##   the test releases them: a server whose per-file read answers late,
##   which the scripted source (answering at once) cannot show.
## - `PendingDataSource` and `FailingDataSource` are the seam's state sources.
##
## Expected values are written out by hand from the invented plan and diffs
## (`synthetic_changes.nim`), never computed through the parsers.

import std/[strutils, unittest]
import isonim/core/[owner, signals]
import nim_agents_isonim_viewmodels

const Minus = "\xE2\x88\x92"

type ReadOnlyChanges = ref object of AgentHarborDataSource
  inner: ScriptedActionSource

method loadReviewRecord(source: ReadOnlyChanges; scope: ReviewScope;
                        done: ReviewCallback) =
  source.inner.loadReviewRecord(scope, done)

method loadChangeDiff(source: ReadOnlyChanges; sessionId, base: string;
                      done: SessionDiffCallback) =
  source.inner.loadChangeDiff(sessionId, base, done)

type HeldFiles = ref object of ScriptedActionSource
  hold: bool
  held: seq[proc()]

method loadFileDiff(source: HeldFiles; sessionId, base, path: string;
                    done: FileDiffCallback) =
  if not source.hold:
    procCall ScriptedActionSource(source).loadFileDiff(sessionId, base, path, done)
    return
  source.held.add proc() =
    procCall ScriptedActionSource(source).loadFileDiff(sessionId, base, path, done)

proc changesOver(fixture: string): ChangesVM =
  result = newChangesVM(changesFixture(fixture), relayScope())
  result.load()

proc tabLine(vm: ChangesVM): seq[string] =
  ## `Label count`, the active tab starred.
  for t in vm.tabs:
    result.add (if t.active: "*" else: "") & t.label & " " & $t.count

proc cardLine(vm: ChangesVM): seq[string] =
  ## `tier | title | state [role]`.
  for c in vm.specCards:
    result.add $c.tier & " | " & c.title & " | " & c.stateText & " [" & c.stateRole & "]"

proc keyOf(vm: ChangesVM; title: string): string =
  for c in vm.specCards:
    if c.title == title: return c.key
  ""

proc paths(vm: ChangesVM): seq[string] =
  for row in vm.files: result.add row.file.path

suite "the tabs":
  test "test_changes_vm_tab_order: Spec Changes, Tests, Implementation Details, Code, opening on the first with content":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      check vm.state.val == asReady
      check vm.tabLine == @["*Spec Changes 8", "Tests 5", "Implementation Details 6", "Code 9"]
      var compact: seq[string]
      for t in vm.tabs: compact.add t.compactLabel
      check compact == @["Specs", "Tests", "Details", "Code"]
      # No spec change in the plan or the diff: it opens on Tests.
      let codeOnly = changesOver("no-spec-changes")
      check codeOnly.tabLine == @["Spec Changes 0", "*Tests 2", "Implementation Details 1", "Code 1"]
      check codeOnly.activeTab.val == rtTests
      # Nothing anywhere: the first tab, saying so.
      let empty = changesOver("empty")
      check empty.activeTab.val == rtSpecChanges
      check empty.notice == NoSpecChangesText
      empty.selectTab(rtCode)
      check empty.notice == NoChangesText
      check empty.summaryLine == NoChangesText
      check empty.rollUp(ended = true) == ""
      vm.dispose()
      codeOnly.dispose()
      empty.dispose()
      disposeRoot()

  test "the reader's tab, cards and filter survive a restart":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      check vm.activeTab.val == rtSpecChanges
      let key = vm.keyOf("specs/Relay-Metrics.md")
      vm.toggleCard(key)
      vm.selectTab(rtCode)
      vm.setFilter(sfAdded)
      vm.restart()
      check vm.state.val == asReady
      check vm.activeTab.val == rtCode
      check vm.filter.val == sfAdded
      var open: seq[string]
      for c in vm.specCards:
        if c.open: open.add c.title
      check open == @["specs/Relay-Metrics.md"]
      vm.dispose()
      disposeRoot()

  test "a task with no plan shows Spec Changes from the diff, and Code":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("no-plan")
      check not vm.hasPlan
      check vm.tabLine == @["*Spec Changes 5", "Code 9"]
      check vm.cardLine == @[
        "requirements | RELAY-AREQ2 Bounded queues | modified [quiet]",
        "requirements | RELAY-AREQ4 Shed the oldest frame | added [quiet]",
        "governance | AGENTS.md | modified [quiet]",
        "specs | specs/Relay-Backpressure.md | approval not recorded [quiet]",
        "specs | specs/Relay-Metrics.md | approval not recorded [quiet]"]
      for c in vm.specCards: check c.summary == ""
      check vm.milestoneChoices == @[("", "All milestones")]
      vm.dispose()
      disposeRoot()

  test "a milestone narrows every tab":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      check vm.milestoneChoices == @[("", "All milestones"),
        ("RB-M1", "RB-M1: Specify the backpressure contract"),
        ("RB-M2", "RB-M2: Report queue depth and slow stations"),
        ("RB-M3", "RB-M3: Document the operator runbook")]
      vm.selectMilestone("RB-M1")
      check vm.tabLine == @["*Spec Changes 5", "Tests 2", "Implementation Details 4", "Code 9"]
      vm.selectMilestone("")
      check vm.tabLine[0] == "*Spec Changes 8"
      vm.dispose()
      disposeRoot()

suite "Spec Changes":
  test "three tiers: requirements and governance from the diff, then the record's entries":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      check vm.cardLine == @[
        "requirements | RELAY-AREQ2 Bounded queues | modified [quiet]",
        "requirements | RELAY-AREQ4 Shed the oldest frame | added [quiet]",
        "governance | AGENTS.md | modified [quiet]",
        "specs | specs/Relay-Backpressure.md | approved 2027-01-12 by Dana Reyes (feedback fb-relay-1) [success]",
        "specs | specs/Relay-Glossary.md | editorial [quiet]",
        "specs | specs/Relay-Metrics.md | pending [warning]",
        "specs | specs/Relay-Ports.md | pending [warning]",
        "specs | specs/Relay-Retention.md | approved 2027-01-13 by Sam Okafor (relayed by relay-manager) [success]"]
      var approvable: seq[string]
      for c in vm.specCards:
        if c.canApprove: approvable.add c.title
      check approvable == @["specs/Relay-Metrics.md"]
      vm.dispose()
      disposeRoot()

  test "malformed and unstructured records are never shown approved":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("malformed")
      var specs: seq[string]
      for line in vm.cardLine:
        if line.startsWith("specs"): specs.add line
      check specs == @[
        "specs | specs/Relay-Ports.md | malformed: missing summary [error]",
        "specs | specs/Relay-Retention.md | malformed: approval [error]",
        "specs | specs/Relay-Metrics.md | malformed: approval [error]",
        "specs | specs/Relay-Legacy.md | approval not recorded [quiet]"]
      for c in vm.specCards: check not c.canApprove
      vm.dispose()
      disposeRoot()

  test "Summary and Diff: a card's own hunks, and its spec file's":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      let areq = vm.keyOf("RELAY-AREQ4 Shed the oldest frame")
      vm.toggleDiff(areq)
      check vm.specCards[1].showsDiff
      check vm.cardDiff(areq).len == 1
      # A spec file's hunks are loaded with the record (tiers 1 and 2 are
      # read from them); another file's only when the reader opens it.
      let entry = vm.keyOf("specs/Relay-Backpressure.md")
      check vm.fileDiff("specs/Relay-Backpressure.md").state == fdLoaded
      check vm.fileDiff("src/relay/queue.py").state == fdNotLoaded
      check vm.cardDiff(entry).len == 1
      check vm.cardDiff(entry)[0].lines[1].text ==
        "Every relay queue holds at most 512 frames."
      vm.dispose()
      disposeRoot()

  test "approve, request changes, revert: each through the seam, the record read again":
    createRoot proc(disposeRoot: proc()) =
      let source = ScriptedActionSource(changesFixture("populated"))
      let vm = newChangesVM(source, relayScope())
      vm.load()
      check not vm.approve(vm.keyOf("specs/Relay-Ports.md"))   # no request open
      check vm.approve(vm.keyOf("specs/Relay-Metrics.md"))
      check "specs | specs/Relay-Metrics.md | approved " & ScriptedApprovalDate &
        " by operator (feedback fb-relay-7) [success]" in vm.cardLine
      let ports = vm.keyOf("specs/Relay-Ports.md")
      vm.openRequestChanges(ports)
      check vm.specCards[6].requestOpen
      check not vm.submitRequestChanges()                     # nothing typed
      vm.setRequestText("Name the old port too.")
      check vm.submitRequestChanges()
      check vm.revert(vm.keyOf("specs/Relay-Glossary.md"))
      check vm.keyOf("specs/Relay-Glossary.md") == ""
      check vm.tabLine[0] == "*Spec Changes 7"
      check source.record == @[
        "approve-spec-change task=relay-backpressure request=fb-relay-7 milestone=RB-M2 " &
          "spec=specs/Relay-Metrics.md",
        "request-spec-changes task=relay-backpressure milestone=RB-M2 " &
          "spec=specs/Relay-Ports.md text=\"Name the old port too.\"",
        "revert-spec-change task=relay-backpressure milestone=RB-M1 spec=specs/Relay-Glossary.md"]
      vm.dispose()
      disposeRoot()

  test "a confirmed write rereads the record and leaves a file's load in flight":
    createRoot proc(disposeRoot: proc()) =
      let scripted = ScriptedActionSource(changesFixture("populated"))
      let source = HeldFiles(label: scripted.label, reviews: scripted.reviews,
                             diffs: scripted.diffs, script: scripted.script,
                             effects: true)
      let vm = newChangesVM(source, relayScope())
      vm.load()
      check vm.state.val == asReady
      source.hold = true
      vm.selectFile("src/relay/queue.py")
      check vm.fileDiff("src/relay/queue.py").state == fdLoading
      check vm.approve(vm.keyOf("specs/Relay-Metrics.md"))
      check "specs | specs/Relay-Metrics.md | approved " & ScriptedApprovalDate &
        " by operator (feedback fb-relay-7) [success]" in vm.cardLine
      # The file's answer, arriving after the record was read again, is shown.
      check source.held.len == 1
      source.held[0]()
      check vm.fileDiff("src/relay/queue.py").state == fdLoaded
      check vm.fileDiff("src/relay/queue.py").file.hunks.len == 2
      vm.dispose()
      disposeRoot()

  test "staged cards sit in their tiers, and are applied or discarded":
    createRoot proc(disposeRoot: proc()) =
      let source = ScriptedActionSource(changesFixture("staged"))
      let vm = newChangesVM(source, relayScope())
      vm.load()
      check vm.cardLine[0 .. 4] == @[
        "requirements | RELAY-AREQ2 Bounded queues | modified [quiet]",
        "requirements | RELAY-AREQ4 Shed the oldest frame | added [quiet]",
        "requirements | RELAY-AREQ5 Tell the probe when frames are shed | staged [warning]",
        "governance | AGENTS.md | modified [quiet]",
        "governance | .ah/autonomy.md | staged [warning]"]
      check vm.specCards[2].origin == "operator-distilled"
      check vm.applyStaged(vm.specCards[2].key)
      check vm.discardStaged(vm.keyOf(".ah/autonomy.md"))
      check not vm.applyStaged(vm.keyOf("AGENTS.md"))         # not staged
      check vm.cardLine[0 .. 3] == @[
        "requirements | RELAY-AREQ2 Bounded queues | modified [quiet]",
        "requirements | RELAY-AREQ4 Shed the oldest frame | added [quiet]",
        "requirements | RELAY-AREQ5 Tell the probe when frames are shed | added [quiet]",
        "governance | AGENTS.md | modified [quiet]"]
      check source.record == @[
        "apply-staged task=relay-backpressure spec=specs/Relay-Backpressure.md",
        "discard-staged task=relay-backpressure spec=.ah/autonomy.md"]
      vm.dispose()
      disposeRoot()

  test "a write to a source without actions is shown failed, never sent":
    createRoot proc(disposeRoot: proc()) =
      let inner = ScriptedActionSource(changesFixture("populated"))
      let vm = newChangesVM(ReadOnlyChanges(label: "read only", inner: inner), relayScope())
      vm.load()
      let key = vm.keyOf("specs/Relay-Metrics.md")
      check vm.approve(key)
      var card: SpecCardView
      for c in vm.specCards:
        if c.key == key: card = c
      check card.action == astFailed
      check card.actionReason == "the data source 'read only' does not provide operator actions"
      check card.stateText == "pending"
      check inner.record.len == 0
      vm.dispose()
      disposeRoot()

suite "Tests and Implementation Details":
  test "tests by milestone, failing first, statuses by their leading token":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      var lines: seq[string]
      for g in vm.tests:
        for e in g.entries:
          lines.add g.milestoneId & " " & e.testName & " " & $e.status &
            (if e.annotation.len > 0: " (" & e.annotation & ")" else: "")
      check lines == @[
        "RB-M2 test_depth_metric_reports_each_queue failing",
        "RB-M2 test_slow_station_is_told_to_slow_down pending",
        "RB-M1 test_queue_bound_holds passing",
        "RB-M1 test_oldest_frame_is_shed passing (2027-01-12 (review) at e4f5a6b)",
        "RB-M3 test_runbook_links_resolve pending"]
      let passing = changesOver("all-passing")
      for g in passing.tests:
        for e in g.entries: check e.status == vsPassing
      let pending = changesOver("all-pending")
      for g in pending.tests:
        for e in g.entries: check e.status == vsPending
      vm.dispose()
      passing.dispose()
      pending.dispose()
      disposeRoot()

  test "implementation details as written, with key source files":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      let d = vm.details
      check d.len == 2
      check d[0].milestoneId == "RB-M1"
      check d[0].notes.startsWith("The queue keeps its frames in arrival order:\n- =RelayQueue.push=")
      check d[0].keySourceFiles[0].path == "src/relay/queue.py"
      check d[0].keySourceFiles[0].purpose == "the bounded queue and its shedding."
      check d[1].notes == "The depth gauge is read when the metrics endpoint is scraped."
      vm.dispose()
      disposeRoot()

suite "Code":
  test "files: key source files first, committed and uncommitted marks, the summary":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      vm.selectTab(rtCode)
      var rows: seq[string]
      for row in vm.files:
        rows.add $row.file.status & " " & row.file.path & " " & row.counts & " " &
          $row.file.origin & (if row.key: " key" else: "") & (if row.file.binary: " binary" else: "")
      check rows == @[
        "M src/relay/queue.py +5 " & Minus & "1 both key",
        "A tests/test_queue.py +3 " & Minus & "0 uncommitted key",
        "M AGENTS.md +1 " & Minus & "0 committed",
        "M specs/Relay-Backpressure.md +5 " & Minus & "1 committed",
        "M specs/Relay-Metrics.md +1 " & Minus & "0 committed",
        "R src/relay/backlog.py +1 " & Minus & "1 committed",
        "D src/relay/old_buffer.py +0 " & Minus & "2 committed",
        "A docs/backpressure.png +0 " & Minus & "0 committed binary",
        "A src/relay/transports/websocket/framing/compression/deflate/window/encoder.py +2 " &
          Minus & "0 committed"]
      check vm.summaryLine == "9 files changed +18 " & Minus & "5"
      check vm.rollUp(ended = true) == "9 files +18 " & Minus & "5"
      check vm.rollUp(ended = false) == ""
      check vm.notice == ""
      vm.dispose()
      disposeRoot()

  test "filter and search; nothing matching says so":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      vm.setFilter(sfAdded)
      check vm.paths == @["tests/test_queue.py", "docs/backpressure.png",
        "src/relay/transports/websocket/framing/compression/deflate/window/encoder.py"]
      vm.setFilter(sfAll)
      vm.setQuery("RELAY/")
      check vm.paths == @["src/relay/queue.py", "src/relay/backlog.py",
        "src/relay/old_buffer.py",
        "src/relay/transports/websocket/framing/compression/deflate/window/encoder.py"]
      vm.setQuery("buffer.py")      # a rename's old path matches too
      check vm.paths == @["src/relay/backlog.py", "src/relay/old_buffer.py"]
      vm.setQuery("no such file")
      check vm.paths.len == 0
      check vm.filesNotice == NoMatchingFilesText
      vm.dispose()
      disposeRoot()

  test "a file's diff: not loaded, loaded with both origins' hunks, binary; prev and next":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      check vm.fileDiff("src/relay/queue.py").state == fdNotLoaded
      check vm.fileDiff("docs/backpressure.png").state == fdBinary
      vm.selectFile("src/relay/queue.py")
      let loaded = vm.fileDiff("src/relay/queue.py")
      check loaded.state == fdLoaded
      check loaded.file.hunks.len == 2
      check loaded.file.hunks[0].origin == coCommitted
      check loaded.file.hunks[1].origin == coUncommitted
      check vm.selectedPosition == "1 of 9"
      check vm.stepFile(1)
      check vm.selectedFile.val == "tests/test_queue.py"
      check vm.selectedPosition == "2 of 9"
      check vm.fileDiff("tests/test_queue.py").state == fdLoaded
      check vm.stepFile(-1)
      check not vm.stepFile(-1)
      check vm.selectedFile.val == "src/relay/queue.py"
      vm.openInEditor("src/relay/queue.py")
      check vm.editorRequest.val == "src/relay/queue.py"
      check vm.editorRequests.val == 1
      vm.dispose()
      disposeRoot()

  test "the base selector: the merge base or the session's own diff":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("populated")
      var labels: seq[string]
      for b in vm.bases: labels.add b.label
      check labels == @["Since main", "Session changes"]
      check vm.baseLabel == "Since main"
      vm.selectTab(rtCode)
      vm.selectBase("session")
      check vm.baseLabel == "Session changes"
      check vm.paths == @["src/relay/queue.py", "tests/test_queue.py"]
      check vm.summaryLine == "2 files changed +5 " & Minus & "0"
      check vm.activeTab.val == rtCode
      vm.dispose()
      disposeRoot()

  test "three hundred files":
    createRoot proc(disposeRoot: proc()) =
      let vm = changesOver("code-long")
      check vm.files.len == 300
      check vm.summaryLine == "300 files changed +600 " & Minus & "300"
      vm.dispose()
      disposeRoot()

suite "load states":
  test "loading, an error, and a diff that cannot be read beside a readable record":
    createRoot proc(disposeRoot: proc()) =
      let loading = changesOver("loading")
      check loading.state.val == asLoading
      check loading.notice == ChangesLoadingNotice
      let failing = changesOver("error")
      check failing.state.val == asError
      check failing.error.val == ChangesErrorText
      let noDiff = newScriptedActionSource("a plan whose diff cannot be read")
      noDiff.reviews.add (RelayTaskId, TaskReview(record: relayRecord(), hasPlan: true))
      let vm = newChangesVM(noDiff, relayScope())
      vm.load()
      check vm.state.val == asReady
      check vm.tabLine[1] == "Tests 5"
      vm.selectTab(rtCode)
      check vm.notice == NoDiffDataText
      check vm.summaryLine == NoDiffDataText
      check vm.rollUp(ended = true) == ""
      loading.dispose()
      failing.dispose()
      vm.dispose()
      disposeRoot()
