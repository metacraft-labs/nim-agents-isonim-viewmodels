## The sessions family's shared contract: what one session is, as every
## sessions view shows it -- the tab strip in each of its layouts
## (`session_tabs_vm.nim`), the initiatives panel's session lines
## (`initiatives_vm.nim`) -- whatever its UI pattern. A front-end binds to
## `SessionItem`; the variants differ in how they arrange items, not in what
## an item says. The fleet list (`fleet_vm.nim`) shows a wider row,
## `FleetRow`, built from the same domain rules.
##
## Signal-free: `sessionItemOf` is a pure function of a session, the clock
## and the policy, so every variant and every headless test reads the same
## words. The rules themselves (effective status, label fallback, activity
## digest) are nim-agents' (`nim_agents/agent_harbor/*`).

import std/strutils
import nim_agents/agent_harbor/[session_directory, activity_digest, fleet_fold]
import ./records

export session_directory, activity_digest

type
  SessionItem* = object
    id*: string
    shortId*: string
    title*: string
    titleSource*: LabelSource
    attention*: SessionAttention
    statusLabel*: string
    waitText*: string          ## why it waits, for a tooltip; "" when it does not
    origin*: string            ## front-end id (`cli`, `webui`, …), "" unknown
    originLabel*: string       ## `CLI`, `WebUI`, …
    originShort*: string       ## `CLI`, `Web`, … (a tab's room)
    planId*: string
    initiativeTitle*: string
    agentLabel*: string
    host*: string
    ageLabel*: string
    durationLabel*: string
    activity*: seq[DigestLine] ## most informative first
    failureText*: string
    tooltip*: string
    active*: bool

proc attentionWord*(attention: SessionAttention): string =
  case attention
  of saNeedsInput: "needs input"
  of saIdle: "idle"
  of saRunning: "running"
  of saQueued: "queued"
  of saFailed: "failed"
  of saEnded: "ended"

proc sessionItemOf*(session: FleetSession; nowMs: int64; policy: SessionPolicy;
                    active = false): SessionItem =
  let (title, source) = session.titleOf(policy.labels)
  result = SessionItem(
    id: session.id, shortId: shortIdOf(session.id), title: title,
    titleSource: source,
    attention: session.attentionOf(policy.status),
    statusLabel: session.statusLabelOf(policy.status),
    waitText: session.waitDescription,
    origin: session.originFrontEnd, originLabel: originLabel(session.originFrontEnd),
    originShort: originShortLabel(session.originFrontEnd),
    planId: session.planId, initiativeTitle: session.initiative,
    agentLabel: agentLabel(session.agentSoftware, session.agentVersion),
    host: session.host,
    ageLabel: ageLabel(nowMs, session.lastActivityMs),
    durationLabel: durationLabel(
      if session.startedAtMs > 0: session.startedAtMs else: session.createdAtMs,
      if session.endedAtMs > 0: session.endedAtMs
      elif session.status.isActive: nowMs
      else: 0),
    activity: digestActivity(session.recent, currentStatus = session.rawStatus),
    active: active)
  if result.attention == saFailed:
    # Why it failed, from the domain's predicate (`isReasonLine`): the newest
    # error line; else the reason the source found in the session's history
    # (an exit line); else the newest log line of any level. A row draws it in
    # the error colour, so an ordinary log line comes last.
    for i in countdown(session.recent.high, 0):
      let e = session.recent[i]
      if e.isReasonLine and e.level == "error":
        result.failureText = e.text
        break
    if result.failureText.len == 0: result.failureText = session.failureReason
    if result.failureText.len == 0:
      var newestFirst: seq[FleetActivity]
      for i in countdown(session.recent.high, 0): newestFirst.add session.recent[i]
      result.failureText = failureReasonOf(newestFirst)
  # The tooltip says everything a compact item leaves out, one fact a line.
  var lines = @[title]
  if source != lsPrompt and source != lsId:
    lines.add "(" & $source & (if session.labelSource.len > 0: ", from " & session.labelSource else: "") & ")"
  lines.add result.statusLabel & (if result.waitText.len > 0: ": " & result.waitText else: "")
  var facts: seq[string]
  if result.originLabel.len > 0: facts.add "started from " & result.originLabel
  if result.agentLabel.len > 0: facts.add result.agentLabel
  if result.host.len > 0: facts.add result.host
  if result.durationLabel.len > 0: facts.add result.durationLabel
  if facts.len > 0: lines.add facts.join(" \xC2\xB7 ")
  if result.initiativeTitle.len > 0: lines.add "initiative: " & result.initiativeTitle
  if result.failureText.len > 0: lines.add result.failureText
  elif result.activity.len > 0: lines.add result.activity[0].lineText
  result.tooltip = lines.join("\n")

proc followFrame*(dir: var SessionDirectory; nowMs: var int64;
                  frame: FleetFrame): bool =
  ## One fleet frame folded into a sessions view's directory
  ## (`fleet_fold.applyFleetFrame`), and the view's clock moved to the
  ## frame's moment: the frame's own stamp, its lifecycle frame's, or the
  ## update time of the session it changed, whichever is latest; the clock
  ## never goes back. True when the directory changed. The shared step of
  ## every sessions view that follows a source's frames (the tab strip, the
  ## initiative tab bar, the initiatives panel); the fleet list holds a
  ## `FleetFold` instead.
  result = dir.applyFleetFrame(frame)
  if not result: return
  var moment = frame.atMs
  if frame.kind == ffLifecycle: moment = max(moment, frame.lifecycle.atMs)
  let id = case frame.kind
    of ffLifecycle: frame.lifecycle.sessionId
    of ffSession: frame.session.id
    of ffEvent: frame.sessionId
  let at = dir.find(id)
  if at >= 0: moment = max(moment, dir.sessions[at].updatedAtMs)
  nowMs = max(nowMs, moment)
