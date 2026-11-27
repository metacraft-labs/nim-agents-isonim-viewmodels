## The live data source: the fleet of a real Agent Harbor server, over
## nim-agent-harbor's client (CTF-M3 slice 2).
##
## It serves the fleet and its lifecycle, which is what the session strip
## and the fleet panels read:
##
## - `loadFleet` answers from `GET /api/v1/sessions`, every page. A refused
##   or unreadable listing answers an error, never an empty fleet.
## - `subscribeFleetFrames` delivers each frame of
##   `GET /api/v1/session-lifecycle/events` as a lifecycle `FleetFrame`.
## - `subscribeResets` delivers a `StreamReset` whenever the feed answers
##   `resync`: the server could not replay from the source's cursor (or the
##   source had none), so what a subscriber folded may be stale and it loads
##   again. The first connection always starts with one.
## - Every other load and subscription answers through the base methods,
##   that the source does not provide it, so nothing renders as empty.
##
## **Threads.** Viewmodels are single-threaded and the feed blocks, so the
## network runs on worker threads and the host delivers on its own thread:
## one worker follows the feed for the source's life, and each `loadFleet`
## runs on a short-lived worker. Workers only read the network and post
## plain messages to a channel; nothing they hold is shared. The host calls
## `pump()` from its UI loop, which drains the channel and calls the
## subscribers and the load callbacks on the host's thread. No callback is
## ever called from a worker, and no load answers inside the load call.
##
## **Reconnecting.** When the feed ends, stalls past `readTimeoutMs` or is
## refused, the feed worker connects again with the last cursor it read, so
## the server replays what was missed and answers `caught_up`; only when the
## server cannot replay does a `resync`, and so a reset, follow. Between
## failed attempts it waits `minBackoffMs`, doubling to `maxBackoffMs`; a
## connection that delivered a frame resets the wait.
##
## **Closing.** `close()` returns at once: it tells the workers to stop and
## drops the subscribers, and nothing is delivered after it. A worker inside
## a blocking read leaves at that read's deadline (the feed's
## `readTimeoutMs`, a load's control deadline); the source keeps it, and its
## channel, until it has, and joins it then.
##
## Native only: the JavaScript front-end is fed by its host.

when defined(js):
  {.error: "the live Agent Harbor data source is native only".}

import std/[atomics, json, os, tables, times]
import nim_agent_harbor
import nim_agents/agent_harbor/[fleet_records, fleet_fold]
import ./data_source

type
  MessageKind = enum
    mkConnecting   ## the feed worker opens a connection
    mkConnected    ## that connection delivered its first frame
    mkDisconnected ## it ended or failed; `text` says why
    mkFrame        ## one feed frame: `event`, `data`, `id`
    mkFleet        ## a listing answered: `ok`, then `text` is the JSON body
                   ## or the error

  Message = object
    kind: MessageKind
    event, data, id: string
    ok: bool
    text: string
    loadId: int

  Shared = object
    ## What the host and the workers share. Allocated in shared memory and
    ## freed only when every worker that holds it has been joined.
    channel: Channel[Message]
    stop: Atomic[bool]

  Connection = object
    baseUrl: string
    authKind: AuthKind
    token: string

  FeedArgs = object
    conn: Connection
    shared: ptr Shared
    after: string
    readTimeoutMs, minBackoffMs, maxBackoffMs: int

  LoadArgs = object
    conn: Connection
    shared: ptr Shared
    loadId: int

  LiveDataSource* = ref object of AgentHarborDataSource
    conn: Connection
    shared: ptr Shared
    feed: ref Thread[FeedArgs]
    loads: seq[ref Thread[LoadArgs]]
    pendingLoads: Table[int, FleetCallback]
    nextLoad: int
    frameSubscribers: Subscribers[FleetFrame]
    resetSubscribers: Subscribers[StreamReset]
    lastCursor: string
    isConnected: bool
    error: string
    connectionCount: int
    closed: bool

  Retired = object
    ## A closed source's workers that had not finished, and their channel.
    shared: ptr Shared
    feed: ref Thread[FeedArgs]
    loads: seq[ref Thread[LoadArgs]]

var retired {.threadvar.}: seq[Retired]

proc nowMs(): int64 = int64(epochTime() * 1000)

proc clientOf(conn: Connection): HarborClient =
  newNativeHarborClient(conn.baseUrl,
    HarborAuth(kind: conn.authKind, token: conn.token))

proc stopping(shared: ptr Shared): bool = shared.stop.load()

proc post(shared: ptr Shared; message: sink Message) =
  shared.channel.send(message)

# ---------------------------------------------------------------------------
# Workers
# ---------------------------------------------------------------------------

proc waitOrStop(shared: ptr Shared; ms: int) =
  var left = ms
  while left > 0 and not shared.stopping:
    sleep(min(left, 20))
    left -= 20

proc followFeed(args: FeedArgs) {.thread.} =
  ## The feed worker: follow the lifecycle feed until told to stop,
  ## reconnecting from the last cursor read.
  {.cast(gcsafe).}:
    var client = clientOf(args.conn)
    client.frameStreamTransport = nativeHarborFrameStream(args.readTimeoutMs)
    let shared = args.shared
    var cursor = args.after
    var wait = args.minBackoffMs
    while not shared.stopping:
      shared.post Message(kind: mkConnecting)
      var delivered = false
      try:
        client.followSessionLifecycle(proc(frame: SseFrame): bool =
          if shared.stopping: return false
          if not delivered:
            delivered = true
            shared.post Message(kind: mkConnected)
          # The cursor to resume from: a lifecycle frame's id, or the
          # cursor in a resync or caught_up frame's data.
          let decoded = lifecycleFrameOf(frame.event, frame.data, frame.id)
          if decoded.cursor.len > 0: cursor = decoded.cursor
          shared.post Message(kind: mkFrame, event: frame.event,
            data: frame.data, id: frame.id)
          true, after = cursor)
        if not shared.stopping:
          shared.post Message(kind: mkDisconnected, text: "the feed ended")
      except CatchableError as error:
        if not shared.stopping:
          shared.post Message(kind: mkDisconnected, text: error.msg)
      if delivered: wait = args.minBackoffMs
      shared.waitOrStop(wait)
      if not delivered: wait = min(wait * 2, args.maxBackoffMs)

proc loadOnce(args: LoadArgs) {.thread.} =
  ## A listing worker: read every page and post the result as JSON text.
  {.cast(gcsafe).}:
    var message = Message(kind: mkFleet, loadId: args.loadId)
    try:
      let items = clientOf(args.conn).listAllSessions()
      var node = newJObject()
      var list = newJArray()
      for item in items: list.add item
      node["items"] = list
      node["total"] = %items.len
      message.ok = true
      message.text = $node
    except CatchableError as error:
      message.text = error.msg
    if not args.shared.stopping:
      args.shared.post message

# ---------------------------------------------------------------------------
# Retiring workers after close
# ---------------------------------------------------------------------------

proc finished[T](thread: ref Thread[T]): bool =
  thread.isNil or not thread[].running

proc reapRetired() =
  ## Joins the workers of closed sources that have finished, and frees their
  ## channel once all of a source's have.
  var kept: seq[Retired]
  for entry in retired.mitems:
    var loads: seq[ref Thread[LoadArgs]]
    for load in entry.loads:
      if load.finished: joinThread(load[]) else: loads.add load
    entry.loads = loads
    if not entry.feed.isNil and entry.feed.finished:
      joinThread(entry.feed[])
      entry.feed = nil
    if entry.feed.isNil and entry.loads.len == 0:
      entry.shared.channel.close()
      deallocShared(entry.shared)
    else:
      kept.add entry
  retired = kept

# ---------------------------------------------------------------------------
# The source
# ---------------------------------------------------------------------------

proc newLiveDataSource*(baseUrl: string; auth = HarborAuth(kind: akNone);
                        after = ""; readTimeoutMs = 30_000;
                        minBackoffMs = 250; maxBackoffMs = 30_000): LiveDataSource =
  ## A source over the server at `baseUrl`, starting its feed worker now.
  ## `after` resumes the feed from a cursor a previous source applied ("" for
  ## none). `readTimeoutMs` is how long the feed may stay silent before the
  ## worker reconnects; a quiet fleet costs one reconnect per period.
  reapRetired()
  let shared = cast[ptr Shared](allocShared0(sizeof(Shared)))
  shared.channel.open()
  let conn = Connection(baseUrl: baseUrl, authKind: auth.kind, token: auth.token)
  result = LiveDataSource(label: "live: " & baseUrl, conn: conn,
    shared: shared, pendingLoads: initTable[int, FleetCallback](),
    lastCursor: after)
  new result.feed
  createThread(result.feed[], followFeed, FeedArgs(conn: conn, shared: shared,
    after: after, readTimeoutMs: readTimeoutMs,
    minBackoffMs: max(1, minBackoffMs),
    maxBackoffMs: max(minBackoffMs, maxBackoffMs)))

proc connected*(source: LiveDataSource): bool =
  ## True while the feed's current connection has delivered a frame.
  source.isConnected

proc lastError*(source: LiveDataSource): string =
  ## Why the feed's last connection ended ("" while connected).
  source.error

proc connections*(source: LiveDataSource): int =
  ## The feed connections opened so far, pumped.
  source.connectionCount

proc cursor*(source: LiveDataSource): string =
  ## The cursor of the last frame delivered: what a later source passes as
  ## `after` to resume where this one stopped.
  source.lastCursor

proc pending*(source: LiveDataSource): int =
  ## Messages the workers posted that `pump()` has not delivered yet.
  if source.closed: 0 else: source.shared.channel.peek()

proc stopped*(source: LiveDataSource): bool =
  ## True once the feed worker has finished (after `close`, at its read
  ## deadline).
  source.feed.finished

proc deliverFrame(source: LiveDataSource; message: Message) =
  let frame = lifecycleFrameOf(message.event, message.data, message.id)
  if frame.cursor.len > 0: source.lastCursor = frame.cursor
  let at = nowMs()
  discard source.frameSubscribers.broadcast(
    success(lifecycleFrame(frame, if frame.atMs > 0: frame.atMs else: at)))
  if frame.event == "resync":
    discard source.resetSubscribers.broadcast(success(StreamReset(atMs: at,
      reason: "the server could not replay the feed (" & frame.reason & ")")))

proc pump*(source: LiveDataSource): int =
  ## Delivers what the workers have posted, on the caller's thread: frames
  ## and resets to the subscribers, listings to the loads waiting for them.
  ## Returns the number of messages handled. Call it from the UI loop; it
  ## never blocks.
  if source.closed: return 0
  var loads: seq[ref Thread[LoadArgs]]
  for load in source.loads:
    if load.finished: joinThread(load[]) else: loads.add load
  source.loads = loads
  while not source.closed:
    let (got, message) = source.shared.channel.tryRecv()
    if not got: break
    inc result
    case message.kind
    of mkConnecting:
      inc source.connectionCount
    of mkConnected:
      source.isConnected = true
      source.error = ""
    of mkDisconnected:
      source.isConnected = false
      source.error = message.text
    of mkFrame:
      source.deliverFrame(message)
    of mkFleet:
      var done: FleetCallback
      if source.pendingLoads.pop(message.loadId, done):
        if not message.ok:
          done(failure[FleetSnapshot](message.text))
        else:
          try:
            done(success(fleetSnapshotFromJson(parseJson(message.text),
              nowMs(), source.label)))
          except CatchableError as error:
            done(failure[FleetSnapshot]("unreadable session list: " & error.msg))

proc close*(source: LiveDataSource) =
  ## Stops the source: nothing is delivered after it returns, and waiting
  ## loads are never answered. It does not wait for a worker's blocking read.
  if source.closed: return
  source.closed = true
  source.shared.stop.store(true)
  source.pendingLoads.clear()
  source.frameSubscribers = Subscribers[FleetFrame]()
  source.resetSubscribers = Subscribers[StreamReset]()
  retired.add Retired(shared: source.shared, feed: source.feed,
    loads: source.loads)
  source.loads = @[]
  reapRetired()

method loadFleet*(source: LiveDataSource; done: FleetCallback) =
  ## Lists every session on a worker; `done` is called from `pump()`.
  if source.closed:
    done(failure[FleetSnapshot]("the live source is closed"))
    return
  inc source.nextLoad
  let id = source.nextLoad
  source.pendingLoads[id] = done
  var thread: ref Thread[LoadArgs]
  new thread
  createThread(thread[], loadOnce, LoadArgs(conn: source.conn,
    shared: source.shared, loadId: id))
  source.loads.add thread

method subscribeFleetFrames*(source: LiveDataSource;
    callback: FeedCallback[FleetFrame]): Subscription[FleetFrame] =
  source.frameSubscribers.subscribe(callback)

method subscribeResets*(source: LiveDataSource;
    callback: FeedCallback[StreamReset]): Subscription[StreamReset] =
  source.resetSubscribers.subscribe(callback)
