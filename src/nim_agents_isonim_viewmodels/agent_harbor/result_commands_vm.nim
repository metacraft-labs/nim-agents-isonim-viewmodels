## `ResultCommandsVM`: the omnibox's result commands -- a GROUPED RESULTS
## SHEET pattern: the one-line field, and under it the rows the command
## answered while the operator types, grouped by the provider that answered,
## each group with its own state.
##
## The rules (what a query is, supersession, the providers' order, the
## eight-row limit, completions, where opening a row goes) are nim-agents'
## `result_commands`; this viewmodel publishes them through signals and runs
## the queries on two seams (`result_sources`): the search providers of
## `/search` (`SearchProvider`; CodeTracer's own and Agent Harbor's
## sessions, OMNI-AREQ3), and Agent Harbor's input-command protocol
## (`InputCommandSource`: its discovery and its queries, OMNI-AREQ1/2).
##
## What it shows, by what the field holds (`setInput`):
##
## - `/s <text>`: one group per provider, in their order, each `searching…`
##   until its provider answers; `+N more` past eight rows (`showGroup`
##   shows one group alone, `showAll` goes back);
## - `/ah`, `/ah-<start>`: Agent Harbor's commands, from its discovery;
## - `/ah-<id> <text>`, `/ah<alias> <text>`: that command's rows, one group;
## - an unknown `/ah` name, or Agent Harbor unreachable: one line in place
##   of the rows (`notice`);
## - `/ai …@<token>`, `/ai …/<token>`: the completions of the sigil being
##   typed (agents, repositories and files; workflows and chat
##   capabilities), `insertSelected` puts one into the field.
##
## **Keys** a host binds: `↓` / `↑` `moveSelection`, `Enter` `openSelected`
## (or, for a completion, `insertSelected`), `Tab` `insertSelected`.
##
## **Answers** are applied only to the query they answer: a provider's rows
## for an older text, or any answer after `dispose`, change nothing.

import std/strutils
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import ./result_sources

export result_sources, viewmodel, signals, computation

type
  DiscoveryState* = enum
    dsLoading = "loading"
    dsReady = "ready"
    dsFailed = "failed"

  ShownGroup* = object
    ## A group as the sheet shows it.
    group*: ProviderGroup
    rows*: seq[ResultRow]   ## the rows drawn
    more*: int              ## rows past the limit (`+N more`), 0 when alone
    first*: int             ## the selection index of its first row

  Notice* = object
    ## One line in place of the rows, and a quiet hint after it.
    text*: string
    role*: string           ## `caption` or `error`
    hint*: string
    term*: string           ## the part of `text` a line break must not split (a
                            ## command's name, a query); "" for none

  ResultCommandsVM* = ref object of ViewModel
    providers: seq[SearchProvider]
    commands: InputCommandSource
    input: string
    query: ResultQuery
    search: ResultSearch
    discovered: seq[InputCommand]
    discovery: DiscoveryState
    discoveryError: string
    discoveryToken: int
    openedRow: string
    openedTarget: OpenTarget
    openedText: string
    disposed: bool
    revision*: Signal[int]
      ## Moves whenever what the sheet shows changes.
    selected*: Signal[int]
      ## The selected row, an index into `selectableRows`.
    alone*: Signal[string]
      ## The id of the group shown alone; "" for every group.
    htmlEnabled*: Signal[bool]
      ## Rich rows draw their HTML box (where the front-end can); off, every
      ## row draws its text form.
    surface*: string
      ## The surface Agent Harbor's discovery is asked for.
    agents*, repositories*, files*, workflows*, capabilities*: seq[string]
      ## What the sigils complete, as the host lists them.
    onOpen*: proc(row: ResultRow; target: OpenTarget)
      ## The host opens a row (the editor, a session tab, the system).
    maxSheetWidth*: int
    sheetInset*: int
    narrowBelow*: int

const
  CommandsGroupId* = "agent-harbor-commands"
  CompletionGroups* = [(rkAgent, "agents", "Agents"),
                       (rkRepository, "repositories", "Repositories"),
                       (rkFile, "files", "Files"),
                       (rkWorkflow, "workflows", "Workflows"),
                       (rkCapability, "capabilities", "Chat capabilities")]
  Dot = " \xC2\xB7 "
  Ellipsis = "\xE2\x80\xA6"

proc bump(vm: ResultCommandsVM) =
  vm.revision.val = vm.revision.val + 1

proc refreshCommands*(vm: ResultCommandsVM)

proc newResultCommandsVM*(providers: openArray[SearchProvider];
                          commands: InputCommandSource;
                          surface = "external"): ResultCommandsVM =
  ## The result commands over `providers` (`/search`, in this order) and
  ## Agent Harbor's `commands`, whose discovery is asked for `surface` at
  ## once.
  let list = @providers
  let vm = withViewModel proc(dispose: proc()): ResultCommandsVM =
    let vm = ResultCommandsVM(providers: list, commands: commands, surface: surface,
      discovery: dsLoading, revision: createSignal(0), selected: createSignal(0),
      alone: createSignal(""), htmlEnabled: createSignal(true),
      maxSheetWidth: 640, sheetInset: 8, narrowBelow: 480)
    onCleanup proc() = vm.disposed = true
    vm
  vm.refreshCommands()
  vm

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc input*(vm: ResultCommandsVM): string =
  ## What the field holds, prefix included.
  discard vm.revision.val
  vm.input

proc query*(vm: ResultCommandsVM): ResultQuery =
  discard vm.revision.val
  vm.query

proc kind*(vm: ResultCommandsVM): QueryKind =
  discard vm.revision.val
  vm.query.kind

proc discoveryState*(vm: ResultCommandsVM): DiscoveryState =
  discard vm.revision.val
  vm.discovery

proc commandList*(vm: ResultCommandsVM): seq[InputCommand] =
  discard vm.revision.val
  vm.discovered

proc command*(vm: ResultCommandsVM): InputCommand =
  ## The command `/ah-<id>` or `/ah<alias>` runs.
  discard vm.revision.val
  findCommand(vm.discovered, vm.query.command)

proc completionGroups(vm: ResultCommandsVM): seq[ProviderGroup] =
  let q = vm.query
  for (kind, id, title) in CompletionGroups:
    let names = case kind
                of rkAgent: vm.agents
                of rkRepository: vm.repositories
                of rkFile: vm.files
                of rkWorkflow: vm.workflows
                else: vm.capabilities
    let forSigil = if q.sigil == '@': kind in {rkAgent, rkRepository, rkFile}
                   else: kind in {rkWorkflow, rkCapability}
    if not forSigil: continue
    let rows = completionRows(kind, q.sigil, names, q.token)
    if rows.len > 0:
      result.add ProviderGroup(id: id, title: title, source: "builtin",
                               state: psAnswered, rows: rows)

proc rawGroups(vm: ResultCommandsVM): seq[ProviderGroup] =
  case vm.query.kind
  of qkSearch, qkAhRun: vm.search.groups
  of qkAhList:
    if vm.discovery != dsReady: @[]
    else:
      var rows: seq[ResultRow]
      for c in commandsMatching(vm.discovered, vm.query.typed):
        rows.add commandRow(c)
      if rows.len == 0: @[]
      else: @[ProviderGroup(id: CommandsGroupId, title: "Agent Harbor commands",
                            source: "builtin", state: psAnswered, rows: rows)]
  of qkCompletion: vm.completionGroups
  of qkAhUnknown, qkNone: @[]

proc groups*(vm: ResultCommandsVM): seq[ShownGroup] =
  ## The groups the sheet shows, in order, with the rows each draws; one
  ## group when one is shown alone. None while a line stands in their place
  ## (`notice`).
  discard vm.revision.val
  let alone = vm.alone.val
  if vm.query.kind == qkSearch and vm.search.nothingMatches: return
  var at = 0
  for g in vm.rawGroups:
    if alone.len > 0 and g.id != alone: continue
    let (rows, more) = g.shownRows(alone = alone.len > 0)
    result.add ShownGroup(group: g, rows: rows, more: more, first: at)
    at += rows.len

proc selectableRows*(vm: ResultCommandsVM): seq[ResultRow] =
  ## Every row drawn, in order: what `↑` / `↓` move through.
  for g in vm.groups:
    result.add g.rows

proc selectedRow*(vm: ResultCommandsVM): ResultRow =
  let rows = vm.selectableRows
  let i = vm.selected.val
  if i >= 0 and i < rows.len: rows[i] else: ResultRow()

proc isSelected*(vm: ResultCommandsVM; group: ShownGroup; index: int): bool =
  ## Row `index` of `group` is the selected one.
  vm.selected.val == group.first + index

proc providerCount(vm: ResultCommandsVM): int = vm.search.groups.len

proc notice*(vm: ResultCommandsVM): Notice =
  ## The line in place of the rows, if one stands there.
  discard vm.revision.val
  case vm.query.kind
  of qkSearch:
    if vm.search.nothingMatches:
      Notice(text: "Nothing matches \xE2\x80\x9C" & vm.search.text & "\xE2\x80\x9D", role: "caption",
             term: "\xE2\x80\x9C" & vm.search.text & "\xE2\x80\x9D")
    else: Notice()
  of qkAhList, qkAhRun:
    case vm.discovery
    of dsFailed:
      Notice(text: "Agent Harbor is not reachable: " & vm.discoveryError, role: "error")
    of dsLoading: Notice()
    of dsReady:
      if vm.query.kind == qkAhList and vm.rawGroups.len == 0:
        Notice(text: "No Agent Harbor command starts with " & vm.query.typed, role: "caption",
               hint: "/ah lists them", term: vm.query.typed)
      else: Notice()
  of qkAhUnknown:
    if vm.discovery == dsFailed:
      Notice(text: "Agent Harbor is not reachable: " & vm.discoveryError, role: "error")
    else:
      Notice(text: "No Agent Harbor command named " & vm.query.typed, role: "caption",
             hint: "/ah lists them", term: vm.query.typed)
  of qkCompletion:
    if vm.completionGroups.len == 0:
      Notice(text: "Nothing completes " & $vm.query.sigil & vm.query.token, role: "caption")
    else: Notice()
  of qkNone: Notice()

proc openedLine*(vm: ResultCommandsVM): string =
  ## What the header says once a row was opened; "" before.
  discard vm.revision.val
  vm.openedText

proc openedOutside*(vm: ResultCommandsVM; row: ResultRow): bool =
  ## `row` was passed on to the system: it says so under its title.
  discard vm.revision.val
  vm.openedTarget == otOutside and vm.openedRow == row.id and row.id.len > 0

proc showsHtml*(vm: ResultCommandsVM; row: ResultRow): bool =
  ## The row draws its HTML box (where the front-end can render HTML).
  row.html.len > 0 and vm.htmlEnabled.val

proc scriptsBlocked*(vm: ResultCommandsVM; row: ResultRow): bool =
  ## An untrusted box that holds a script: drawn with the script not run.
  vm.showsHtml(row) and not row.trusted and row.html.toLowerAscii.contains("<script")

proc htmlHeightOf*(row: ResultRow): int =
  ## The box's height in CSS pixels: what the source asks for, at most
  ## `MaxHtmlHeight` (then it scrolls inside).
  min(MaxHtmlHeight, if row.htmlHeight > 0: row.htmlHeight else: DefaultHtmlHeight)

proc rowTag*(vm: ResultCommandsVM; row: ResultRow): string =
  ## A quiet tag at the row's right: where a command or a contributed row
  ## comes from, or `HTML` for a rich row drawn as HTML.
  if row.kind == rkCommand:
    return sourceLabel(findCommand(vm.discovered, row.id))
  if row.source.startsWith("extension:"):
    for c in vm.discovered:
      if c.source == row.source and c.sourceTitle.len > 0: return c.sourceTitle
    for p in vm.providers:
      if p.source == row.source: return p.title
    return row.source.substr("extension:".len)
  ""

proc aliasesOf*(vm: ResultCommandsVM; row: ResultRow): string =
  ## A command row's aliases, as typed (`/ahs`), after its name.
  if row.kind != rkCommand: return ""
  findCommand(vm.discovered, row.id).aliasNames.join(", ")

proc headerText*(vm: ResultCommandsVM): string =
  ## The sheet's header line: where the query is.
  discard vm.revision.val
  discard vm.alone.val
  discard vm.htmlEnabled.val
  if vm.openedText.len > 0: return vm.openedText
  # A phrase a line break must not split (no-break spaces): a narrow sheet
  # wraps the header between its parts, never inside one.
  # Said only where a row has a rich form that is drawn as text.
  var rich = false
  if not vm.htmlEnabled.val and vm.query.kind in {qkSearch, qkAhRun}:
    for g in vm.search.groups:
      for r in g.rows:
        if r.html.len > 0: rich = true
  let textOnly = if rich: Dot & "Rich\xC2\xA0results\xC2\xA0shown\xC2\xA0as\xC2\xA0text" else: ""
  case vm.query.kind
  of qkSearch:
    let s = vm.search
    if s.groups.len == 0: return "Search files, symbols, the program's text and Agent Harbor's sessions"
    let alone = vm.alone.val
    if alone.len > 0:
      for g in s.groups:
        if g.id == alone:
          return g.title & Dot & $g.rows.len & (if g.rows.len == 1: " result" else: " results") &
                 Dot & "Enter opens" & textOnly
    if not s.complete:
      return "Searching" & Ellipsis & " " & $s.answered & " of " & $s.groups.len &
             " providers answered" & textOnly
    if s.nothingMatches:
      return "Searched " & $s.groups.len & " providers"
    var failed: seq[string]
    for g in s.groups:
      if g.state == psFailed: failed.add g.title
    let n = s.totalRows
    let answeredBy = if failed.len > 0: $(s.groups.len - failed.len) & " of " & $s.groups.len & " providers"
                     else: $s.groups.len & " providers"
    # A provider that failed is named here, where it is in view whatever
    # the body has scrolled past (its group says why).
    let failedPart = if failed.len > 0: Dot & failed.join(", ") & " failed" else: ""
    $n & (if n == 1: " result" else: " results") & " from " & answeredBy & failedPart &
      Dot & "Enter opens" & textOnly
  of qkAhList:
    case vm.discovery
    of dsLoading: "Asking Agent Harbor for its commands" & Ellipsis
    of dsFailed: "Agent Harbor commands"
    of dsReady: "Agent Harbor commands" & Dot & "Enter chooses one"
  of qkAhRun:
    let c = findCommand(vm.discovered, vm.query.command)
    (if vm.query.byAlias: vm.query.typed & " is " & c.fullName else: c.fullName) &
      Dot & c.title & Dot & c.sourceLabel & textOnly
  of qkAhUnknown: "Agent Harbor commands"
  of qkCompletion:
    "Completing " & $vm.query.sigil & vm.query.token & Dot & "Tab inserts it"
  of qkNone: ""

proc headerRole*(vm: ResultCommandsVM): string =
  ## `body` once a row was opened; `error` while a provider of the query
  ## failed; `caption` otherwise.
  discard vm.revision.val
  if vm.openedText.len > 0: return "body"
  if vm.query.kind == qkSearch and vm.alone.val.len == 0:
    for g in vm.search.groups:
      if g.state == psFailed: return "error"
  "caption"

proc sheetWidthFor*(vm: ResultCommandsVM; window: int): int =
  ## The sheet's width in a window `window` wide, in the renderer's unit
  ## (the composer's rule).
  max(0, min(vm.maxSheetWidth, window - 2 * vm.sheetInset))

proc isNarrow*(vm: ResultCommandsVM; window: int): bool = window < vm.narrowBelow

# ---------------------------------------------------------------------------
# Acting
# ---------------------------------------------------------------------------

proc refreshCommands*(vm: ResultCommandsVM) =
  ## Asks Agent Harbor's discovery again (an extension enabled or disabled,
  ## Agent Harbor reachable again).
  inc vm.discoveryToken
  let token = vm.discoveryToken
  vm.discovery = dsLoading
  let target = vm
  vm.commands.discover(vm.surface, proc(answer: DataResult[seq[InputCommand]]) =
    if target.disposed or token != target.discoveryToken: return
    if answer.ok:
      target.discovered = answer.value
      target.discovery = dsReady
      target.discoveryError = ""
    else:
      target.discovered = @[]
      target.discovery = dsFailed
      target.discoveryError = answer.error
    # A query typed before the discovery answered is read again.
    if target.input.len > 0:
      target.query = classifyResultQuery(target.input, target.discovered)
    target.bump())

proc sinkFor(vm: ResultCommandsVM; generation: int; provider: string): ResultSink =
  ## Where the answer of `provider` to the query of `generation` goes. A
  ## proc of its own so each sink owns its provider (a closure made in a
  ## loop shares the loop's variables).
  let target = vm
  ResultSink(
    rows: proc(rows: seq[ResultRow]; final: bool) =
      if target.disposed: return
      if target.search.applyRows(generation, provider, rows, final): target.bump(),
    failed: proc(error: string) =
      if target.disposed: return
      if target.search.applyFailure(generation, provider, error): target.bump())

proc run(vm: ResultCommandsVM) =
  ## Starts what the query asks for: every provider, or one command.
  for p in vm.providers: p.cancel()
  vm.commands.cancel()
  case vm.query.kind
  of qkSearch:
    var infos: seq[ProviderInfo]
    if vm.query.text.len > 0:
      for p in vm.providers: infos.add p.info
    let generation = vm.search.begin(vm.query.text, infos)
    if vm.query.text.len == 0: return
    for p in vm.providers:
      p.search(vm.query.text, vm.sinkFor(generation, p.id))
  of qkAhRun:
    let c = findCommand(vm.discovered, vm.query.command)
    let generation = vm.search.begin(vm.query.text,
      [ProviderInfo(id: c.id, title: c.title, source: c.source)])
    if vm.query.text.len == 0:
      # Nothing to run on yet: the command's group, answered with nothing.
      discard vm.search.applyRows(generation, c.id, [])
      return
    vm.commands.query(c.id, vm.query.text, vm.sinkFor(generation, c.id))
  else:
    discard vm.search.begin("", [])

proc setInput*(vm: ResultCommandsVM; input: string) =
  ## What the field holds now (typing): the query it asks for supersedes
  ## the last one; the selection goes back to the first row.
  if input == vm.input: return
  vm.input = input
  vm.query = classifyResultQuery(input, vm.discovered)
  vm.openedRow = ""
  vm.openedTarget = otNone
  vm.openedText = ""
  vm.alone.val = ""
  vm.selected.val = 0
  vm.run()
  vm.bump()

proc moveSelection*(vm: ResultCommandsVM; delta: int) =
  ## `↓` / `↑`: the next or previous row drawn, wrapping.
  let n = vm.selectableRows.len
  if n == 0 or delta == 0: return
  vm.selected.val = ((vm.selected.val + delta) mod n + n) mod n

proc showGroup*(vm: ResultCommandsVM; id: string) =
  ## `+N more`: the group alone, every row of it.
  for g in vm.rawGroups:
    if g.id == id:
      vm.alone.val = id
      vm.selected.val = 0
      vm.bump()
      return

proc showAll*(vm: ResultCommandsVM) =
  ## `← All providers`: every group again.
  if vm.alone.val.len == 0: return
  vm.alone.val = ""
  vm.selected.val = 0
  vm.bump()

proc insertSelected*(vm: ResultCommandsVM): bool =
  ## `Tab`: the selected completion or command into the field (and a space
  ## after it). False when the selected row inserts nothing.
  let row = vm.selectedRow
  if row.insert.len == 0: return false
  let next = case vm.query.kind
             of qkCompletion: insertCompletion(vm.input, vm.query, row)
             else: row.insert
  vm.setInput(next)
  true

proc open*(vm: ResultCommandsVM; index: int) =
  ## Opens row `index` (`selectableRows`): where its kind says
  ## (`openTargetOf`); a row that inserts text puts it into the field.
  let rows = vm.selectableRows
  if index < 0 or index >= rows.len: return
  vm.selected.val = index
  let row = rows[index]
  let target = openTargetOf(row)
  if target == otInsert:
    discard vm.insertSelected()
    return
  vm.openedRow = row.id
  vm.openedTarget = target
  vm.openedText = openedLine(row, target)
  vm.bump()
  if not vm.onOpen.isNil and target != otNone: vm.onOpen(row, target)

proc openSelected*(vm: ResultCommandsVM) =
  ## `Enter`.
  vm.open(vm.selected.val)

proc setHtmlEnabled*(vm: ResultCommandsVM; on: bool) =
  vm.htmlEnabled.val = on
  vm.bump()
