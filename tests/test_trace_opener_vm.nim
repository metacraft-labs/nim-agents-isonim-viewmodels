## The trace opener (`TraceOpenerVM`): a trace Agent Harbor holds connects,
## replays and asks the host to open it once, or is unavailable with the
## reason (and a Retry unless the trace is gone); a recording on this machine
## is opened at once with no action sent; downloads; one state per trace
## whatever form names it; and the placement sentences.
##
## Test doubles, and why each is justified:
##
## - `TraceLinkSource` (through `traceLinkFixture`) is the prototypes'
##   production source for trace links: opening a trace starts a replay
##   host, which the prototypes may not do, so every press is answered from
##   its script (per trace for replays and downloads) and recorded.
## - `NoActions` leaves `submitAction` to the seam's base: a source with no
##   way to send an action, which must never show a trace replaying.
##
## Expected values are written out by hand from the invented links
## (`synthetic_test_runs.nim`).

import std/[strutils, unittest]
import isonim/core/[owner, signals]
import nim_agents/agent_harbor/trace_links
import nim_agents_isonim_viewmodels

type NoActions = ref object of AgentHarborDataSource

proc ah(id: string; query = ""): TraceReference =
  let text = AgentHarborTracePrefix & id & (if query.len > 0: "?" & query else: "")
  let parse = parseTraceReference(text, TestRunsServer)
  doAssert parse.ok, parse.reason
  parse.reference

proc opener(fixture: string): (TraceOpenerVM, TraceLinkSource) =
  let source = traceLinkFixture(fixture)
  (newTraceOpenerVM(source, TestRunsSessionId, initiativeId = "relay-backpressure"), source)

suite "loading a trace Agent Harbor holds":
  test "test_trace_opener_vm_connects_then_replays_and_asks_the_host_once":
    createRoot proc(disposeRoot: proc()) =
      let (vm, source) = opener("replaying")
      source.script.setRule(oaOpenTraceReplay, neverAnswered())
      let trace = ah(OneTraceId)
      check vm.buttonText(trace) == LoadTraceText
      check vm.titleText(trace) == "Load trace " & OneTraceId & " in a replay near it (" &
        TestRunsServer & "/trace/" & OneTraceId & "). Opens in a new tab; Ctrl+click opens it in this tab."
      vm.load(trace)
      check vm.stateOf(trace).phase == rpConnecting
      check vm.buttonText(trace) == ConnectingText
      check not vm.canPress(trace)
      check source.record == @["open-trace-replay session=" & TestRunsSessionId &
                               " trace=" & OneTraceId]
      check vm.requests.val == 0
      # A press while connecting sends nothing.
      vm.load(trace)
      check source.record.len == 1
      source.script.settle(0, ok = true)
      check vm.stateOf(trace).phase == rpReplaying
      check vm.buttonText(trace) == ShowTraceText
      check vm.requests.val == 1
      check vm.requestedTrace.val.reference.id == OneTraceId
      check vm.requestedTrace.val.destination == tdNewTab
      # The initiative heard it load, then turn ready.
      check vm.recordingEvents.val == 2
      check vm.recordingEvent.val.entry.state == rsReady
      check vm.recordingEvent.val.initiativeId == "relay-backpressure"
      # Pressed again: shown in the tab it has, with no new replay.
      vm.load(trace)
      check source.record.len == 1
      check vm.requests.val == 2
      check vm.requestedTrace.val.destination == tdOwnTab
      check vm.titleText(trace).endsWith(OpensInOwnTabText)
      vm.dispose()
      disposeRoot()

  test "test_trace_opener_vm_unavailable_after_a_failed_receipt_with_retry":
    createRoot proc(disposeRoot: proc()) =
      let (vm, source) = opener("unavailable")
      let trace = ah(OneTraceId)
      vm.load(trace)
      let state = vm.stateOf(trace)
      check state.phase == rpUnavailable
      check state.canRetry
      check vm.errorText(trace) == "Replay unavailable: no replay host is free near the trace"
      check vm.canRetry(trace)
      check vm.requests.val == 0
      check vm.recordingEvent.val.entry.state == rsFailed
      source.replayAnswers = @[]
      vm.retry(trace)
      check source.record.len == 2
      check vm.stateOf(trace).phase == rpReplaying
      check vm.requests.val == 1
      vm.dispose()
      disposeRoot()

  test "a trace that is gone offers no Retry, and a press sends nothing":
    createRoot proc(disposeRoot: proc()) =
      let (vm, source) = opener("gone")
      let trace = ah(OneTraceId)
      vm.load(trace)
      check vm.errorText(trace) == "Replay unavailable: " & TraceGoneText
      check not vm.canRetry(trace)
      check not vm.canPress(trace)
      vm.retry(trace)
      vm.load(trace)
      check source.record.len == 1
      vm.dispose()
      disposeRoot()

  test "a source without actions shows the trace unavailable, never replaying":
    createRoot proc(disposeRoot: proc()) =
      let source = NoActions(label: "reads only")
      let vm = newTraceOpenerVM(source)
      let trace = ah(OneTraceId)
      vm.load(trace)
      check vm.stateOf(trace).phase == rpUnavailable
      check vm.errorText(trace) ==
        "Replay unavailable: the data source 'reads only' does not provide operator actions"
      check vm.requests.val == 0
      vm.dispose()
      disposeRoot()

  test "one state per trace, whatever form names it, read by every surface":
    createRoot proc(disposeRoot: proc()) =
      let (vm, _) = opener("many-links")
      let parse = parseTraceReference(TestRunsServer & "/trace/" & OneTraceId, TestRunsServer)
      check parse.ok
      vm.load(ah(OneTraceId))
      check vm.stateOf(parse.reference).phase == rpReplaying
      check vm.buttonText(parse.reference) == ShowTraceText
      check vm.stateOf(ah(SecondTraceId)).phase == rpIdle
      vm.dispose()
      disposeRoot()

suite "a recording on this machine":
  test "test_trace_opener_vm_local_recording_opens_with_no_action":
    createRoot proc(disposeRoot: proc()) =
      let (vm, source) = opener("local-recording")
      let parse = parseTraceReference("codetracer://recordings/test_queue_bound_holds?mode=refresh", "")
      check parse.ok and parse.reference.kind == trkLocalRecording
      let rec = parse.reference
      check vm.buttonText(rec) == OpenRecordingText
      check vm.titleText(rec) == "Open the recording of test_queue_bound_holds on this machine. " &
        "Opens in a new tab; Ctrl+click opens it in this tab."
      vm.load(rec)
      check source.record.len == 0
      check vm.requests.val == 1
      check vm.requestedTrace.val.reference.url ==
        "codetracer://recordings/test_queue_bound_holds?mode=refresh"
      check vm.stateOf(rec).phase == rpIdle
      check not vm.canDownload(rec)
      vm.download(rec)
      check source.record.len == 0
      check vm.downloadOf(rec).phase == dpIdle
      check vm.recordingEvents.val == 0
      vm.dispose()
      disposeRoot()

suite "downloads":
  test "saved with the receipt's name, failed with the reason, downloading while unanswered":
    createRoot proc(disposeRoot: proc()) =
      let (saved, savedSource) = opener("download")
      let trace = ah(OneTraceId)
      saved.download(trace)
      check savedSource.record == @["download-trace session=" & TestRunsSessionId &
                                    " trace=" & OneTraceId]
      check saved.downloadStatus(trace) == "Saved relay-depth-metric.ct"
      check saved.stateOf(trace).phase == rpIdle   # a download starts no replay
      let (failed, _) = opener("download-failed")
      failed.download(trace)
      check failed.downloadStatus(trace) == "Download failed: the trace store refused: quota exceeded"
      let (held, heldSource) = opener("one-link")
      heldSource.script.setRule(oaDownloadTrace, neverAnswered())
      held.download(trace)
      check held.downloadStatus(trace) == "Downloading\xE2\x80\xA6"
      check not held.canDownload(trace)
      held.download(trace)
      check heldSource.record.len == 1
      for vm in [saved, failed, held]: vm.dispose()
      disposeRoot()

suite "where a trace opens":
  test "the placement sentences and destinations":
    var ctx = PlacementContext()
    check ctx.placementSentence(false) == "Opens in a new tab; Ctrl+click opens it in this tab."
    check ctx.destinationOf(false) == tdNewTab
    ctx.modifierHeld = true
    check ctx.placementSentence(false) ==
      "Opens in this tab, ending its session; release Ctrl opens a new tab."
    check ctx.destinationOf(false) == tdCurrentTab
    ctx = PlacementContext(policy: tdCurrentTab)
    check ctx.placementSentence(false) ==
      "Opens in this tab, ending its session; Ctrl+click opens a new tab."
    check ctx.destinationOf(false) == tdCurrentTab
    ctx.cannotReplace = true
    check ctx.placementSentence(false) == OpensInNewTabText
    check ctx.destinationOf(false) == tdNewTab
    check ctx.placementSentence(true) == OpensInOwnTabText
    check ctx.destinationOf(true) == tdOwnTab
    check traceReferenceOf(OneTraceId, "").id == OneTraceId
    check traceReferenceOf(AgentHarborTracePrefix & OneTraceId, "").kind == trkAgentHarbor
    check traceReferenceOf("../etc", "").id == ""

  test "the host's placement moves the title and the request":
    createRoot proc(disposeRoot: proc()) =
      let (vm, _) = opener("one-link")
      vm.placement.val = PlacementContext(policy: tdCurrentTab)
      let trace = ah(OneTraceId)
      check vm.titleText(trace).endsWith("Opens in this tab, ending its session; Ctrl+click opens a new tab.")
      vm.load(trace)
      check vm.requestedTrace.val.destination == tdCurrentTab
      vm.forget(trace)
      check not vm.hasTab(trace)
      vm.dispose()
      disposeRoot()
