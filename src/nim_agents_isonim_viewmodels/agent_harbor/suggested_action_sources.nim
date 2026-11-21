## The performer of an agent's suggested UI actions, as the prototypes and
## the tests answer it.
##
## An approved suggested action runs "as if the operator had invoked it"
## (agent-harbor `specs/UI-Introspection-and-Steering-Broker.md`,
## `suggest_actions`): it is the front-end that performs it, not Agent
## Harbor, so it goes through the front-end's own seam for UI actions,
## `InstructionRouter.performUiAction` (`instruction_router.nim`), the one the
## omnibox composer's UI-action destination uses. A request names the
## action's id (`UiActionRequest.action`) and says what it does (`text`).
##
## `ScriptedActionPerformer` answers each action by its id, at once or held
## until `release`, so a prototype shows the outcomes a story names and a
## test sees the order actions were asked for. It routes nothing: `route`
## keeps the base answer (the performer does not route instructions).
## `PendingRouter` and `FailingRouter` (`instruction_router.nim`) give the
## performer that never answers and the one that always fails.

import std/tables
import nim_agents/instruction_composer
import ./data_source
import ./instruction_router

export instruction_router

type
  ScriptedActionPerformer* = ref object of InstructionRouter
    outcomes*: Table[string, Receipt]
      ## By action id; an action it holds no outcome for is done.
    failures*: Table[string, string]
      ## By action id: the performer cannot be asked, and why.
    hold*: bool
      ## Hold every answer until `release`.
    held: seq[proc()]
    performed*: seq[UiActionRequest]
      ## What it was asked, in order.

proc newScriptedActionPerformer*(label = "scripted UI-action performer"): ScriptedActionPerformer =
  ScriptedActionPerformer(label: label, outcomes: initTable[string, Receipt](),
                          failures: initTable[string, string]())

proc answerWith*(performer: ScriptedActionPerformer; actionId: string; receipt: Receipt) =
  performer.outcomes[actionId] = receipt

proc failWith*(performer: ScriptedActionPerformer; actionId, reason: string) =
  performer.failures[actionId] = reason

proc pendingAnswers*(performer: ScriptedActionPerformer): int = performer.held.len

proc release*(performer: ScriptedActionPerformer) =
  ## Delivers every held answer, oldest first.
  let held = performer.held
  performer.held = @[]
  for reply in held: reply()

method performUiAction*(performer: ScriptedActionPerformer; request: UiActionRequest;
                        done: UiActionCallback) =
  performer.performed.add request
  let reply =
    if request.action in performer.failures:
      failure[Receipt](performer.failures[request.action])
    elif request.action in performer.outcomes:
      success(performer.outcomes[request.action])
    else:
      success(Receipt(outcome: uoDone))
  let answer = proc() = done(reply)
  if performer.hold: performer.held.add answer else: answer()
