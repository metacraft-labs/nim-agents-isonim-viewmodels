## AgentWorkspaceVM (`agent_panels/agent_workspace_vm`), native and JS: the
## Agent Workspace sidebar's state, set through its setters, and the memos
## over it. The viewmodel keeps the host store it is given and reads nothing
## from it, so these cases give it none, or a bare `ViewModel`. Real IsoNim
## reactive core, no mocks. The data is invented, as everything in this public
## repository.

import std/unittest
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import nim_agents/activity_model
import nim_agents_isonim_viewmodels/agent_panels/agent_workspace_vm

proc file(path: string; covered = 0; total = 0): AgentWorkspaceFileEntry =
  AgentWorkspaceFileEntry(path: path, coveredLines: covered, totalLines: total)

suite "AgentWorkspaceVM":
  test "a new viewmodel is an empty workspace":
    createRoot proc(dispose: proc()) =
      let vm = newAgentWorkspaceVM()
      check vm.store.isNil
      check vm.viewKind.val == awvkAgentWorkspace
      check vm.workspacePath.val == ""
      check vm.sessionId.val == ""
      check vm.files.val.len == 0
      check vm.selectedFileIndex.val == 0
      check vm.coverageOverlayEnabled.val
      check vm.notificationCount.val == 0
      check vm.fileCount.val == 0
      check not vm.hasWorkspace.val
      check vm.selectedFile.val.path == ""
      check vm.selectedCoverageText.val == "--"
      dispose()

  test "the host store is kept as given":
    createRoot proc(dispose: proc()) =
      let store = ViewModel()
      let vm = newAgentWorkspaceVM(store)
      check vm.store == store
      let other = ViewModel()
      vm.store = other
      check vm.store == other
      dispose()

  test "metadata and the view kind":
    createRoot proc(dispose: proc()) =
      let vm = newAgentWorkspaceVM()
      vm.setViewKind(awvkUserWorkspace)
      vm.setWorkspaceMetadata("/tmp/agent", "session-1")
      check vm.viewKind.val == awvkUserWorkspace
      check vm.workspacePath.val == "/tmp/agent"
      check vm.sessionId.val == "session-1"
      check vm.hasWorkspace.val
      dispose()

  test "files keep the selection inside the list":
    createRoot proc(dispose: proc()) =
      let vm = newAgentWorkspaceVM()
      vm.setFiles(@[file("src/a.nim", 3, 4), file("src/b.nim", 0, 0)])
      check vm.fileCount.val == 2
      check vm.hasWorkspace.val
      check vm.selectedFile.val.path == "src/a.nim"
      check vm.selectedCoverageText.val == "3/4"
      vm.setSelectedFileIndex(9)
      check vm.selectedFileIndex.val == 1
      check vm.selectedFile.val.path == "src/b.nim"
      check vm.selectedCoverageText.val == "--"
      vm.setFiles(@[file("src/c.nim", 1, 2)])
      check vm.selectedFileIndex.val == 0
      check vm.selectedFile.val.path == "src/c.nim"
      vm.setSelectedFileIndex(-3)
      check vm.selectedFileIndex.val == 0
      dispose()

  test "the overlay toggle, the notification count and clearing":
    createRoot proc(dispose: proc()) =
      let vm = newAgentWorkspaceVM()
      vm.toggleCoverageOverlay()
      check not vm.coverageOverlayEnabled.val
      vm.setCoverageOverlayEnabled(true)
      check vm.coverageOverlayEnabled.val
      vm.setNotificationCount(3)
      check vm.notificationCount.val == 3
      vm.setNotificationCount(-2)
      check vm.notificationCount.val == 0
      vm.setSummary(AgentWorkspaceSummary(testsRun: 2))
      vm.setWorkspaceMetadata("/tmp/agent", "session-1")
      vm.setFiles(@[file("a", 1, 1)])
      vm.setCoverageOverlayEnabled(false)
      vm.setNotificationCount(5)
      vm.clearWorkspace()
      check vm.workspacePath.val == ""
      check vm.sessionId.val == ""
      check vm.summary.val == AgentWorkspaceSummary()
      check vm.fileCount.val == 0
      check vm.coverageOverlayEnabled.val
      check vm.notificationCount.val == 0
      check not vm.hasWorkspace.val
      dispose()
