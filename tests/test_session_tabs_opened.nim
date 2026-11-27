## The session strip in its opened-only mode, the product's rule (operator
## decision, 2026-11-26): a session gets a tab only when the operator opens
## it; every other listed session waits in the session list, the switcher
## tabs are opened from.
##
## No mocks: the strip loads through `SnapshotDataSource` (a state source
## serving a listing built here) and receives lifecycle frames through its
## own `applyFleetFrame`, the entry point a source's subscription calls. The
## same rule against a live server is in `test_live_source.nim`.
##
## Checks sit outside the reactive roots: a `check` inside a closure records
## its failure in a global and the case still reports OK.

import std/[sequtils, unittest]
import isonim/core/owner
import nim_agents_isonim_viewmodels

const Now = 1_800_000_000_000'i64

proc fleet(ids: varargs[string]): FleetSnapshot =
  result = FleetSnapshot(capturedAtMs: Now)
  for i, id in ids:
    result.sessions.add FleetSession(id: id, status: fsRunning,
      createdAtMs: Now - 1000 + i)

proc created(id: string): FleetFrame =
  lifecycleFrame(LifecycleFrame(event: "lifecycle", kind: "session_created",
    sessionId: id, status: "queued"), Now)

proc removed(id: string): FleetFrame =
  lifecycleFrame(LifecycleFrame(event: "lifecycle", kind: "session_removed",
    sessionId: id), Now)

type Seen = object
  tabs, listed: seq[string]
  active: string

proc seen(vm: SessionTabStripVM): Seen =
  Seen(tabs: vm.tabs.mapIt(it.id), listed: vm.listedSessions.mapIt(it.id),
    active: vm.activeId.val)

proc run(snapshot: FleetSnapshot; steps: proc(vm: SessionTabStripVM;
         log: var seq[Seen])): seq[Seen] =
  var log: seq[Seen]
  createRoot proc(disposeRoot: proc()) =
    let vm = newSessionTabStripVM(newSnapshotDataSource(snapshot),
      tabs = tsOpenedOnly)
    vm.load()
    log.add vm.seen
    steps(vm, log)
    vm.dispose()
    disposeRoot()
  log

suite "opened-only session strip":
  test "listed sessions wait in the list, with no tab and none active":
    let log = run(fleet("a", "b", "c")) do (vm: SessionTabStripVM; log: var seq[Seen]):
      discard
    check log[0].tabs.len == 0
    check log[0].listed == @["a", "b", "c"]
    check log[0].active == ""

  test "opening moves a session from the list to the strip and activates it":
    var opened: seq[bool]
    let log = run(fleet("a", "b", "c")) do (vm: SessionTabStripVM; log: var seq[Seen]):
      opened.add vm.openSession("b")
      log.add vm.seen
      opened.add vm.openSession("a")
      log.add vm.seen
      opened.add vm.openSession("b")       # already open: activates it only
      log.add vm.seen
      opened.add vm.openSession("missing") # not listed
      log.add vm.seen
    check opened == @[true, true, false, false]
    check log[1].tabs == @["b"]
    check log[1].listed == @["a", "c"]
    check log[1].active == "b"
    # Tabs stay in the order they were opened.
    check log[2].tabs == @["b", "a"]
    check log[2].listed == @["c"]
    check log[2].active == "a"
    check log[3].tabs == @["b", "a"]
    check log[3].active == "b"
    check log[4] == log[3]

  test "closing returns the session to the list and stops nothing":
    let log = run(fleet("a", "b", "c")) do (vm: SessionTabStripVM; log: var seq[Seen]):
      discard vm.openSession("a")
      discard vm.openSession("b")
      discard vm.close("b")
      log.add vm.seen
      discard vm.close("a")
      log.add vm.seen
    check log[1].tabs == @["a"]
    check log[1].active == "a"
    # Back in the list at its launch place.
    check log[1].listed == @["b", "c"]
    check log[2].tabs.len == 0
    check log[2].active == ""
    check log[2].listed == @["a", "b", "c"]

  test "a new session joins the list, not the strip":
    let log = run(fleet("a")) do (vm: SessionTabStripVM; log: var seq[Seen]):
      discard vm.openSession("a")
      discard vm.applyFleetFrame(created("n"))
      log.add vm.seen
    check log[1].tabs == @["a"]
    check log[1].listed == @["n"]
    check log[1].active == "a"

  test "a removed session leaves whichever it was in":
    let log = run(fleet("a", "b", "c")) do (vm: SessionTabStripVM; log: var seq[Seen]):
      discard vm.openSession("a")
      discard vm.openSession("b")
      discard vm.applyFleetFrame(removed("b"))   # open and active
      log.add vm.seen
      discard vm.applyFleetFrame(removed("c"))   # only listed
      log.add vm.seen
    check log[1].tabs == @["a"]
    check log[1].active == "a"
    check log[1].listed == @["c"]
    check log[2].tabs == @["a"]
    check log[2].listed.len == 0

  test "a session is never both a tab and in the list":
    let log = run(fleet("a", "b", "c", "d")) do (vm: SessionTabStripVM; log: var seq[Seen]):
      discard vm.openSession("c")
      discard vm.openSession("a")
      discard vm.applyFleetFrame(created("e"))
      discard vm.close("c")
      discard vm.openSession("e")
      log.add vm.seen
    let last = log[^1]
    for id in last.tabs: check id notin last.listed
    check (last.tabs & last.listed).len == 5

  test "the opened tabs survive a source reset":
    let log = run(fleet("a", "b")) do (vm: SessionTabStripVM; log: var seq[Seen]):
      discard vm.openSession("b")
      vm.restart()
      log.add vm.seen
    check log[1].tabs == @["b"]
    check log[1].listed == @["a"]

  test "the list says when it holds only the newest part of the fleet":
    var notes: seq[string]
    var fleetOf3 = fleet("a", "b", "c")
    fleetOf3.total = 10                    # the server has 10; 3 were read
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTabStripVM(newSnapshotDataSource(fleetOf3),
        tabs = tsOpenedOnly)
      vm.load()
      notes.add vm.partialListingNote
      discard vm.applyFleetFrame(created("n"))      # one more on the server
      notes.add vm.partialListingNote
      discard vm.applyFleetFrame(removed("a"))
      notes.add vm.partialListingNote
      vm.dispose()
      disposeRoot()
    var whole: string
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTabStripVM(newSnapshotDataSource(fleet("a", "b")),
        tabs = tsOpenedOnly)
      vm.load()
      whole = vm.partialListingNote
      vm.dispose()
      disposeRoot()
    check notes == @["showing newest 3 of 10", "showing newest 4 of 11",
                     "showing newest 3 of 10"]
    check whole == ""

  test "the default mode still shows every listed session as a tab":
    var tabs, listed: seq[string]
    createRoot proc(disposeRoot: proc()) =
      let vm = newSessionTabStripVM(newSnapshotDataSource(fleet("a", "b")))
      vm.load()
      tabs = vm.tabs.mapIt(it.id)
      listed = vm.listedSessions.mapIt(it.id)
      vm.dispose()
      disposeRoot()
    check tabs == @["a", "b"]
    check listed.len == 0
