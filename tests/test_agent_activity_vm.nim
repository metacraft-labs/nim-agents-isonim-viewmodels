## AgentActivityVM (`agent_panels/agent_activity_vm`), native and JS: the
## Agent Activity panel's conversation, its `ct test` run cards through the
## host's `testRunProjector` (D90), its evidence cards through the host's
## `reviewOpen`, a recording opened through the host's `traceOpen`, and the
## prompt's state. The viewmodel keeps the host store it is given and reads
## nothing from it. The projector here is a stand-in for the host's
## recogniser, so these cases need no runner wire format: what they check is
## that the viewmodel asks it, keeps its answer and acts on it. Real IsoNim
## reactive core, real nim-agents rules. The data is invented, as everything in
## this public repository.

import std/[options, unittest]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import nim_agents/activity_model
import nim_agents_isonim_viewmodels/agent_panels/agent_activity_vm

const
  CollectCommand =
    "ct review collect --diff main..HEAD --recordings .ct/runs -o review.json"

proc message(id, content: string): AgentActivityMessageEntry =
  AgentActivityMessageEntry(id: id, content: content, role: aamrAgent)

proc toolCall(id, command, toolCallId: string): AgentActivityMessageEntry =
  AgentActivityMessageEntry(id: id, content: command, role: aamrAgent,
                            toolName: command, toolCallId: toolCallId)

proc toolUpdate(id, toolCallId, status: string): AgentActivityMessageEntry =
  AgentActivityMessageEntry(id: id, role: aamrAgent, toolCallId: toolCallId,
                            status: status)

proc summaryOf(rows: varargs[TestRunRow]): TestRunSummary =
  result = newTestRunSummary()
  result.rows = @rows
  result.passed = rows.len

proc runsMarkedRun(messages: openArray[AgentActivityMessageEntry]):
    seq[AgentTestRunEntry] =
  ## Stand-in recogniser: a message whose content is "RUN" is a run with one
  ## recorded test and one unrecorded one.
  for m in messages:
    if m.content == "RUN":
      result.add AgentTestRunEntry(anchorId: m.id, summary: summaryOf(
        TestRunRow(testId: "a::recorded", outcome: troPassed,
                   tracePath: "/tmp/a.ct", traceId: "7", recordingId: "r-1"),
        TestRunRow(testId: "a::plain", outcome: troPassed)))

suite "AgentActivityVM":
  test "a new viewmodel is an idle, empty panel":
    createRoot proc(dispose: proc()) =
      let vm = newAgentActivityVM()
      check vm.store.isNil
      check vm.testRunProjector.isNil
      check vm.messageCount.val == 0
      check not vm.hasMessages.val
      check vm.terminalCount.val == 0
      check vm.testRunCount.val == 0
      check vm.evidenceCallCount.val == 0
      check vm.inputValue.val == ""
      check not vm.isLoading.val
      check vm.sessionKey.val == ""
      check not vm.hasSessionNotice.val
      check vm.settingsRuntime.val == "devcontainer"
      check vm.settingsPermissions.val == "Ask before commands"
      dispose()

  test "the host store is kept as given":
    createRoot proc(dispose: proc()) =
      let store = ViewModel()
      let vm = newAgentActivityVM(store)
      check vm.store == store
      dispose()

  test "with no projector no message is a run":
    createRoot proc(dispose: proc()) =
      let vm = newAgentActivityVM()
      vm.setMessages(@[message("m:0", "RUN"), message("m:1", "hello")])
      check vm.messageCount.val == 2
      check vm.hasMessages.val
      check vm.testRunCount.val == 0
      check vm.testRunIndex("m:0") == -1
      check vm.testRunFor("m:0").isNone
      check not vm.openTestRecording("m:0", "a::recorded")
      dispose()

  test "the projector's runs are kept, anchored and re-derived":
    createRoot proc(dispose: proc()) =
      var asked = 0
      let vm = newAgentActivityVM(nil,
        proc(messages: openArray[AgentActivityMessageEntry]):
            seq[AgentTestRunEntry] =
          inc asked
          runsMarkedRun(messages))
      vm.setMessages(@[message("m:0", "hello"), message("m:1", "RUN")])
      check asked == 1
      check vm.testRunCount.val == 1
      check vm.testRunIndex("m:1") == 0
      check vm.testRunIndex("m:0") == -1
      check vm.testRunFor("m:1").get.totalTests == 2
      vm.setMessages(@[message("m:0", "hello")])
      check asked == 2
      check vm.testRunCount.val == 0
      dispose()

  test "a run card expands, and its tests expand on their own":
    createRoot proc(dispose: proc()) =
      let vm = newAgentActivityVM(nil, runsMarkedRun)
      vm.setMessages(@[message("m:0", "RUN")])
      check not vm.isTestRunExpanded("m:0")
      vm.toggleTestRun("m:0")
      check vm.isTestRunExpanded("m:0")
      vm.toggleTest("m:0", "a::plain")
      check vm.isTestExpanded("m:0", "a::plain")
      check not vm.isTestExpanded("m:0", "a::recorded")
      vm.toggleTestRun("m:0")
      check not vm.isTestRunExpanded("m:0")
      check expansionKey("m:0", "a") != expansionKey("m:0a", "")
      dispose()

  test "only a recorded test opens, through the host, with its trace":
    createRoot proc(dispose: proc()) =
      let vm = newAgentActivityVM(nil, runsMarkedRun)
      var opened: seq[TraceOpenRequest]
      vm.traceOpen = TraceOpenService(
        openProc: proc(request: TraceOpenRequest) = opened.add request)
      vm.setMessages(@[message("m:0", "RUN")])
      check vm.openTestRecording("m:0", "a::recorded", topNewTab)
      check opened.len == 1
      check opened[0] == TraceOpenRequest(tracePath: "/tmp/a.ct",
        traceId: "7", recordingId: "r-1", testId: "a::recorded",
        policy: topNewTab)
      check not vm.openTestRecording("m:0", "a::plain")
      check not vm.openTestRecording("m:0", "a::absent")
      check not vm.openTestRecording("m:9", "a::recorded")
      check opened.len == 1
      dispose()

  test "a recorded test with no host reports it opened nothing it could":
    createRoot proc(dispose: proc()) =
      let vm = newAgentActivityVM(nil, runsMarkedRun)
      vm.setMessages(@[message("m:0", "RUN")])
      # No `traceOpen`: the request is silence, and the answer is still
      # whether the row had a recording to open.
      check vm.openTestRecording("m:0", "a::recorded")
      dispose()

  test "a completed evidence call is inspected once, then opened":
    createRoot proc(dispose: proc()) =
      let vm = newAgentActivityVM()
      var requests: seq[ReviewDatasetRequest]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      let conversation = @[toolCall("s:0", CollectCommand, "t1"),
                           toolUpdate("s:1", "t1", "completed")]
      vm.setMessages(conversation)
      vm.setMessages(conversation)
      check vm.evidenceCallCount.val == 1
      check requests.len == 1
      check requests[0] == ReviewDatasetRequest(anchorId: "s:0",
        datasetPath: "review.json", kind: rdrInspect)
      check not vm.openEvidence("s:0")
      vm.applyEvidenceDataset("review.json",
        EvidenceDataset(state: edsReady, fileCount: 2))
      check vm.evidenceCallFor("s:0").get.dataset.fileCount == 2
      check vm.openEvidence("s:0")
      check requests.len == 2
      check requests[1].kind == rdrOpen
      check not vm.openEvidence("s:9")
      dispose()

  test "an inspection asked with no host is asked again once there is one":
    createRoot proc(dispose: proc()) =
      let vm = newAgentActivityVM()
      vm.setMessages(@[toolCall("s:0", CollectCommand, "t1"),
                       toolUpdate("s:1", "t1", "completed")])
      var requests: seq[ReviewDatasetRequest]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      vm.retryPendingEvidenceInspections()
      check requests.len == 1
      check requests[0].datasetPath == "review.json"
      dispose()

  test "the prompt's attachments, flags and settings":
    createRoot proc(dispose: proc()) =
      let vm = newAgentActivityVM()
      vm.addContextPath("src/a.nim")
      vm.addContextPath("src/a.nim")
      vm.addContextPath("src/b.nim")
      check vm.getContextPaths() == @["src/a.nim", "src/b.nim"]
      vm.removeContextPath(0)
      check vm.getContextPaths() == @["src/b.nim"]
      let slot = vm.addPastedImageLoading()
      vm.updatePastedImage(slot, "data:image/png;base64,AA==")
      check vm.getPastedImages() == @["data:image/png;base64,AA=="]
      vm.setPromptFlags(true, false)
      check vm.wantsPassword.val and not vm.wantsPermission.val
      vm.setSessionNotice("Session unavailable")
      check vm.hasSessionNotice.val
      vm.settingsRuntime.val = "local"
      vm.settingsActiveDropdown.val = "runtime"
      vm.toggleSettingsOpen()
      check vm.settingsOpen.val
      check vm.settingsActiveDropdown.val == ""
      vm.resetSettingsToDefaults()
      check vm.settingsRuntime.val == "devcontainer"
      dispose()

  test "clearing the conversation resets what belonged to it":
    createRoot proc(dispose: proc()) =
      let vm = newAgentActivityVM(nil, runsMarkedRun)
      vm.setMessages(@[message("m:0", "RUN"),
                       toolCall("s:0", CollectCommand, "t1"),
                       toolUpdate("s:1", "t1", "completed")])
      vm.toggleTestRun("m:0")
      vm.toggleThought("m:0")
      vm.applyEvidenceDataset("review.json",
        EvidenceDataset(state: edsReady, fileCount: 1))
      vm.setInputValue("draft")
      vm.setLoading(true)
      vm.addContextPath("src/a.nim")
      vm.clearConversation()
      check vm.messageCount.val == 0
      check vm.testRunCount.val == 0
      check vm.evidenceCallCount.val == 0
      check not vm.isTestRunExpanded("m:0")
      check not vm.isThoughtToggled("m:0")
      check vm.datasetFor("review.json").state == edsUnknown
      check vm.inputValue.val == ""
      check not vm.isLoading.val
      check vm.getContextPaths().len == 0
      check vm.testRunProjector != nil
      dispose()
