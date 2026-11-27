## `HostFedDataSource`: the data source of a window whose host follows the
## Agent Harbor server for it (manager decision D92: in a desktop app the
## main process follows the server and forwards what it reads to each window
## over IPC). The window's source asks the host for the fleet and is handed
## the host's messages; the session strip reads it as it reads any source.
##
## No mocks: the host's half here is this test, posting the messages a host
## posts (`host_messages.nim`) with the repository's synthetic fleet
## (`fixtures/agent-harbor/fleet/`), and every message crosses the boundary
## as the text IPC carries (`encodeHostMessage` / `decodeHostMessage`). The
## host's own half, the Node follower against a real server, is
## `test_node_follower.nim`.
##
## Checks sit outside the reactive roots: a `check` inside a closure records
## its failure in a global and the case still reports OK, so each case
## collects what it saw and asserts afterwards. Native and JavaScript.

import std/[json, sequtils, strutils, unittest]
import isonim/core/owner
import nim_agents_isonim_viewmodels
import nim_agents_isonim_viewmodels/agent_harbor/[host_messages, host_fed_source]

const
  sessionsJson = staticRead("../fixtures/agent-harbor/fleet/sessions.json")
  firstId = "c43bad2a-276d-40d4-a1e5-19fa40e9e482"
  newId = "0e5f00d1-0000-4000-8000-0000000000aa"

type Asked = ref object
  loads: seq[tuple[loadId, pageSize: int]]

proc asker(asked: Asked): FleetRequest =
  result = proc(loadId, pageSize: int) = asked.loads.add (loadId, pageSize)

proc viaIpc(message: HostMessage): HostMessage =
  ## The message as the window receives it: through the text IPC carries.
  decodeHostMessage(encodeHostMessage(message))

proc fleetAnswer(loadId: int; body = sessionsJson): HostMessage =
  let node = parseJson(body)
  HostMessage(kind: hmFleet, loadId: loadId, ok: true,
    text: $(%*{"items": node["items"], "total": node["items"].len}))

proc created(id, cursor: string): HostMessage =
  HostMessage(kind: hmFrame, stream: hsLifecycle, event: "lifecycle",
    id: cursor, data: $(%*{"kind": "session_created", "sessionId": id,
      "status": "queued", "agent": "claude", "at": "2026-01-15T10:00:00.000Z"}))

proc resync(cursor: string): HostMessage =
  HostMessage(kind: hmFrame, stream: hsLifecycle, event: "resync",
    data: $(%*{"cursor": cursor, "reason": "no_cursor"}))

type Seen = object
  state: AsyncState
  listed: seq[string]
  error: string

proc seen(vm: SessionTabStripVM): Seen =
  Seen(state: vm.state.val, listed: vm.listedSessions.mapIt(it.id),
    error: vm.error.val)

proc run(steps: proc(source: HostFedDataSource; vm: SessionTabStripVM;
                     log: var seq[Seen])): seq[Seen] =
  var log: seq[Seen]
  createRoot proc(disposeRoot: proc()) =
    let source = newHostFedDataSource(asker(Asked()), label = "host: test")
    let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
    steps(source, vm, log)
    vm.dispose()
    disposeRoot()
  log

suite "a window's source, fed by its host":
  test "loading asks the host, and the host's answer is the fleet":
    let asked = Asked()
    var log: seq[Seen]
    createRoot proc(disposeRoot: proc()) =
      let source = newHostFedDataSource(asker(asked), label = "host: test",
                                        fleetPageSize = 200)
      let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
      vm.load()
      log.add vm.seen
      check source.deliver(viaIpc(fleetAnswer(asked.loads[0].loadId)))
      log.add vm.seen
      vm.dispose()
      disposeRoot()
    check asked.loads.len == 1
    check asked.loads[0].pageSize == 200
    check log[0].state == asLoading
    check log[1].state == asReady
    check log[1].listed.len == 48
    check firstId in log[1].listed

  test "a refused listing is an error the strip says, never an empty fleet":
    let asked = Asked()
    var log: seq[Seen]
    createRoot proc(disposeRoot: proc()) =
      let source = newHostFedDataSource(asker(asked))
      let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
      vm.load()
      discard source.deliver(viaIpc(HostMessage(kind: hmFleet,
        loadId: asked.loads[0].loadId, ok: false,
        text: "Harbor session list failed (HTTP 401): unauthorized")))
      log.add vm.seen
      vm.dispose()
      disposeRoot()
    check log[0].state == asError
    check "401" in log[0].error
    check log[0].listed.len == 0

  test "an unreadable listing is an error too":
    let asked = Asked()
    var log: seq[Seen]
    createRoot proc(disposeRoot: proc()) =
      let source = newHostFedDataSource(asker(asked))
      let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
      vm.load()
      discard source.deliver(HostMessage(kind: hmFleet,
        loadId: asked.loads[0].loadId, ok: true, text: "not json"))
      log.add vm.seen
      vm.dispose()
      disposeRoot()
    check log[0].state == asError
    check log[0].error.len > 0

  test "a session created on the server joins the list from its frame":
    let asked = Asked()
    var log: seq[Seen]
    createRoot proc(disposeRoot: proc()) =
      let source = newHostFedDataSource(asker(asked))
      let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
      vm.load()
      discard source.deliver(viaIpc(fleetAnswer(asked.loads[0].loadId)))
      discard source.deliver(viaIpc(created(newId, "e1-49")))
      log.add vm.seen
      check source.cursor == "e1-49"
      vm.dispose()
      disposeRoot()
    check newId in log[0].listed
    check log[0].listed.len == 49

  test "a resync is a reset: the strip loads again":
    let asked = Asked()
    var cursor = ""
    createRoot proc(disposeRoot: proc()) =
      let source = newHostFedDataSource(asker(asked))
      let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
      vm.load()
      discard source.deliver(viaIpc(fleetAnswer(asked.loads[0].loadId)))
      discard source.deliver(viaIpc(resync("e2-0")))
      cursor = source.cursor
      vm.dispose()
      disposeRoot()
    check asked.loads.len == 2
    check asked.loads[1].loadId != asked.loads[0].loadId
    check cursor == "e2-0"

  test "the connection's state is the host's":
    var states: seq[(bool, string, int)]
    discard run(proc(source: HostFedDataSource; vm: SessionTabStripVM;
                     log: var seq[Seen]) =
      states.add (source.connected, source.lastError, source.connections)
      discard source.deliver(viaIpc(HostMessage(kind: hmConnecting)))
      discard source.deliver(viaIpc(HostMessage(kind: hmConnected)))
      states.add (source.connected, source.lastError, source.connections)
      discard source.deliver(viaIpc(HostMessage(kind: hmDisconnected,
        text: "the feed ended")))
      states.add (source.connected, source.lastError, source.connections))
    check states[0] == (false, "", 0)
    check states[1] == (true, "", 1)
    check states[2] == (false, "the feed ended", 1)

  test "an answer to a load the window did not ask for is ignored":
    let asked = Asked()
    var handled = true
    var log: seq[Seen]
    createRoot proc(disposeRoot: proc()) =
      let source = newHostFedDataSource(asker(asked))
      let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
      vm.load()
      handled = source.deliver(fleetAnswer(asked.loads[0].loadId + 100))
      log.add vm.seen
      vm.dispose()
      disposeRoot()
    check not handled
    check log[0].state == asLoading

  test "after close nothing is delivered and nothing is asked":
    let asked = Asked()
    var handled = true
    var log: seq[Seen]
    createRoot proc(disposeRoot: proc()) =
      let source = newHostFedDataSource(asker(asked))
      let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
      vm.load()
      discard source.deliver(fleetAnswer(asked.loads[0].loadId))
      source.close()
      handled = source.deliver(created(newId, "e1-49"))
      log.add vm.seen
      var answered = ""
      source.loadFleet(proc(r: DataResult[FleetSnapshot]) =
        answered = if r.ok: "ok" else: r.error)
      log.add Seen(error: answered)
      vm.dispose()
      disposeRoot()
    check not handled
    check newId notin log[0].listed
    check asked.loads.len == 1
    check "closed" in log[1].error

suite "the messages, as IPC carries them":
  test "every kind round-trips through its text":
    let messages = @[
      HostMessage(kind: hmConnecting, stream: hsLifecycle),
      HostMessage(kind: hmConnected, stream: hsLifecycle),
      HostMessage(kind: hmDisconnected, stream: hsLifecycle, text: "stalled"),
      created(newId, "e1-7"),
      HostMessage(kind: hmFleet, loadId: 3, ok: false, text: "refused"),
      fleetAnswer(4)]
    for message in messages:
      check viaIpc(message) == message

  test "a text that is not a message is refused, naming why":
    for text in ["", "not json", "[]", """{"kind": "nonsense"}""",
                 """{"kind": "fleet", "loadId": "x"}"""]:
      var refused = false
      try:
        discard decodeHostMessage(text)
      except ValueError as error:
        refused = error.msg.len > 0
      check refused
