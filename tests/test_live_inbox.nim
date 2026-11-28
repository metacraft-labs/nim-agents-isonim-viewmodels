## `LiveDataSource`'s inbox and its cursor, and `InboxVM` over it: a press
## switches before the server answers, the posts go out in the order pressed,
## a second front-end on the same cursor follows a step made in the first,
## and a server without the inbox stream says so once.
##
## Test doubles, and why each is justified:
##
## - `FakeHarbor` serves `GET /api/v1/inbox?cursor=`, `GET /api/v1/inbox/events`
##   and `POST /api/v1/inbox/cursors/{name}/next|prev` in the REST contract's
##   shapes, keeping the cursor by nim-agents' rules (`walkNext`, `walkPrev`,
##   `aheadOf`). No Agent Harbor build serves the inbox stream or the cursor
##   routes yet (`ah` 0.6.17 answers both 404), so nothing real can answer a
##   press; it holds a post back on request, the only way to show a press
##   that does not wait for its answer. Its cursor-block and `ahead` shapes are
##   the same guesses nim-agents' readers make, named there in test names.
##   These cases move to a real server when one serves the routes.
## - The last case runs against a real `ah server` (nim-agent-harbor's
##   `testing/real_server`), which serves the inbox and not its stream: it is
##   skipped, with the reason printed, when no `ah` binary is available.
##
## The test is the host: it calls `pump()`, as a UI loop does. Checks sit
## outside the reactive roots, as in `test_live_source.nim`. Native only.

import std/[asyncdispatch, asynchttpserver, asyncnet, atomics, json, locks, monotimes,
            net, os, strutils, times, unittest]
import isonim/core/[owner, signals]
import nim_agent_harbor
import nim_agent_harbor/testing/real_server
import nim_agents/agent_harbor/[inbox, inbox_cursor]
import nim_agents_isonim_viewmodels
import nim_agents_isonim_viewmodels/agent_harbor/live_source

# ---------------------------------------------------------------------------
# The fake server
# ---------------------------------------------------------------------------

const
  Ids = ["item-a", "item-b", "item-c"]
  Epoch = "e1"

var
  stateLock: Lock
  cursor: InboxCursor          ## guarded by stateLock
  version: int64               ## guarded by stateLock
  frames: seq[string]          ## guarded by stateLock: `changed` frames sent
  postBodies: seq[string]      ## guarded by stateLock
  inboxReads: int              ## guarded by stateLock: reads answered
  holdPosts: Atomic[bool]
  stopServer: Atomic[bool]

initLock(stateLock)

proc order(): seq[InboxItemRef] =
  for id in Ids: result.add InboxItemRef(id: id)

proc itemJson(id: string): JsonNode =
  let at = Ids.find(id)
  %*{"id": id, "kind": "blocked_question",
     "session": {"id": "s-" & id, "title": "Session " & id, "host": "host-a",
                 "agent": "Claude", "status": "running", "label": "Session " & id},
     "priority": "normal", "effectivePriority": "normal", "position": at + 1,
     "explanation": "Normal priority", "enteredAt": "2026-11-27T08:01:00Z",
     "question": "Which?"}

proc refsJson(refs: seq[InboxItemRef]): JsonNode =
  result = newJArray()
  for r in refs: result.add %r.id

proc aheadJson(): JsonNode =
  let ahead = aheadOf(order(), cursor, AheadDepth, version)
  %*{"next": refsJson(ahead.next), "prev": refsJson(ahead.prev), "basedOn": version}

proc itemIdJson(): JsonNode =
  if cursor.current.isNone: newJNull() else: %cursor.current.id

proc readJson(): JsonNode =
  var items = newJArray()
  for id in Ids: items.add itemJson(id)
  %*{"items": items, "generatedAt": "2026-11-27T08:05:00Z",
     "cursor": {"name": "default", "itemId": itemIdJson(),
                "visitedDepth": cursor.visited.len, "cursorVersion": version},
     "ahead": aheadJson()}

proc sseChunk(frame: string): string =
  ## One frame as one chunk of a chunked response body.
  toHex(frame.len).strip(chars = {'0'}, trailing = false) & "\r\n" & frame & "\r\n"

proc handle(req: Request) {.async, gcsafe.} =
  {.cast(gcsafe).}:
    let path = req.url.path
    let json = newHttpHeaders([("Content-Type", "application/json")])
    if req.reqMethod == HttpGet and path == "/api/v1/inbox":
      var body: string
      withLock stateLock:
        body = $readJson()
        inc inboxReads
      await req.respond(Http200, body, json)
    elif req.reqMethod == HttpGet and path == "/api/v1/inbox/events":
      await req.client.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
        "Cache-Control: no-cache\r\nTransfer-Encoding: chunked\r\n\r\n")
      await req.client.send(sseChunk("event: resync\nid: " & Epoch &
        ":0\ndata: {\"reason\":\"connected\"}\n\n"))
      var sent: int
      withLock stateLock: sent = frames.len
      var quietMs = 0
      while not stopServer.load and not req.client.isClosed:
        var next: seq[string]
        withLock stateLock:
          if sent < frames.len: next = frames[sent .. ^1]
        for frame in next:
          await req.client.send(sseChunk(frame))
          inc sent
        # A comment line every half second of silence, as a server keeps a
        # quiet stream open, so the source's 2 s read deadline never ends
        # it and a reconnect's resync never lands in the middle of a case.
        if next.len > 0: quietMs = 0
        elif quietMs >= 500:
          await req.client.send(sseChunk(":keepalive\n\n"))
          quietMs = 0
        await sleepAsync(10)
        quietMs += 10
    elif req.reqMethod == HttpPost and path.startsWith("/api/v1/inbox/cursors/default/"):
      withLock stateLock: postBodies.add req.body
      while holdPosts.load and not stopServer.load:
        await sleepAsync(5)
      var answer: JsonNode
      withLock stateLock:
        let moved =
          if path.endsWith("/next"): walkNext(order(), cursor).moved
          else: walkPrev(order(), cursor).moved
        if moved: inc version
        answer = %*{"item": (if cursor.current.isNone: newJNull()
                             else: itemJson(cursor.current.id)),
                    "visitedDepth": cursor.visited.len, "cursorVersion": version,
                    "ahead": aheadJson()}
        if moved:
          let data = %*{"reasons": ["cursor"], "cursors": [{"name": "default",
            "itemId": itemIdJson(), "cursorVersion": version, "ahead": aheadJson()}]}
          frames.add "event: changed\nid: " & Epoch & ":" & $(frames.len + 1) &
            "\ndata: " & $data & "\n\n"
      await req.respond(Http200, $answer, json)
    else:
      await req.respond(Http404, "{\"status\":404,\"detail\":\"API route not found\"}", json)

proc serve(port: Port) {.thread.} =
  {.cast(gcsafe).}:
    let server = newAsyncHttpServer()
    server.listen(port, "127.0.0.1")
    var accepting: Future[void]
    while not stopServer.load:
      if accepting.isNil or accepting.finished:
        accepting = server.acceptRequest(handle)
      try: poll(10)
      except ValueError: discard   # nothing pending
    server.close()

type FakeHarbor = object
  port: Port
  thread: ref Thread[Port]

proc startFake(): FakeHarbor =
  withLock stateLock:
    cursor = InboxCursor()
    version = 0
    frames = @[]
    postBodies = @[]
    inboxReads = 0
  holdPosts.store(false)
  stopServer.store(false)
  result.port = freePort()
  new result.thread
  createThread(result.thread[], serve, result.port)
  sleep(100)

proc stop(fake: FakeHarbor) =
  stopServer.store(true)
  joinThread(fake.thread[])

proc baseUrl(fake: FakeHarbor): string = "http://127.0.0.1:" & $fake.port.int

proc readsAnswered(): int =
  withLock stateLock: result = inboxReads

proc posted(): seq[JsonNode] =
  withLock stateLock:
    for body in postBodies: result.add parseJson(body)

# ---------------------------------------------------------------------------
# Pumping
# ---------------------------------------------------------------------------

proc pumpUntil(sources: openArray[LiveDataSource]; done: proc(): bool;
               timeoutMs = 10_000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    for source in sources: discard source.pump()
    if done(): return true
    sleep(5)
  false

suite "LiveDataSource: the inbox and its cursor (fake server)":
  test "a press switches before the server answers, and the posts go out in the order pressed":
    let fake = startFake()
    defer: fake.stop()
    let source = newLiveDataSource(fake.baseUrl, readTimeoutMs = 2_000)
    defer: source.close()
    var loaded, resynced, firstShown, secondShown, pendingAfterFour, settled = false
    var afterAnswer = ""
    var inFlightHeld = -1
    createRoot proc(disposeRoot: proc()) =
      let vm = newInboxVM(source)
      vm.load()
      loaded = [source].pumpUntil(proc(): bool = vm.state.val == asReady)
      # The stream's first frame is a resync, which forgets the targets and
      # reads again (once the load has landed, if it comes first): press only
      # once that read is taken, or the first press waits for it, as it
      # should, and the case shows nothing.
      resynced = [source].pumpUntil(proc(): bool =
        source.connected(skInbox) and readsAnswered() >= 2 and
          vm.heldAhead.known and vm.heldAhead.next.len == 3)
      holdPosts.store(true)
      # Three presses switch at once, with every post held at the server.
      discard vm.next()
      firstShown = vm.current.val.id == "item-a"
      discard vm.next()
      secondShown = vm.current.val.id == "item-b"
      discard vm.next()
      discard vm.next()          # beyond the three targets the read held
      pendingAfterFour = vm.cursorPending.val and vm.current.val.id == "item-a"
      inFlightHeld = vm.inFlight
      holdPosts.store(false)
      settled = [source].pumpUntil(proc(): bool = vm.inFlight == 0)
      afterAnswer = vm.current.val.id
      vm.dispose()
      disposeRoot()
    check loaded
    check resynced
    check firstShown
    check secondShown
    check pendingAfterFour
    check inFlightHeld == 4
    check settled
    # From item-a the server's Next is the top excluding it: item-b.
    check afterAnswer == "item-b"
    let posts = posted()
    check posts.len == 4
    check posts[0]["landedOn"].getStr == "item-a"
    check posts[0]["expectedVersion"].getInt == 0
    check posts[1]["landedOn"].getStr == "item-b"
    check posts[2]["landedOn"].getStr == "item-a"
    check not posts[3].hasKey("landedOn")

  test "a second front-end on the same cursor follows a step made in the first, within one pump of the frame":
    let fake = startFake()
    defer: fake.stop()
    let deviceA = newLiveDataSource(fake.baseUrl, readTimeoutMs = 2_000)
    let deviceB = newLiveDataSource(fake.baseUrl, readTimeoutMs = 2_000)
    defer: deviceA.close()
    defer: deviceB.close()
    var ready, streaming, followed, followedBack = false
    var bTab = ""
    createRoot proc(disposeRoot: proc()) =
      let a = newInboxVM(deviceA)
      let b = newInboxVM(deviceB)
      a.load()
      b.load()
      ready = [deviceA, deviceB].pumpUntil(proc(): bool =
        a.state.val == asReady and b.state.val == asReady)
      # Both streams' resyncs read again: step only once both reads are
      # taken, so B can follow A's step only through the stream's notice.
      streaming = [deviceA, deviceB].pumpUntil(proc(): bool =
        deviceA.connected(skInbox) and deviceB.connected(skInbox) and
          readsAnswered() >= 4 and a.heldAhead.known and b.heldAhead.known)
      discard a.next()
      followed = [deviceA, deviceB].pumpUntil(proc(): bool =
        b.current.val.id == "item-a")
      bTab = b.requestedSession.val
      discard b.prev()           # nothing visited before item-a: wraps to item-c
      followedBack = [deviceA, deviceB].pumpUntil(proc(): bool =
        a.current.val.id == "item-c")
      a.dispose()
      b.dispose()
      disposeRoot()
    check ready
    check streaming
    check followed
    check bTab == "s-item-a"
    check followedBack

  test "a closed source answers a read and a post with an error, and posts nothing":
    # The empty inbox's negative control (no press posts) is the viewmodel's,
    # in test_inbox_vm.
    let fake = startFake()
    defer: fake.stop()
    let source = newLiveDataSource(fake.baseUrl, readTimeoutMs = 2_000)
    source.close()
    var readError, postError = ""
    source.loadInboxRead("default", proc(answer: DataResult[InboxRead]) =
      readError = answer.error)
    source.postInboxCursor("default", CursorPost(direction: pdNext),
      proc(answer: DataResult[CursorAnswer]) = postError = answer.error)
    check "closed" in readError
    check "closed" in postError
    sleep(50)
    check posted().len == 0

let binary = serverBinary()

suite "LiveDataSource: the inbox on a server without its stream (real server)":
  test "the read answers with no cursor, and the missing stream is said once":
    if binary.len == 0:
      echo "SKIPPED: no Agent Harbor server binary: `ah` is not on PATH and " &
        "AH_SERVER_BIN is unset"
      skip()
    else:
      let server = startServer(binary, "test-key")
      defer: server.stop()
      let source = newLiveDataSource(server.baseUrl, apiKeyAuth("test-key"),
                                     readTimeoutMs = 2_000)
      defer: source.close()
      var state = asIdle
      var count = -1
      var gone = false
      var connectionsAfterGone = -1
      createRoot proc(disposeRoot: proc()) =
        let vm = newInboxVM(source)
        vm.load()
        discard [source].pumpUntil(proc(): bool = vm.state.val != asLoading)
        state = vm.state.val
        count = vm.count
        gone = [source].pumpUntil(proc(): bool =
          "does not serve the inbox stream" in source.lastError(skInbox))
        # Counted from the moment the 404 is said, not from the start: on a
        # loaded host the first connection can fail another way (a read
        # timeout) and be retried before the server's 404 arrives, which is
        # the worker's ordinary backoff, not a second "gone".
        let atGone = source.connections(skInbox)
        sleep(1_000)   # four times the worker's 250 ms minimum backoff
        discard source.pump()
        connectionsAfterGone = source.connections(skInbox) - atGone
        vm.dispose()
        disposeRoot()
      check state == asReady
      check count == 0
      check gone
      check connectionsAfterGone == 0   # said once, never asked again
