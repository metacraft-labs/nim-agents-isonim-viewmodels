## The data source of a window whose host follows the Agent Harbor server for
## it.
##
## In a desktop app the main process follows the server and forwards what it
## reads to each window (manager decision D92): the window never connects to
## the server and never holds its key, and the app keeps one connection
## however many windows it has. This source is the window's half. It serves
## the fleet and its lifecycle, as the native `LiveDataSource` does:
##
## - `loadFleet` asks the host for the newest page (`FleetRequest`, with a
##   load id and the page size) and answers when the host's `hmFleet`
##   message for that id is delivered. A refused or unreadable listing
##   answers an error, never an empty fleet.
## - `subscribeFleetFrames` delivers each `hmFrame` of the lifecycle stream
##   as a lifecycle `FleetFrame`.
## - `subscribeResets` delivers a `StreamReset` when a frame is `resync`: the
##   server could not replay from the host's cursor, so what a subscriber
##   folded may be stale and it loads again.
##
## The host hands each message it receives to `deliver`, on the window's
## thread (its IPC handler), so a callback is never called from anywhere
## else, and never inside the `loadFleet` call. The host's half on Node is
## `node_follower.nim`; the messages are `host_messages.nim`.
##
## What `deliver` does with each message mirrors `LiveDataSource.pump`, kept
## separate while `live_source.nim` is being extended with the inbox stream
## (CTF-M7); the two are to share one delivery once that lands.
##
## Pure: native and JavaScript.

import std/[json, tables, times]
import nim_agents/agent_harbor/[fleet_records, fleet_fold]
import ./data_source
import ./host_messages

export host_messages

type
  FleetRequest* = proc(loadId, pageSize: int) {.closure.}
    ## Asks the host for the newest `pageSize` sessions; the host answers
    ## with an `hmFleet` message carrying `loadId`.

  StreamState = object
    connected: bool
    error: string
    connections: int
    cursor: string

  HostFedDataSource* = ref object of AgentHarborDataSource
    request: FleetRequest
    states: array[HostStream, StreamState]
    pendingLoads: Table[int, FleetCallback]
    nextLoad: int
    pageSize: int
    frameSubscribers: Subscribers[FleetFrame]
    resetSubscribers: Subscribers[StreamReset]
    closed: bool

proc nowMs(): int64 = int64(epochTime() * 1000)

proc newHostFedDataSource*(request: FleetRequest; label = "host";
                           fleetPageSize = 200): HostFedDataSource =
  ## A source the host feeds through `deliver`. `label` names the server in
  ## a panel's chrome (the host knows it: "live: <server>"); `fleetPageSize`
  ## is how many of the newest sessions a load asks for (the server's
  ## maximum page is 200).
  HostFedDataSource(label: label, request: request,
    pendingLoads: initTable[int, FleetCallback](),
    pageSize: clamp(fleetPageSize, 1, 200))

proc connected*(source: HostFedDataSource; stream = hsLifecycle): bool =
  ## True while the host's current connection has delivered a frame.
  source.states[stream].connected

proc lastError*(source: HostFedDataSource; stream = hsLifecycle): string =
  ## Why the host's last connection ended ("" while connected).
  source.states[stream].error

proc connections*(source: HostFedDataSource; stream = hsLifecycle): int =
  ## The connections the host has opened so far, delivered.
  source.states[stream].connections

proc cursor*(source: HostFedDataSource; stream = hsLifecycle): string =
  ## The cursor of the last frame delivered.
  source.states[stream].cursor

proc closed*(source: HostFedDataSource): bool = source.closed

proc deliverLifecycleFrame(source: HostFedDataSource; message: HostMessage) =
  let frame = lifecycleFrameOf(message.event, message.data, message.id)
  if frame.cursor.len > 0: source.states[hsLifecycle].cursor = frame.cursor
  let at = nowMs()
  discard source.frameSubscribers.broadcast(
    success(lifecycleFrame(frame, if frame.atMs > 0: frame.atMs else: at)))
  if frame.event == "resync":
    discard source.resetSubscribers.broadcast(success(StreamReset(atMs: at,
      reason: "the server could not replay the feed (" & frame.reason & ")")))

proc deliver*(source: HostFedDataSource; message: HostMessage): bool =
  ## Delivers one message from the host: frames and resets to the
  ## subscribers, a listing to the load waiting for it. False when it
  ## delivered nothing: the source is closed, or the listing answers no load
  ## this source is waiting for.
  if source.closed: return false
  case message.kind
  of hmConnecting:
    inc source.states[message.stream].connections
  of hmConnected:
    source.states[message.stream].connected = true
    source.states[message.stream].error = ""
  of hmDisconnected:
    source.states[message.stream].connected = false
    source.states[message.stream].error = message.text
  of hmFrame:
    case message.stream
    of hsLifecycle: source.deliverLifecycleFrame(message)
  of hmFleet:
    var done: FleetCallback
    if not source.pendingLoads.pop(message.loadId, done): return false
    if not message.ok:
      done(failure[FleetSnapshot](message.text))
    else:
      var node: JsonNode
      var unreadable = ""
      try:
        node = parseJson(message.text)
      except:
        # A bare `except`: on the JavaScript backend `parseJson` throws the
        # engine's own `SyntaxError`, which no Nim exception type catches.
        unreadable = "the body is not JSON"
      if unreadable.len > 0:
        done(failure[FleetSnapshot]("unreadable session list: " & unreadable))
      else:
        try:
          done(success(fleetSnapshotFromJson(node, nowMs(), source.label)))
        except CatchableError as error:
          done(failure[FleetSnapshot]("unreadable session list: " & error.msg))
  true

proc close*(source: HostFedDataSource) =
  ## Stops the source: nothing is delivered after it returns, waiting loads
  ## are never answered, and nothing more is asked of the host.
  if source.closed: return
  source.closed = true
  source.pendingLoads.clear()
  source.frameSubscribers = Subscribers[FleetFrame]()
  source.resetSubscribers = Subscribers[StreamReset]()

method loadFleet*(source: HostFedDataSource; done: FleetCallback) =
  ## Asks the host for the newest page; `done` is called from `deliver`.
  if source.closed:
    done(failure[FleetSnapshot]("the host-fed source is closed"))
    return
  inc source.nextLoad
  let id = source.nextLoad
  source.pendingLoads[id] = done
  source.request(id, source.pageSize)

method subscribeFleetFrames*(source: HostFedDataSource;
    callback: FeedCallback[FleetFrame]): Subscription[FleetFrame] =
  source.frameSubscribers.subscribe(callback)

method subscribeResets*(source: HostFedDataSource;
    callback: FeedCallback[StreamReset]): Subscription[StreamReset] =
  source.resetSubscribers.subscribe(callback)
