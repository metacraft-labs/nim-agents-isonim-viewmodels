## `InitiativeProgressVM`: one initiative's progress -- its milestones grouped
## by status, the current milestone, the executive summary -- the data of an
## Initiative Progress panel (a GROUPED LIST pattern). A progress event (a
## milestone's status changed in the plan) updates every count once
## (`applyProgress`, over nim-agents' `applyMilestoneStatus`).
##
## Reads through the data-source seam (`loadInitiatives`) and shows the
## initiative named by `initiativeId`; a host follows the Initiatives
## panel's selection with `show`. `load` also subscribes to the source's
## progress events (`subscribeProgress`, through a `ProgressFeed`), so a
## source that sends one moves the panel with no host call; a host may still
## apply one itself (`applyProgress`). Disposing the viewmodel unsubscribes
## it; `progressState` / `progressError` report the feed (an error when the
## source does not provide the events).

import std/strutils
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import ./data_source
import ./progress_feed

export data_source, progress_feed, viewmodel, signals, computation

type
  MilestoneLine* = object
    id*: string
    title*: string
    status*: string
    statusClass*: MilestoneStatusClass
    deliverablesText*: string   ## `2/5 deliverables`, "" when it lists none
    testsText*: string          ## `Tests: 2 passing, 1 failing, 3 pending`, or `no tests`
    failing*: int               ## failing verifications, which a view marks as errors
    current*: bool

  MilestoneGroupView* = object
    status*: MilestoneStatusClass
    title*: string              ## `In progress (2)`
    name*: string               ## `In progress`
    count*: int
    milestones*: seq[MilestoneLine]

  InitiativeProgressVM* = ref object of ViewModel
    source: AgentHarborDataSource
    initiatives: seq[Initiative]
    revision*: Signal[int]
    state*: Signal[AsyncState]
    error*: Signal[string]
    initiativeId*: Signal[string]
    loadToken: int
    feed: ProgressFeed
    progressState*: Signal[AsyncState]
      ## The progress feed: `asIdle` before `load`, `asReady` while subscribed,
      ## `asError` when the source does not provide progress events.
    progressError*: Signal[string]

proc newInitiativeProgressVM*(source: AgentHarborDataSource;
                              initiativeId = ""): InitiativeProgressVM =
  withViewModel proc(dispose: proc()): InitiativeProgressVM =
    let feed = newProgressFeed()
    # Disposing the viewmodel's root unsubscribes it from its source.
    onCleanup proc() = feed.close()
    InitiativeProgressVM(source: source, revision: createSignal(0),
                         state: createSignal(asIdle), error: createSignal(""),
                         initiativeId: createSignal(initiativeId),
                         feed: feed, progressState: feed.state,
                         progressError: feed.error)

proc sourceLabel*(vm: InitiativeProgressVM): string =
  if vm.source.isNil: "" else: vm.source.label

proc applyProgress*(vm: InitiativeProgressVM; event: ProgressEvent): bool =
  ## A progress event, as the source's subscription delivers it. True when it
  ## changed the initiative; an event for an unknown initiative or milestone,
  ## or one that repeats the status, changes nothing and moves no signal.
  if vm.initiatives.applyProgressEvent(event):
    vm.revision.val = vm.revision.val + 1
    return true
  false

proc applyProgress*(vm: InitiativeProgressVM; initiativeId, milestoneId,
                    status: string): bool =
  ## A progress event the host applies itself (the form from before sources
  ## delivered them); the same as the source's delivery.
  vm.applyProgress(ProgressEvent(initiativeId: initiativeId,
                                 milestoneId: milestoneId, status: status))

proc lateProgressEvents*(vm: InitiativeProgressVM): int =
  ## Progress events a source delivered after the viewmodel unsubscribed
  ## (disposed or reloaded); none of them moved it.
  vm.feed.lateEvents

proc load*(vm: InitiativeProgressVM) =
  ## Ready once the initiatives answer. Subscribes to the source's progress
  ## events first, replacing an earlier subscription, so no event falls
  ## between the answer and the subscription.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  let target = vm
  vm.feed.open(vm.source, proc(event: ProgressEvent): bool =
    target.applyProgress(event))
  vm.source.loadInitiatives proc(answer: DataResult[seq[Initiative]]) =
    if token != target.loadToken: return
    if answer.ok:
      target.initiatives = answer.value
      if target.initiativeId.val.len == 0 and answer.value.len > 0:
        target.initiativeId.val = answer.value[0].id
      target.revision.val = target.revision.val + 1
      target.state.val = asReady
    else:
      target.error.val = answer.error
      target.state.val = asError

proc show*(vm: InitiativeProgressVM; id: string) =
  vm.initiativeId.val = id

proc found*(vm: InitiativeProgressVM): bool =
  discard vm.revision.val
  let id = vm.initiativeId.val
  for initiative in vm.initiatives:
    if initiative.id == id: return true

proc current*(vm: InitiativeProgressVM): Initiative =
  ## Tracked: the shown initiative (an empty one when it is unknown).
  discard vm.revision.val
  let id = vm.initiativeId.val
  for initiative in vm.initiatives:
    if initiative.id == id: return initiative

proc groupTitle*(status: MilestoneStatusClass; count: int): string =
  let name = case status
    of mscInProgress: "In progress"
    of mscPartial: "Partially completed"
    of mscBlocked: "Blocked"
    of mscPlanned: "Planned"
    of mscCompleted: "Completed"
    of mscOther: "Other"
  name & " (" & $count & ")"

proc testsText*(v: VerificationCounts): string =
  if v.passing + v.failing + v.pending == 0: return "no tests"
  var parts: seq[string]
  if v.passing > 0: parts.add $v.passing & " passing"
  if v.failing > 0: parts.add $v.failing & " failing"
  if v.pending > 0: parts.add $v.pending & " pending"
  "Tests: " & parts.join(", ")

proc groups*(vm: InitiativeProgressVM): seq[MilestoneGroupView] =
  ## Tracked: the milestones by status class, in-progress first, completed
  ## last, each group in plan order.
  let initiative = vm.current
  for (status, milestones) in milestonesByStatus(initiative.progress):
    var group = MilestoneGroupView(status: status,
                                   title: groupTitle(status, milestones.len),
                                   name: groupTitle(status, milestones.len).split(" (")[0],
                                   count: milestones.len)
    for m in milestones:
      group.milestones.add MilestoneLine(
        id: m.id, title: m.title, status: m.status, statusClass: status,
        deliverablesText:
          if m.deliverables.total == 0: ""
          else: $m.deliverables.done & "/" & $m.deliverables.total & " deliverables",
        testsText: testsText(m.verifications),
        failing: m.verifications.failing,
        current: m.id == initiative.progress.currentMilestone)
    result.add group

proc headline*(vm: InitiativeProgressVM): string =
  ## `3 of 19 milestones · 16%`.
  let p = vm.current.progress
  $p.summary.completedMilestones & " of " & $p.summary.totalMilestones &
    (if p.summary.totalMilestones == 1: " milestone" else: " milestones") &
    " \xC2\xB7 " & $p.summary.progressPercent & "%"

proc statusCounts*(vm: InitiativeProgressVM): array[MilestoneStatusClass, int] =
  statusCounts(vm.current.progress)
