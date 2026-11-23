## Where a trace a surface asks the host to open goes, and the sentence that
## says so: the Test Results pane's placement words, shared by every surface
## of the Tests panel and the trace links (the panel, the opener of the
## links, the session timeline's links). Pure: no signals.
##
## A surface asks its host to open a trace with a `TraceRequest`: the trace
## (nim-agents' `TraceReference`), the test and platform it was recorded
## for, when it is a test's, and the destination. The destination is the
## host's setting (`PlacementContext.policy`: a new tab, or this tab),
## inverted while the modifier is held; a trace that already has a tab opens
## there, and a host whose current tab cannot be replaced opens a new one.
## The open title's last sentence (`placementSentence`) says the same, in the
## pane's words.

import nim_agents/agent_harbor/trace_links

type
  TraceDestination* = enum
    tdNewTab = "new-tab"
    tdCurrentTab = "current-tab"
    tdOwnTab = "own-tab"         ## the tab the trace already has

  PlacementContext* = object
    ## What a host reports about where an open goes.
    policy*: TraceDestination    ## the setting: `tdNewTab` or `tdCurrentTab`
    modifierHeld*: bool          ## the modifier (Ctrl) is held
    cannotReplace*: bool         ## the current tab cannot be replaced
    modifierName*: string        ## "" means `Ctrl`

  TraceRequest* = object
    ## A surface's request that the host open a trace.
    reference*: TraceReference
    testId*, platform*: string   ## a test's recording: the test and platform key
    destination*: TraceDestination

const
  OpensInOwnTabText* = "Opens in the tab it already has."
  OpensInNewTabText* = "Opens in a new tab."

proc modifier(ctx: PlacementContext): string =
  if ctx.modifierName.len > 0: ctx.modifierName else: "Ctrl"

proc destinationOf*(ctx: PlacementContext; hasTab: bool): TraceDestination =
  ## Where an open goes now.
  if hasTab: return tdOwnTab
  if ctx.cannotReplace: return tdNewTab
  let wanted = if ctx.policy == tdCurrentTab: tdCurrentTab else: tdNewTab
  if not ctx.modifierHeld: wanted
  elif wanted == tdNewTab: tdCurrentTab
  else: tdNewTab

proc placementSentence*(ctx: PlacementContext; hasTab: bool): string =
  ## The open title's last sentence: `Opens in a new tab; Ctrl+click opens it
  ## in this tab.`, `Opens in this tab, ending its session; Ctrl+click opens
  ## a new tab.`, `Opens in the tab it already has.`, `Opens in a new tab.`;
  ## with the modifier held, the inverted destination's sentence with
  ## `release Ctrl` as the other gesture.
  if hasTab: return OpensInOwnTabText
  if ctx.cannotReplace: return OpensInNewTabText
  let other = if ctx.modifierHeld: "release " & ctx.modifier else: ctx.modifier & "+click"
  case ctx.destinationOf(false)
  of tdCurrentTab: "Opens in this tab, ending its session; " & other & " opens a new tab."
  else: "Opens in a new tab; " & other & " opens it in this tab."

proc traceReferenceOf*(trace, serverOrigin: string): TraceReference =
  ## A test run's trace reference as a `TraceReference`: the reference as
  ## written (`agent-harbor://trace/<id>`, its https form, or a recording),
  ## or a bare trace id. An empty reference when it is neither.
  let parse = parseTraceReference(trace, serverOrigin)
  if parse.ok: return parse.reference
  let bare = parseTraceReference(AgentHarborTracePrefix & trace, serverOrigin)
  if bare.ok: bare.reference else: TraceReference()
