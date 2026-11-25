## The suggested-actions block's viewmodel (`SuggestedActionsVM`) over its
## two seams -- the front-end's UI-action performer
## (`InstructionRouter.performUiAction`) and Agent Harbor's
## `submitAction`: approve performs the checked actions in order and then
## sends one decision naming exactly them; dismiss performs nothing; a
## second approve while they run does nothing; outcomes and a failed reply
## in the record lines; answers after disposal; an auto-approved suggestion.
##
## No test doubles beyond the seams' own implementations:
## `ScriptedActionPerformer` (outcomes by action id, held until released
## where a test needs an answer to arrive late), `FailingRouter`, and
## `ScriptedActionSource`, which records every action as `$action` writes
## it and answers it from its script -- what the prototype's stories use,
## because the prototypes never write to a server. Every expectation is
## written out by hand. The data is invented (an upload client's retry
## work).

import std/unittest
import isonim/core/[owner, computation]
import nim_agents_isonim_viewmodels

proc act(id, action, description, doneText: string; unavailable = ""): SuggestedAction =
  SuggestedAction(id: id, action: action, description: description, doneText: doneText,
                  unavailable: unavailable)

proc suggestion(): ActionSuggestion =
  ActionSuggestion(requestId: "req-7", sessionId: "sess-upload-retry",
    reason: "Look at the failing retry before changing it.",
    actions: @[
      act("a1", "open-url", "Open the recording of test_retry in a new tab",
          "Opened the recording of test_retry in a new tab"),
      act("a2", "show-panel", "Show the call trace beside the editor",
          "Showed the call trace beside the editor"),
      act("a3", "open-url", "Open the recording of test_retry on macos-arm64", "",
          unavailable = "No recording of test_retry on macos-arm64 has been uploaded")])

var actions: ScriptedActionSource

proc suggestionBlock(performer: InstructionRouter; s = suggestion();
           autoApproved = false): SuggestedActionsVM =
  actions = newScriptedActionSource("test actions")
  newSuggestedActionsVM(s, performer, actions, autoApproved)

proc lineTexts(vm: SuggestedActionsVM): seq[string] =
  for l in vm.recordLines: result.add l.text

suite "the block":
  test "rows: performable ones checked, the other disabled with its reason":
    createRoot proc(dispose: proc()) =
      let vm = suggestionBlock(newScriptedActionPerformer())
      let rows = vm.rows
      check rows.len == 3
      check rows[0].checked and not rows[0].disabled
      check rows[2].disabled and not rows[2].checked
      check rows[2].reason == "No recording of test_retry on macos-arm64 has been uploaded"
      check vm.shown
      check vm.approveLabel == "Approve"
      check vm.recordLines.len == 0
      dispose()

  test "unchecking one dims it and counts it out of the label":
    createRoot proc(dispose: proc()) =
      let vm = suggestionBlock(newScriptedActionPerformer())
      vm.toggle("a2")
      check vm.rows[1].dimmed and not vm.rows[1].checked
      check vm.approveLabel == "Approve 1 of 2"
      vm.toggle("a3")                       # cannot be performed: nothing changes
      check not vm.rows[2].checked
      dispose()

  test "readings are tracked: an effect over them runs again on a toggle and a decision":
    createRoot proc(dispose: proc()) =
      let vm = suggestionBlock(newScriptedActionPerformer())
      var labels: seq[string]
      var records: seq[int]
      createEffect proc() =
        labels.add vm.approveLabel
        records.add vm.recordLines.len
      vm.toggle("a2")
      vm.dismiss()
      check labels == @["Approve", "Approve 1 of 2", "Approve"]
      check records == @[0, 0, 1]
      dispose()

suite "approve":
  test "performs the checked actions in order, then sends one decision naming them":
    createRoot proc(dispose: proc()) =
      let performer = newScriptedActionPerformer()
      performer.answerWith("a2", Receipt(outcome: uoRefused,
                                         result: "the call trace is not in this layout"))
      let vm = suggestionBlock(performer)
      vm.approve()
      check performer.performed.len == 2
      check performer.performed[0].action == "a1"
      check performer.performed[1].action == "a2"
      check actions.record == @["decide-suggestion session=sess-upload-retry " &
                                "request=req-7 decision=approve choices=a1,a2"]
      check vm.phase == spApproved
      check not vm.shown
      check vm.lineTexts == @["Approved 2 UI actions",
        "Opened the recording of test_retry in a new tab",
        "Refused: the call trace is not in this layout"]
      let lines = vm.recordLines
      check lines[0].level == 0 and lines[1].level == 1 and lines[2].textRole == "warning"
      check lines[0].itemKind == UiActionItemKind
      dispose()

  test "the decision is sent only after every action has its outcome":
    createRoot proc(dispose: proc()) =
      let performer = newScriptedActionPerformer()
      performer.hold = true
      let vm = suggestionBlock(performer)
      vm.approve()
      check vm.approving and vm.shown
      check vm.approveDisabledReason == ApprovingLabel
      check performer.performed.len == 1     # the next waits for the first
      check actions.record.len == 0
      vm.approve()                          # a second press: nothing more
      check performer.performed.len == 1
      performer.release()
      check performer.performed.len == 2
      check actions.record.len == 0
      performer.release()
      check actions.record.len == 1
      check vm.phase == spApproved
      dispose()

  test "a performer that fails records each approved action as refused":
    createRoot proc(dispose: proc()) =
      let vm = suggestionBlock(newFailingRouter("the front-end is not ready"))
      vm.toggle("a2")
      vm.approve()
      check vm.lineTexts == @["Approved 1 UI action",
                              "Refused: the front-end is not ready"]
      dispose()

  test "a failed reply keeps the decision and says why":
    createRoot proc(dispose: proc()) =
      let vm = suggestionBlock(newScriptedActionPerformer())
      actions.script.setRule(oaDecideSuggestion, failedWith("the server closed the connection"))
      vm.approve()
      check vm.phase == spApproved
      check vm.lineTexts[^1] == "Could not tell the agent: the server closed the connection"
      check vm.recordLines[^1].textRole == "error"
      dispose()

suite "dismiss":
  test "performs nothing and sends dismiss":
    createRoot proc(dispose: proc()) =
      let performer = newScriptedActionPerformer()
      let vm = suggestionBlock(performer)
      vm.dismiss()
      check performer.performed.len == 0
      check actions.record == @["decide-suggestion session=sess-upload-retry " &
                                "request=req-7 decision=dismiss"]
      check vm.lineTexts == @["Dismissed 3 suggested UI actions"]
      check vm.recordLines[0].textRole == "quiet"
      vm.approve()
      check performer.performed.len == 0
      dispose()

suite "auto-approved":
  test "no block; its action performed at once and recorded with the tag":
    createRoot proc(dispose: proc()) =
      let performer = newScriptedActionPerformer()
      var s = suggestion()
      s.actions = @[s.actions[1]]
      let vm = suggestionBlock(performer, s, autoApproved = true)
      check not vm.shown
      check performer.performed.len == 1
      let lines = vm.recordLines
      check lines.len == 2
      check lines[0].parts[0].text == "Ran 1 UI action"
      check lines[0].parts[1] == LinePart(text: AutoApprovedTag, role: "quiet")
      check lines[1].text == "Showed the call trace beside the editor"
      check lines[1].itemKind == UiActionOutcomeItemKind
      check actions.record == @["decide-suggestion session=sess-upload-retry " &
                                "request=req-7 decision=approve choices=a2"]
      dispose()

suite "disposal":
  test "an answer after dispose changes nothing":
    let performer = newScriptedActionPerformer()
    performer.hold = true
    var vm: SuggestedActionsVM
    createRoot proc(disposeRoot: proc()) =
      vm = suggestionBlock(performer)
      vm.approve()
      vm.dispose()
      disposeRoot()
    performer.release()
    check vm.phase == spApproving
    check vm.decision.outcomes.len == 0
    check performer.performed.len == 1     # the next action is never asked for
    check actions.record.len == 0

  test "an answer after the owner is disposed changes nothing":
    # Disposed with the root it was made under, never by `vm.dispose()`:
    # the late answer is ignored because the ViewModel base marks the block
    # disposed when that root goes.
    let performer = newScriptedActionPerformer()
    performer.hold = true
    var vm: SuggestedActionsVM
    createRoot proc(disposeRoot: proc()) =
      vm = suggestionBlock(performer)
      vm.approve()
      disposeRoot()
    check vm.isDisposed
    performer.release()
    check vm.phase == spApproving
    check vm.decision.outcomes.len == 0
    check performer.performed.len == 1     # the next action is never asked for
    check actions.record.len == 0
