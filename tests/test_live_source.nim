## `LiveDataSource` against a real, private Agent Harbor server, and
## `SessionTabStripVM` over it.
##
## No mocks: each case starts `ah server start` through nim-agent-harbor's
## `testing/real_server` (fresh state, loopback, its own API key) and drives
## it through the client a front-end uses. The source's feed runs on its
## worker thread; the test is the host and calls `pump()`, as a UI loop does.
##
## Checks sit outside the reactive roots on purpose: a `check` inside a
## closure records its failure in a global and the case still reports OK, so
## each case collects what it saw and asserts afterwards.
##
## When no `ah` binary is available every case is skipped with the reason
## printed. Native only.

import std/[monotimes, net, os, sequtils, strutils, times, unittest]
import isonim/core/[owner, signals]
import nim_everywhere
import nim_agent_harbor
import nim_agent_harbor/testing/real_server
import nim_agents_isonim_viewmodels
import nim_agents_isonim_viewmodels/agent_harbor/live_source

const apiKey = "viewmodels-live-source-key"

proc pumpUntil(source: LiveDataSource; done: proc(): bool;
               seconds = 30): bool =
  ## Pumps as a UI loop would until `done` holds or the deadline passes.
  let deadline = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < deadline:
    discard source.pump()
    if done(): return true
    sleep(20)
  false

proc settle(source: LiveDataSource; ms: int) =
  ## Keeps pumping for `ms`, so late deliveries would show.
  let deadline = getMonoTime() + initDuration(milliseconds = ms)
  while getMonoTime() < deadline:
    discard source.pump()
    sleep(20)

proc gitRepo(dir: string) =
  createDir(dir)
  doAssert execShellCmd("git init -q -b main " & quoteShell(dir)) == 0
  doAssert execShellCmd("git -C " & quoteShell(dir) &
    " -c user.name=live -c user.email=live@example.invalid" &
    " commit -q --allow-empty -m init") == 0

proc createSession(server: RealServer): string =
  ## Creates a session through an independent blocking client and returns
  ## its id.
  let repoDir = server.root / "repo"
  if not dirExists(repoDir): gitRepo(repoDir)
  let creator = newHarborClient(server.baseUrl, nativeTransport(),
    apiKeyAuth(apiKey))
  let created = creator.createTask(probeTask(repoDir, "live source probe"))
  doAssert created.sessionIds.len == 1
  created.sessionIds[0]

let binary = serverBinary()

template needsServer(body: untyped) =
  if binary.len == 0:
    echo "SKIPPED: no Agent Harbor server binary: `ah` is not on PATH and " &
      "AH_SERVER_BIN is unset"
    skip()
  else:
    body

suite "LiveDataSource":
  test "a refused list is an error, never an empty fleet":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let source = newLiveDataSource(server.baseUrl)   # no credentials
      defer: source.close()
      var state = asIdle
      var error = ""
      var tabs = -1
      createRoot proc(disposeRoot: proc()) =
        let strip = newSessionTabStripVM(source)
        strip.load()
        discard source.pumpUntil(proc(): bool = strip.state.val != asLoading)
        state = strip.state.val
        error = strip.error.val
        tabs = strip.tabs.len
        strip.dispose()
        disposeRoot()
      check state == asError
      check "401" in error
      check tabs == 0

  test "an empty server is a ready strip with no tabs":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let source = newLiveDataSource(server.baseUrl, apiKeyAuth(apiKey))
      defer: source.close()
      var state = asIdle
      var tabs = -1
      createRoot proc(disposeRoot: proc()) =
        let strip = newSessionTabStripVM(source)
        strip.load()
        discard source.pumpUntil(proc(): bool =
          strip.state.val != asLoading and source.connected)
        state = strip.state.val
        tabs = strip.tabs.len
        strip.dispose()
        disposeRoot()
      check state == asReady
      check tabs == 0

  test "a session created while following appears within one pump of its frame":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let source = newLiveDataSource(server.baseUrl, apiKeyAuth(apiKey))
      defer: source.close()
      var sessionId = ""
      var createdSeen = false
      var tabsAfterCreatedPump: seq[string] = @[]
      var completed = false
      var finalTabs: seq[string] = @[]
      createRoot proc(disposeRoot: proc()) =
        let strip = newSessionTabStripVM(source)
        # This subscriber and the strip are called in the same pump; the
        # check below runs after that pump returns, so it sees the strip as
        # the frame left it.
        let watch = source.subscribeFleetFrames(proc(
            answer: DataResult[FleetFrame]): ProgressDelivery =
          if answer.ok and answer.value.kind == ffLifecycle:
            let frame = answer.value.lifecycle
            if frame.sessionId == sessionId and sessionId.len > 0:
              if frame.kind == "session_created": createdSeen = true
              if frame.kind == "session_completed": completed = true
          pdUnchanged)
        strip.load()
        doAssert source.pumpUntil(proc(): bool =
          strip.state.val == asReady and source.connected)
        sessionId = server.createSession()
        var checkedCreated = false
        discard source.pumpUntil(proc(): bool =
          if createdSeen and not checkedCreated:
            checkedCreated = true
            tabsAfterCreatedPump = strip.tabs.mapIt(it.id)
          completed)
        finalTabs = strip.tabs.mapIt(it.id)
        watch.cancel()
        strip.dispose()
        disposeRoot()
      check createdSeen
      check sessionId in tabsAfterCreatedPump
      check completed
      check finalTabs == @[sessionId]

  test "opened-only: a new live session is listed, and gets a tab when opened":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let source = newLiveDataSource(server.baseUrl, apiKeyAuth(apiKey))
      defer: source.close()
      var sessionId = ""
      var listedBefore, tabsBefore, listedAfter, tabsAfter: seq[string]
      var opened = false
      createRoot proc(disposeRoot: proc()) =
        let strip = newSessionTabStripVM(source, tabs = tsOpenedOnly)
        strip.load()
        doAssert source.pumpUntil(proc(): bool =
          strip.state.val == asReady and source.connected)
        sessionId = server.createSession()
        discard source.pumpUntil(proc(): bool =
          strip.listedSessions.anyIt(it.id == sessionId))
        listedBefore = strip.listedSessions.mapIt(it.id)
        tabsBefore = strip.tabs.mapIt(it.id)
        opened = strip.openSession(sessionId)
        listedAfter = strip.listedSessions.mapIt(it.id)
        tabsAfter = strip.tabs.mapIt(it.id)
        strip.dispose()
        disposeRoot()
      check listedBefore == @[sessionId]
      check tabsBefore.len == 0
      check opened
      check listedAfter.len == 0
      check tabsAfter == @[sessionId]

  test "a fleet larger than a page loads its newest page and says so":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      var ids: seq[string]
      for i in 0 ..< 3:
        ids.add server.createSession()
        sleep(50)
      let source = newLiveDataSource(server.baseUrl, apiKeyAuth(apiKey),
        fleetPageSize = 2)
      defer: source.close()
      var listed: seq[string]
      var note = ""
      var state = asIdle
      createRoot proc(disposeRoot: proc()) =
        let strip = newSessionTabStripVM(source, tabs = tsOpenedOnly)
        strip.load()
        discard source.pumpUntil(proc(): bool = strip.state.val != asLoading)
        state = strip.state.val
        listed = strip.listedSessions.mapIt(it.id)
        note = strip.partialListingNote
        strip.dispose()
        disposeRoot()
      check state == asReady
      check listed.len == 2
      check ids[0] notin listed            # the oldest is the one left out
      check ids[1] in listed and ids[2] in listed
      check note == "showing newest 2 of 3"

  test "a cursor from another epoch produces exactly one reset":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let source = newLiveDataSource(server.baseUrl, apiKeyAuth(apiKey),
        after = "0000000000000000-1")
      defer: source.close()
      var reasons: seq[string] = @[]
      let resets = source.subscribeResets(proc(
          answer: DataResult[StreamReset]): ProgressDelivery =
        if answer.ok: reasons.add answer.value.reason
        pdApplied)
      check source.pumpUntil(proc(): bool = reasons.len > 0)
      source.settle(1500)
      resets.cancel()
      check reasons.len == 1
      check reasons.len == 1 and "unknown_epoch" in reasons[0]

  test "a quiet feed reconnects from its last cursor without a reset":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      # A short read deadline turns a quiet minute into several reconnects.
      let source = newLiveDataSource(server.baseUrl, apiKeyAuth(apiKey),
        readTimeoutMs = 1000, minBackoffMs = 50, maxBackoffMs = 200)
      defer: source.close()
      var resets = 0
      let sub = source.subscribeResets(proc(
          answer: DataResult[StreamReset]): ProgressDelivery =
        inc resets
        pdApplied)
      check source.pumpUntil(proc(): bool = source.connected and resets == 1)
      let id = server.createSession()
      var lastId = ""
      let frames = source.subscribeFleetFrames(proc(
          answer: DataResult[FleetFrame]): ProgressDelivery =
        if answer.ok and answer.value.kind == ffLifecycle and
            answer.value.lifecycle.sessionId == id:
          lastId = answer.value.lifecycle.cursor
        pdUnchanged)
      check source.pumpUntil(proc(): bool =
        lastId.len > 0 and source.cursor == lastId and
        source.pending == 0)
      let before = source.connections
      source.settle(3500)
      frames.cancel()
      sub.cancel()
      # Each reconnect resumed after the cursor: the server answered
      # caught_up, not resync, so no reset reached the subscriber.
      check source.connections > before
      check resets == 1
      check source.cursor == lastId

  test "a server that comes up later is followed without a new load":
    needsServer:
      let port = freePort()
      let source = newLiveDataSource("http://127.0.0.1:" & $port.int,
        apiKeyAuth(apiKey), minBackoffMs = 50, maxBackoffMs = 400)
      defer: source.close()
      var states: seq[AsyncState] = @[]
      var attemptsBefore = 0
      var finalState = asIdle
      var server: RealServer
      createRoot proc(disposeRoot: proc()) =
        let strip = newSessionTabStripVM(source)
        strip.load()
        discard source.pumpUntil(proc(): bool = strip.state.val != asLoading)
        states.add strip.state.val
        source.settle(1500)
        attemptsBefore = source.connections
        server = startServer(binary, apiKey, port)
        # The feed's first frame on the new server is a resync, delivered as
        # a reset; the strip restarts and loads again by itself.
        discard source.pumpUntil(proc(): bool =
          source.connected and strip.state.val == asReady)
        finalState = strip.state.val
        strip.dispose()
        disposeRoot()
      defer: server.stop()
      check states == @[asError]
      check source.lastError.len > 0 or source.connected
      # Bounded backoff: with no server, attempts kept coming.
      check attemptsBefore >= 3
      check finalState == asReady

  test "after close nothing is delivered and the worker stops at its read deadline":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let source = newLiveDataSource(server.baseUrl, apiKeyAuth(apiKey),
        readTimeoutMs = 1000)
      var delivered = 0
      let sub = source.subscribeFleetFrames(proc(
          answer: DataResult[FleetFrame]): ProgressDelivery =
        inc delivered
        pdUnchanged)
      check source.pumpUntil(proc(): bool = source.connected)
      let started = getMonoTime()
      source.close()
      let closeMs = (getMonoTime() - started).inMilliseconds
      let atClose = delivered
      discard server.createSession()
      sleep(1500)
      check source.pump() == 0
      check delivered == atClose
      # close() does not wait for the worker's blocking read; the worker
      # leaves at its next read deadline (1 s here).
      check closeMs < 500
      check source.stopped
      sub.cancel()
