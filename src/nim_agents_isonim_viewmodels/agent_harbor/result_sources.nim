## The seams the omnibox's result commands read through.
##
## - `SearchProvider`: one provider of `/search` (OMNI-AREQ3): CodeTracer's
##   files, symbols and program text, Agent Harbor's sessions, and any an
##   extension contributes (Extensibility-Model §6.1, "Search provider"). A
##   provider answers a query through a `ResultSink`: rows (in parts, the
##   last one final), or a failure.
## - `InputCommandSource`: Agent Harbor's input-command protocol
##   (agent-harbor `specs/Input-Commands.md`): `discover` lists the commands
##   a surface may offer, `query` runs one on a text and streams its rows.
##   `AgentHarborSearchProvider` makes its `search` command a provider of
##   CodeTracer's `/search` (OMNI-AREQ3), so the omnibox reaches it both as
##   `/ah-search` and as a group of `/search`.
##
## Every call is asynchronous by contract: a sink is answered once, possibly
## inside the call, possibly much later, possibly never. A query is
## superseded by the next one; the viewmodel ignores a superseded answer
## (`ResultSearch`), and a source may stop its work when `cancel` is called.
##
## The implementations here are the prototypes': `ScriptedSearchProvider`
## (rows computed from the text, held until `release` where a story needs a
## provider still searching, or failing with one reason) and
## `ScriptedCommandSource` (commands as a discovery answer, rows by command
## and text, unreachable with a reason). A live provider or a live Agent
## Harbor source answers the same calls; a viewmodel built on these seams
## does not change when one is swapped in.

import nim_agents/result_commands
import ./data_source

export result_commands, data_source

type
  ResultSink* = object
    ## Where a query's answer goes.
    rows*: proc(rows: seq[ResultRow]; final: bool)
    failed*: proc(error: string)

  SearchProvider* = ref object of RootObj
    id*: string
    title*: string       ## `Files`, `Symbols`, …
    source*: string      ## `builtin` or `extension:<id>`

  QueryRecord* = object
    command*: string     ## "" for a provider's search
    text*: string

method search*(p: SearchProvider; text: string; sink: ResultSink) {.base.} =
  sink.failed("the provider '" & p.id & "' does not search")

method cancel*(p: SearchProvider) {.base.} =
  ## Stops the work of every query not yet answered; the viewmodel calls it
  ## before a new query. A provider that cannot stop ignores it.
  discard

proc info*(p: SearchProvider): ProviderInfo =
  ProviderInfo(id: p.id, title: p.title, source: p.source)

# ---------------------------------------------------------------------------
# A scripted provider
# ---------------------------------------------------------------------------

type
  ScriptedSearchProvider* = ref object of SearchProvider
    answer*: proc(text: string): seq[ResultRow]
      ## The rows for a text (nil: none).
    failure*: string
      ## Non-empty: every query fails with it.
    hold*: bool
      ## Hold every answer until `release`.
    held: seq[proc()]
    asked*: seq[string]
      ## What it was asked, in order.

proc newScriptedSearchProvider*(id, title: string; answer: proc(text: string): seq[ResultRow];
                                source = "builtin"): ScriptedSearchProvider =
  ScriptedSearchProvider(id: id, title: title, source: source, answer: answer)

method search*(p: ScriptedSearchProvider; text: string; sink: ResultSink) =
  p.asked.add text
  let failure = p.failure
  let rows = if p.answer.isNil: @[] else: p.answer(text)
  let reply = proc() =
    if failure.len > 0: sink.failed(failure) else: sink.rows(rows, true)
  if p.hold: p.held.add reply else: reply()

proc pendingAnswers*(p: ScriptedSearchProvider): int = p.held.len

proc release*(p: ScriptedSearchProvider) =
  ## Delivers every held answer, oldest first.
  let held = p.held
  p.held = @[]
  for reply in held: reply()

proc releaseOne*(p: ScriptedSearchProvider) =
  if p.held.len == 0: return
  let reply = p.held[0]
  p.held.delete(0)
  reply()

# ---------------------------------------------------------------------------
# Agent Harbor's input commands
# ---------------------------------------------------------------------------

type
  DiscoveryCallback* = proc(answer: DataResult[seq[InputCommand]])

  InputCommandSource* = ref object of RootObj
    label*: string

method discover*(s: InputCommandSource; surface: string; done: DiscoveryCallback) {.base.} =
  done(failure[seq[InputCommand]]("the source '" & s.label & "' lists no commands"))

method query*(s: InputCommandSource; command, text: string; sink: ResultSink) {.base.} =
  sink.failed("the source '" & s.label & "' runs no commands")

method cancel*(s: InputCommandSource) {.base.} = discard

type
  ScriptedCommandSource* = ref object of InputCommandSource
    commands*: seq[InputCommand]
      ## What the discovery answers (`parseDiscovery` of an invented body).
    rowsFor*: proc(command, text: string): seq[ResultRow]
      ## A command's rows for a text (nil: none).
    unreachable*: string
      ## Non-empty: every call fails with it (Agent Harbor not reachable).
    failures*: seq[(string, string)]
      ## (command, reason): that command's queries fail.
    hold*: bool
      ## Hold every query's answer until `release` (the discovery answers).
    held: seq[proc()]
    queried*: seq[QueryRecord]

proc newScriptedCommandSource*(commands: seq[InputCommand];
                               rowsFor: proc(command, text: string): seq[ResultRow] = nil;
                               label = "scripted Agent Harbor commands"): ScriptedCommandSource =
  ScriptedCommandSource(label: label, commands: commands, rowsFor: rowsFor)

method discover*(s: ScriptedCommandSource; surface: string; done: DiscoveryCallback) =
  if s.unreachable.len > 0:
    done(failure[seq[InputCommand]](s.unreachable))
    return
  var listed: seq[InputCommand]
  for c in s.commands:
    if c.isAvailableOn(surface): listed.add c
  done(success(listed))

method query*(s: ScriptedCommandSource; command, text: string; sink: ResultSink) =
  s.queried.add QueryRecord(command: command, text: text)
  var failure = s.unreachable
  for (c, reason) in s.failures:
    if c == command and failure.len == 0: failure = reason
  let rows = if s.rowsFor.isNil: @[] else: s.rowsFor(command, text)
  let reply = proc() =
    if failure.len > 0: sink.failed(failure) else: sink.rows(rows, true)
  if s.hold: s.held.add reply else: reply()

proc pendingAnswers*(s: ScriptedCommandSource): int = s.held.len

proc release*(s: ScriptedCommandSource) =
  let held = s.held
  s.held = @[]
  for reply in held: reply()

proc disableExtension*(s: ScriptedCommandSource; extension: string) =
  ## The extension `extension` is disabled: its commands are gone from the
  ## next discovery (Input-Commands.md, "Contributed commands").
  var kept: seq[InputCommand]
  for c in s.commands:
    if c.source != "extension:" & extension: kept.add c
  s.commands = kept

# ---------------------------------------------------------------------------
# Agent Harbor's search as a provider of /search (OMNI-AREQ3)
# ---------------------------------------------------------------------------

type
  AgentHarborSearchProvider* = ref object of SearchProvider
    commands*: InputCommandSource
    command*: string     ## the command it runs (`search`)

proc newAgentHarborSearchProvider*(commands: InputCommandSource;
                                   command = "search";
                                   title = "Agent Harbor sessions"): AgentHarborSearchProvider =
  AgentHarborSearchProvider(id: "agent-harbor-" & command, title: title,
                            source: "builtin", commands: commands, command: command)

method search*(p: AgentHarborSearchProvider; text: string; sink: ResultSink) =
  p.commands.query(p.command, text, sink)

method cancel*(p: AgentHarborSearchProvider) =
  p.commands.cancel()
