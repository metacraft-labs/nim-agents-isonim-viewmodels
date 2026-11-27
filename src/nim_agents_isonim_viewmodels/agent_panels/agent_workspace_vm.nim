## nim_agents_isonim_viewmodels/agent_panels/agent_workspace_vm.nim
##
## AgentWorkspaceVM — the Agent Workspace sidebar: one agent session's
## workspace as a file list with a selected row, per-file coverage badges, a
## coverage-overlay toggle and a notification count. UI pattern: a sidebar
## list with a single selection.
##
## Moved from CodeTracer's `viewmodels/agent_workspace_vm.nim` (CTF-M1, D87
## (a)). The rules it applies (which row a selection lands on, the badge text,
## when there is a workspace at all) are nim-agents' `workspace`; this module
## keeps only the signals and memos that publish them.
##
## The host store. CodeTracer's legacy ``AgentWorkspaceComponent`` remains the
## ACP/DeepReview IPC state carrier and Monaco owner and feeds this viewmodel
## through its setters. The viewmodel keeps the store it was created with
## (`store`) and reads nothing from it: that is the whole store interface, a
## field typed as IsoNim's `ViewModel`, which CodeTracer's `ReplayDataStore`
## is. A reader added later widens the interface by exactly what it reads.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import nim_agents/[activity_model, workspace]

export workspace

type
  AgentWorkspaceVM* = ref object of ViewModel
    store*: ViewModel
      ## The host store this viewmodel was created with; never read here.

    viewKind*: Signal[AgentWorkspaceViewKind]
    workspacePath*: Signal[string]
    sessionId*: Signal[string]
    summary*: Signal[AgentWorkspaceSummary]
    files*: Signal[seq[AgentWorkspaceFileEntry]]
    selectedFileIndex*: Signal[int]
    coverageOverlayEnabled*: Signal[bool]
    notificationCount*: Signal[int]

    fileCount*: Memo[int]
    hasWorkspace*: Memo[bool]
    selectedFile*: Memo[AgentWorkspaceFileEntry]
    selectedCoverageText*: Memo[string]

# `clampSelectedIndex`, `coverageBadgeText`, `selectedFileOf` and
# `hasWorkspaceOf` live in `nim_agents/workspace`, re-exported above.

proc setViewKind*(vm: AgentWorkspaceVM; kind: AgentWorkspaceViewKind) =
  vm.viewKind.val = kind

proc setWorkspaceMetadata*(vm: AgentWorkspaceVM; path, sessionId: string) =
  vm.workspacePath.val = path
  vm.sessionId.val = sessionId

proc setSummary*(vm: AgentWorkspaceVM; summary: AgentWorkspaceSummary) =
  vm.summary.val = summary

proc setFiles*(vm: AgentWorkspaceVM; files: openArray[AgentWorkspaceFileEntry]) =
  vm.files.val = @files
  vm.selectedFileIndex.val = clampSelectedIndex(
    vm.selectedFileIndex.val, vm.files.val.len)

proc setSelectedFileIndex*(vm: AgentWorkspaceVM; index: int) =
  vm.selectedFileIndex.val = clampSelectedIndex(index, vm.files.val.len)

proc setCoverageOverlayEnabled*(vm: AgentWorkspaceVM; enabled: bool) =
  vm.coverageOverlayEnabled.val = enabled

proc toggleCoverageOverlay*(vm: AgentWorkspaceVM) =
  vm.coverageOverlayEnabled.val = not vm.coverageOverlayEnabled.val

proc setNotificationCount*(vm: AgentWorkspaceVM; count: int) =
  vm.notificationCount.val = max(0, count)

proc clearWorkspace*(vm: AgentWorkspaceVM) =
  vm.workspacePath.val = ""
  vm.sessionId.val = ""
  vm.summary.val = AgentWorkspaceSummary()
  vm.files.val = @[]
  vm.selectedFileIndex.val = 0
  vm.coverageOverlayEnabled.val = true
  vm.notificationCount.val = 0

proc newAgentWorkspaceVM*(store: ViewModel = nil): AgentWorkspaceVM =
  ## An empty workspace: no files, the first row selected, the coverage
  ## overlay on. CodeTracer creates it through its `createAgentWorkspaceVM`,
  ## which passes its `ReplayDataStore`.
  withViewModel proc(dispose: proc()): AgentWorkspaceVM =
    let viewKind = createSignal(awvkAgentWorkspace)
    let workspacePath = createSignal("")
    let sessionId = createSignal("")
    let summary = createSignal(AgentWorkspaceSummary())
    let files = createSignal(newSeq[AgentWorkspaceFileEntry]())
    let selectedFileIndex = createSignal(0)
    let coverageOverlayEnabled = createSignal(true)
    let notificationCount = createSignal(0)

    let fileCount = createMemo[int] proc(): int =
      files.val.len

    let hasWorkspace = createMemo[bool] proc(): bool =
      hasWorkspaceOf(files.val.len, sessionId.val)

    let selectedFile = createMemo[AgentWorkspaceFileEntry] proc():
        AgentWorkspaceFileEntry =
      selectedFileOf(files.val, selectedFileIndex.val)

    let selectedCoverageText = createMemo[string] proc(): string =
      coverageBadgeText(selectedFile.val)

    AgentWorkspaceVM(
      store: store,
      viewKind: viewKind,
      workspacePath: workspacePath,
      sessionId: sessionId,
      summary: summary,
      files: files,
      selectedFileIndex: selectedFileIndex,
      coverageOverlayEnabled: coverageOverlayEnabled,
      notificationCount: notificationCount,
      fileCount: fileCount,
      hasWorkspace: hasWorkspace,
      selectedFile: selectedFile,
      selectedCoverageText: selectedCoverageText,
      disposeProc: dispose,
    )
