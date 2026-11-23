## `TraceOpenerVM`: a LOAD-TRACE BUTTON pattern -- one per pane, it holds,
## for every trace a link or a test cell of that pane names, what its button
## shows: idle, connecting to a replay, replaying, or unavailable with the
## reason; and its download: downloading, saved, failed. Every surface of the
## pane that shows the same trace reads the same state, so a trace opened
## from one shows `Show trace` in the others.
##
## **Two kinds of trace** (nim-agents' `trace_links`):
##
## - a trace Agent Harbor holds (`agent-harbor://trace/<id>`, or its https
##   form): `load` sends an `open-trace-replay` operator action through the
##   seam (`submitAction`, via the shared `ActionTracker`) and is
##   `connecting` until the source answers: `replaying` on a confirmed
##   receipt, which also asks the host to open the trace
##   (`requestedTrace`) and tells the session's initiative that a recording
##   is loading, then ready (`recordingEvent`); `unavailable` with the
##   receipt's reason otherwise. A trace that is no longer stored offers no
##   Retry. `download` sends `download-trace`.
## - a recording on this machine (`codetracer://recordings/<test>`): `load`
##   asks the host to open it at once (`requestedTrace`); no action is sent,
##   no replay is started, nothing is downloaded.
##
## Nothing moves a state but the source's answer: a source that never
## answers leaves the trace `connecting`, and one without actions shows it
## unavailable with the source's reason. Where the host opens a trace is the
## host's setting and modifier (`placement`, `trace_placement.nim`).

import std/strutils
import isonim/core/signals
import isonim/viewmodel
import nim_agents/agent_harbor/[operator_actions, trace_links]
import ./data_source
import ./action_tracker
import ./trace_placement

export trace_placement

const
  ConnectingText* = "Connecting to the replay\xE2\x80\xA6"
  ShowTraceText* = "Show trace"
  RetryText* = "Retry"
  DownloadText* = "Download"

type
  TraceOpenerVM* = ref object of ViewModel
    source: AgentHarborDataSource
    tracker: ActionTracker
    sessionId*: string
    initiativeId*: string
      ## The initiative a loaded trace is announced to ("" for none).
    replays: seq[(string, ReplayState)]
    downloads: seq[(string, DownloadState)]
    tabs: seq[string]
      ## The traces the host has opened (a further open shows its tab).
    revision*: Signal[int]
    placement*: Signal[PlacementContext]
      ## Set by the host: its setting and whether the modifier is held.
    requestedTrace*: Signal[TraceRequest]
      ## The host's last request to open a trace; `requests` counts them.
    requests*: Signal[int]
    recordingEvent*: Signal[RecordingEvent]
      ## The last recording state announced to the initiative;
      ## `recordingEvents` counts them.
    recordingEvents*: Signal[int]

proc newTraceOpenerVM*(source: AgentHarborDataSource; sessionId = "";
                       tracker: ActionTracker = nil; initiativeId = ""): TraceOpenerVM =
  ## The opener of one pane over `source`, sending through `tracker` (a new
  ## one when nil; pass the pane's shared one).
  withViewModel proc(dispose: proc()): TraceOpenerVM =
    TraceOpenerVM(source: source, sessionId: sessionId, initiativeId: initiativeId,
                  tracker: (if tracker.isNil: newActionTracker() else: tracker),
                  revision: createSignal(0), placement: createSignal(PlacementContext()),
                  requestedTrace: createSignal(TraceRequest()), requests: createSignal(0),
                  recordingEvent: createSignal(RecordingEvent()),
                  recordingEvents: createSignal(0))

proc tracker*(vm: TraceOpenerVM): ActionTracker = vm.tracker

proc keyOf(reference: TraceReference): string = $reference.kind & ":" & reference.id

proc bump(vm: TraceOpenerVM) =
  vm.revision.val = vm.revision.val + 1

proc stateOf*(vm: TraceOpenerVM; reference: TraceReference): ReplayState =
  ## Tracked: the trace's replay state (idle when never loaded).
  discard vm.revision.val
  for (k, s) in vm.replays:
    if k == reference.keyOf: return s
  ReplayState(phase: rpIdle)

proc downloadOf*(vm: TraceOpenerVM; reference: TraceReference): DownloadState =
  ## Tracked: the trace's download state.
  discard vm.revision.val
  for (k, s) in vm.downloads:
    if k == reference.keyOf: return s
  DownloadState(phase: dpIdle)

proc hasTab*(vm: TraceOpenerVM; reference: TraceReference): bool =
  discard vm.revision.val
  reference.keyOf in vm.tabs

proc setReplay(vm: TraceOpenerVM; reference: TraceReference; state: ReplayState) =
  let key = reference.keyOf
  for r in vm.replays.mitems:
    if r[0] == key:
      r[1] = state
      vm.bump()
      return
  vm.replays.add (key, state)
  vm.bump()

proc setDownload(vm: TraceOpenerVM; reference: TraceReference; state: DownloadState) =
  let key = reference.keyOf
  for r in vm.downloads.mitems:
    if r[0] == key:
      r[1] = state
      vm.bump()
      return
  vm.downloads.add (key, state)
  vm.bump()

proc announce(vm: TraceOpenerVM; reference: TraceReference; state: RecordingState) =
  if vm.initiativeId.len == 0: return
  vm.recordingEvent.val = RecordingEvent(initiativeId: vm.initiativeId,
    entry: RecordingEntry(id: "trace:" & reference.id, name: accessibleName(reference),
                          origin: "agent pane", state: state))
  vm.recordingEvents.val = vm.recordingEvents.val + 1

proc request*(vm: TraceOpenerVM; reference: TraceReference; testId = "";
              platform = "") =
  ## Asks the host to open the trace where the placement says; the trace
  ## then has a tab.
  let destination = vm.placement.val.destinationOf(vm.hasTab(reference))
  vm.requestedTrace.val = TraceRequest(reference: reference, testId: testId,
                                       platform: platform, destination: destination)
  vm.requests.val = vm.requests.val + 1
  if reference.keyOf notin vm.tabs:
    vm.tabs.add reference.keyOf
    vm.bump()

proc load*(vm: TraceOpenerVM; reference: TraceReference; testId = ""; platform = "") =
  ## The button's press (see the module comment). A trace already replaying
  ## is shown again without a new replay; a press while connecting sends
  ## nothing.
  if reference.id.len == 0: return
  if reference.kind == trkLocalRecording:
    vm.request(reference, testId, platform)
    return
  let state = vm.stateOf(reference)
  case state.phase
  of rpConnecting: return
  of rpReplaying:
    vm.request(reference, testId, platform)
    return
  of rpUnavailable:
    if not state.canRetry: return
  of rpIdle: discard
  let action = openTraceReplay(reference.id, vm.sessionId)
  if vm.tracker.inFlight(action.targetOf): return
  vm.setReplay(reference, ReplayState(phase: rpConnecting))
  vm.announce(reference, rsLoading)
  let target = vm
  let sent = vm.tracker.submit(vm.source, action, proc(entry: TrackedAction) =
    case entry.status
    of astConfirmed:
      target.setReplay(reference, ReplayState(phase: rpReplaying))
      target.announce(reference, rsReady)
      target.request(reference, testId, platform)
    of astFailed:
      let gone = entry.reason.contains(TraceGoneText)
      target.setReplay(reference, unavailable(entry.reason, canRetry = not gone))
      target.announce(reference, rsFailed)
    else: discard)
  if not sent: vm.setReplay(reference, state)

proc retry*(vm: TraceOpenerVM; reference: TraceReference) =
  ## Loads an unavailable trace again, when a retry can help.
  vm.load(reference)

proc download*(vm: TraceOpenerVM; reference: TraceReference) =
  ## Downloads a trace Agent Harbor holds: downloading, then saved with the
  ## receipt's file name, or failed with the reason. A recording on this
  ## machine is not downloaded.
  if reference.kind != trkAgentHarbor or reference.id.len == 0: return
  if vm.downloadOf(reference).phase == dpDownloading: return
  let action = downloadTrace(reference.id, vm.sessionId)
  vm.setDownload(reference, DownloadState(phase: dpDownloading))
  let target = vm
  let sent = vm.tracker.submit(vm.source, action, proc(entry: TrackedAction) =
    case entry.status
    of astConfirmed:
      let name = if entry.message.len > 0: entry.message else: reference.id & ".ct"
      target.setDownload(reference, DownloadState(phase: dpSaved, name: name))
    of astFailed:
      target.setDownload(reference, DownloadState(phase: dpFailed, reason: entry.reason))
    else: discard)
  if not sent: vm.setDownload(reference, DownloadState(phase: dpIdle))

proc buttonText*(vm: TraceOpenerVM; reference: TraceReference): string =
  ## Tracked: what the button says: `Load trace` / `Open recording`,
  ## `Connecting to the replay…`, `Show trace`.
  if reference.kind == trkLocalRecording: return actionLabel(reference.kind)
  case vm.stateOf(reference).phase
  of rpConnecting: ConnectingText
  of rpReplaying: ShowTraceText
  else: actionLabel(reference.kind)

proc canPress*(vm: TraceOpenerVM; reference: TraceReference): bool =
  ## Tracked: whether the button can be pressed (not while connecting, nor
  ## for a trace that is gone).
  let s = vm.stateOf(reference)
  not (s.phase == rpConnecting or (s.phase == rpUnavailable and not s.canRetry))

proc errorText*(vm: TraceOpenerVM; reference: TraceReference): string =
  ## Tracked: `Replay unavailable: <reason>`, or "".
  unavailableText(vm.stateOf(reference))

proc canRetry*(vm: TraceOpenerVM; reference: TraceReference): bool =
  let s = vm.stateOf(reference)
  s.phase == rpUnavailable and s.canRetry

proc canDownload*(vm: TraceOpenerVM; reference: TraceReference): bool =
  reference.kind == trkAgentHarbor and vm.downloadOf(reference).phase != dpDownloading

proc downloadStatus*(vm: TraceOpenerVM; reference: TraceReference): string =
  ## Tracked: `Downloading…`, `Saved <name>`, `Download failed: <reason>`, "".
  downloadText(vm.downloadOf(reference))

proc titleText*(vm: TraceOpenerVM; reference: TraceReference): string =
  ## Tracked: the button's title: what it opens, and where (the placement
  ## sentence). A recording says it is on this machine.
  discard vm.placement.val
  let what = case reference.kind
    of trkAgentHarbor:
      "Load trace " & reference.id & " in a replay near it" &
        (if reference.httpsUrl.len > 0: " (" & reference.httpsUrl & ")" else: "") & ". "
    of trkLocalRecording: "Open the recording of " & reference.id & " on this machine. "
  what & vm.placement.val.placementSentence(vm.hasTab(reference))

proc forget*(vm: TraceOpenerVM; reference: TraceReference) =
  ## Forgets that the host has a tab for the trace (the host closed it).
  var kept: seq[string]
  for k in vm.tabs:
    if k != reference.keyOf: kept.add k
  if kept.len != vm.tabs.len:
    vm.tabs = kept
    vm.bump()

proc describe*(reference: TraceReference): string =
  ## One line naming a reference, for a story's record and a failing check.
  $reference.kind & " " & reference.id &
    (if reference.query.len > 0: "?" & reference.query else: "") &
    (if reference.url.len > 0: " " & reference.url else: "")
