## ActivityTimelineVM publishes reducer changes through its revision signal
## and stays silent when the reducer reports no change. Real reducer, real
## IsoNim reactive core; no mocks.
import std/unittest
import isonim/core/[computation, owner]
import nim_agents
import nim_agents_isonim_viewmodels

suite "ActivityTimelineVM":
  test "effects re-run on reducer changes only":
    createRoot proc(disposeRoot: proc()) =
      let vm = newActivityTimelineVM()
      var runs = 0
      var seen = 0
      createEffect proc() =
        inc runs
        seen = vm.entries.len
      check runs == 1
      check seen == 0

      vm.beginTurn("hello")
      check runs == 2
      check seen == 1
      check vm.turn == 1

      check vm.reduce(AgentEvent(kind: aekMessageChunk, text: "hi"))
      check runs == 3
      check seen == 2

      let before = runs
      let duplicate = AgentEvent(kind: aekMessageChunk, text: "x",
        sessionId: "s", eventId: "e1")
      check vm.reduce(duplicate)
      check not vm.reduce(duplicate)
      check runs == before + 1
      vm.dispose()
      disposeRoot()
