## The composer's own seam: the routing agent that decides where an
## instruction typed in the omnibox goes, and the agent that performs UI
## actions in the front-end. Both are the front-end's, not Agent Harbor's:
## everything the composer asks of an Agent Harbor server (an instruction to
## a session or a manager, a launch, a new initiative, a stop) is an
## `OperatorAction` sent through `AgentHarborDataSource.submitAction`, the one
## way anything is asked of a server (`data_source.nim`), and the prototypes
## answer it from a script (`scripted_actions.nim`).
##
## Two calls, each asynchronous by contract (the router calls `done` once,
## possibly inside the call, possibly much later, possibly never):
##
## - `route`: the routing agent's decision for an instruction and the context
##   the window offers (`RoutingDecision`: destination, intent, reason,
##   citations);
## - `performUiAction`: the UI-action agent does what the instruction asks of
##   the front-end (open a pane, move the replay, arrange the layout),
##   answered with its outcome (`Receipt`: done, refused, partly done).
##
## Base methods answer that the router does not provide the call, so a
## router that serves part of the composer fails visibly.
##
## The routers here produce the states a prototype shows: `ScriptedRouter`
## (decisions by instruction, a UI action's outcome, optionally held until
## `release`), `newPendingRouter` (never answers: a routing agent that hangs)
## and `newFailingRouter` (every call fails with one reason). A live router
## answers the same calls; a viewmodel built on this seam does not change
## when it is swapped in.

import std/tables
import nim_agents/instruction_composer
import ./data_source

export instruction_composer, data_source

type
  RouteRequest* = object
    text*: string
    context*: seq[ContextItem]   ## what the window offers, operator's choices marked
    targets*: seq[RouteTarget]   ## the destinations the window can reach

  UiActionRequest* = object
    text*: string
    action*: string              ## what the router said the UI action does
    cited*: seq[ContextItem]     ## only what the instruction cites

  RouteCallback* = proc(answer: DataResult[RoutingDecision])
  UiActionCallback* = proc(answer: DataResult[Receipt])

  InstructionRouter* = ref object of RootObj
    label*: string

proc unsupported(router: InstructionRouter; what: string): string =
  "the router '" & router.label & "' does not " & what

method route*(router: InstructionRouter; request: RouteRequest;
              done: RouteCallback) {.base.} =
  done(failure[RoutingDecision](router.unsupported("route instructions")))

method performUiAction*(router: InstructionRouter; request: UiActionRequest;
                        done: UiActionCallback) {.base.} =
  done(failure[Receipt](router.unsupported("perform UI actions")))

# ---------------------------------------------------------------------------
# A scripted router
# ---------------------------------------------------------------------------

type
  ScriptedRouter* = ref object of InstructionRouter
    decisions*: Table[string, RoutingDecision]
      ## By instruction text (trimmed).
    defaultDecision*: RoutingDecision
    hasDefault*: bool
    routeFailure*: string
      ## Non-empty: every route fails with it.
    uiOutcome*: Receipt
      ## What a UI action answers.
    uiFailure*: string
      ## Non-empty: every UI action fails with it.
    hold*: bool
      ## Hold every answer until `release`.
    held: seq[proc()]
    routed*: seq[RouteRequest]
      ## What it was asked, in order (a host's log, and a test's).
    performed*: seq[UiActionRequest]

proc newScriptedRouter*(label = "scripted router"): ScriptedRouter =
  ScriptedRouter(label: label, decisions: initTable[string, RoutingDecision]())

proc decide*(router: ScriptedRouter; text: string; decision: RoutingDecision) =
  router.decisions[text] = decision

proc decideByDefault*(router: ScriptedRouter; decision: RoutingDecision) =
  router.defaultDecision = decision
  router.hasDefault = true

proc answer(router: ScriptedRouter; reply: proc()) =
  if router.hold: router.held.add reply else: reply()

proc pendingAnswers*(router: ScriptedRouter): int = router.held.len

proc release*(router: ScriptedRouter) =
  ## Delivers every held answer, oldest first.
  let held = router.held
  router.held = @[]
  for reply in held: reply()

proc releaseOne*(router: ScriptedRouter) =
  ## Delivers the oldest held answer.
  if router.held.len == 0: return
  let reply = router.held[0]
  router.held.delete(0)
  reply()

proc trimmed(s: string): string =
  var a = 0
  var b = s.len - 1
  while a <= b and s[a] in {' ', '\t', '\n', '\r'}: inc a
  while b >= a and s[b] in {' ', '\t', '\n', '\r'}: dec b
  if a > b: "" else: s[a .. b]

method route*(router: ScriptedRouter; request: RouteRequest;
              done: RouteCallback) =
  router.routed.add request
  let key = trimmed(request.text)
  var reply: DataResult[RoutingDecision]
  if router.routeFailure.len > 0:
    reply = failure[RoutingDecision](router.routeFailure)
  elif key in router.decisions:
    reply = success(router.decisions[key])
  elif router.hasDefault:
    reply = success(router.defaultDecision)
  else:
    reply = failure[RoutingDecision]("the routing agent has no decision for this instruction")
  router.answer(proc() = done(reply))

method performUiAction*(router: ScriptedRouter; request: UiActionRequest;
                        done: UiActionCallback) =
  router.performed.add request
  let reply = if router.uiFailure.len > 0: failure[Receipt](router.uiFailure)
              else: success(router.uiOutcome)
  router.answer(proc() = done(reply))

# ---------------------------------------------------------------------------
# Pending and failing routers
# ---------------------------------------------------------------------------

type
  PendingRouter* = ref object of InstructionRouter
    calls*: int

proc newPendingRouter*(label = "a router that does not answer"): PendingRouter =
  PendingRouter(label: label)

method route*(router: PendingRouter; request: RouteRequest; done: RouteCallback) =
  inc router.calls

method performUiAction*(router: PendingRouter; request: UiActionRequest;
                        done: UiActionCallback) =
  inc router.calls

type
  FailingRouter* = ref object of InstructionRouter
    reason*: string

proc newFailingRouter*(reason: string; label = "a failing router"): FailingRouter =
  FailingRouter(label: label, reason: reason)

method route*(router: FailingRouter; request: RouteRequest; done: RouteCallback) =
  done(failure[RoutingDecision](router.reason))

method performUiAction*(router: FailingRouter; request: UiActionRequest;
                        done: UiActionCallback) =
  done(failure[Receipt](router.reason))
