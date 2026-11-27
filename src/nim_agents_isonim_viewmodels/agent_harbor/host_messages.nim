## The messages a host that follows an Agent Harbor server posts to the
## windows it serves, and their text as IPC carries it.
##
## A desktop front-end's main process follows the server (manager decision
## D92) and forwards what it reads to each window, whose
## `HostFedDataSource` delivers it to the viewmodels. These are the same
## plain messages the native `LiveDataSource`'s workers post to its host
## thread: a stream's connection state, one feed frame as sent (`event`,
## `data`, `id`), and a listing's answer (`ok`, then the JSON body or the
## error). Frames and listings are decoded only where they are delivered, so
## both sides of the boundary agree on the wire by construction.
##
## The text is one JSON object per message. Pure: native and JavaScript.

import std/[json, strutils]

type
  HostStream* = enum
    ## A stream the host follows.
    hsLifecycle = "lifecycle"  ## `GET /api/v1/session-lifecycle/events`

  HostMessageKind* = enum
    hmConnecting = "connecting"     ## the host opens a connection
    hmConnected = "connected"       ## that connection delivered its first frame
    hmDisconnected = "disconnected" ## it ended or failed; `text` says why
    hmFrame = "frame"               ## one feed frame: `event`, `data`, `id`
    hmFleet = "fleet"               ## a listing answered: `ok`, then `text`
                                    ## is the JSON body or the error

  HostMessage* = object
    kind*: HostMessageKind
    stream*: HostStream     ## which stream (stream messages)
    event*, data*, id*: string
    ok*: bool
    text*: string
    loadId*: int            ## which load a listing answers

proc toJson*(message: HostMessage): JsonNode =
  result = %*{"kind": $message.kind, "stream": $message.stream}
  case message.kind
  of hmConnecting, hmConnected: discard
  of hmDisconnected: result["text"] = %message.text
  of hmFrame:
    result["event"] = %message.event
    result["data"] = %message.data
    result["id"] = %message.id
  of hmFleet:
    result["loadId"] = %message.loadId
    result["ok"] = %message.ok
    result["text"] = %message.text

proc encodeHostMessage*(message: HostMessage): string =
  ## The message's text, as IPC carries it.
  $message.toJson

proc stringField(node: JsonNode; name: string): string =
  let field = node{name}
  if field.isNil: return ""
  if field.kind != JString:
    raise newException(ValueError, "a host message's `" & name &
      "` is not a string")
  field.getStr

proc hostMessageFromJson*(node: JsonNode): HostMessage =
  ## The message `node` carries; raises `ValueError` naming what is wrong.
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "a host message is not a JSON object")
  try:
    result.kind = parseEnum[HostMessageKind](node.stringField("kind"))
  except ValueError:
    raise newException(ValueError, "a host message names no known kind")
  let stream = node.stringField("stream")
  if stream.len > 0:
    try:
      result.stream = parseEnum[HostStream](stream)
    except ValueError:
      raise newException(ValueError, "a host message names no known stream")
  result.event = node.stringField("event")
  result.data = node.stringField("data")
  result.id = node.stringField("id")
  result.text = node.stringField("text")
  if result.kind == hmFleet:
    let loadId = node{"loadId"}
    if loadId.isNil or loadId.kind != JInt:
      raise newException(ValueError, "a listing's message names no load")
    result.loadId = int(loadId.getBiggestInt)
    let ok = node{"ok"}
    if ok.isNil or ok.kind != JBool:
      raise newException(ValueError, "a listing's message says no outcome")
    result.ok = ok.getBool

proc decodeHostMessage*(text: string): HostMessage =
  ## The message a text carries; raises `ValueError` naming what is wrong.
  var node: JsonNode
  try:
    node = parseJson(text)
  except:
    # A bare `except`: on the JavaScript backend `parseJson` throws the
    # engine's own `SyntaxError`, which no Nim exception type catches.
    raise newException(ValueError, "a host message is not JSON")
  hostMessageFromJson(node)
