## Reactive view over `nim_agents/activity.ActivityTimeline`. The reducer
## decides what changes; this viewmodel only publishes its revision as a
## signal, so effects and memos that read `entries` re-run when it moves.
import isonim/core/signals
import isonim/viewmodel
import nim_agents
import nim_agents/activity

export activity, viewmodel

type
  ActivityTimelineVM* = ref object of ViewModel
    timeline: ActivityTimeline
    revision*: Signal[int]

proc newActivityTimelineVM*(): ActivityTimelineVM =
  withViewModel proc(dispose: proc()): ActivityTimelineVM =
    ActivityTimelineVM(revision: createSignal(0))

proc publish(vm: ActivityTimelineVM) =
  vm.revision.val = vm.timeline.revision

proc entries*(vm: ActivityTimelineVM): seq[ActivityEntry] =
  ## Tracked read: callers inside a computation depend on `revision`.
  discard vm.revision.val
  vm.timeline.entries

proc turn*(vm: ActivityTimelineVM): int =
  discard vm.revision.val
  vm.timeline.turn

proc beginTurn*(vm: ActivityTimelineVM; text: string) =
  vm.timeline.beginTurn(text)
  vm.publish()

proc reduce*(vm: ActivityTimelineVM; event: AgentEvent): bool {.discardable.} =
  result = vm.timeline.reduce(event)
  if result:
    vm.publish()
