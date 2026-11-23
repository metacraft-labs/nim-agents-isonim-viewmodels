alias t := test
alias fmt := format

paths := "--path:src --path:../nim-agents/src --path:../nim-agent-harbor/src --path:../nim-acp/src --path:../nim-everywhere/src --path:../isonim/src"

build: build-native build-js

build-native:
    nim c {{paths}} tests/test_activity_vm.nim
    nim c {{paths}} tests/test_agent_harbor_fleet_vm.nim
    nim c {{paths}} tests/test_agent_harbor_sessions_vm.nim
    nim c {{paths}} tests/test_progress_pie.nim
    nim c {{paths}} tests/test_playback.nim
    nim c {{paths}} tests/test_session_timeline_vm.nim
    nim c {{paths}} tests/test_changes_vm.nim
    nim c {{paths}} tests/test_inbox_vm.nim
    nim c {{paths}} tests/test_inbox_item_vm.nim
    nim c {{paths}} tests/test_omnibox_composer_vm.nim
    nim c {{paths}} tests/test_result_commands_vm.nim
    nim c {{paths}} tests/test_suggested_actions_vm.nim
    nim c {{paths}} tests/test_test_runs_vm.nim
    nim c {{paths}} tests/test_trace_opener_vm.nim
    nim c {{paths}} tests/test_control_center_vm.nim
    nim c {{paths}} tests/test_nimcache_is_worktree_local.nim
    nim c {{paths}} tests/test_fixture_set_rebuilds_on_switch.nim

build-js:
    nim js {{paths}} tests/test_activity_vm.nim
    nim js {{paths}} tests/test_agent_harbor_fleet_vm.nim
    nim js {{paths}} tests/test_agent_harbor_sessions_vm.nim
    nim js {{paths}} tests/test_progress_pie.nim
    nim js {{paths}} tests/test_playback.nim
    nim js {{paths}} tests/test_session_timeline_vm.nim
    nim js {{paths}} tests/test_changes_vm.nim
    nim js {{paths}} tests/test_inbox_vm.nim
    nim js {{paths}} tests/test_inbox_item_vm.nim
    nim js {{paths}} tests/test_omnibox_composer_vm.nim
    nim js {{paths}} tests/test_result_commands_vm.nim
    nim js {{paths}} tests/test_suggested_actions_vm.nim
    nim js {{paths}} tests/test_test_runs_vm.nim
    nim js {{paths}} tests/test_trace_opener_vm.nim
    nim js {{paths}} tests/test_control_center_vm.nim

test: test-native test-js

test-native:
    nim c -r {{paths}} tests/test_activity_vm.nim
    nim c -r {{paths}} tests/test_agent_harbor_fleet_vm.nim
    nim c -r {{paths}} tests/test_agent_harbor_sessions_vm.nim
    nim c -r {{paths}} tests/test_progress_pie.nim
    nim c -r {{paths}} tests/test_playback.nim
    nim c -r {{paths}} tests/test_session_timeline_vm.nim
    nim c -r {{paths}} tests/test_changes_vm.nim
    nim c -r {{paths}} tests/test_inbox_vm.nim
    nim c -r {{paths}} tests/test_inbox_item_vm.nim
    nim c -r {{paths}} tests/test_omnibox_composer_vm.nim
    nim c -r {{paths}} tests/test_result_commands_vm.nim
    nim c -r {{paths}} tests/test_suggested_actions_vm.nim
    nim c -r {{paths}} tests/test_test_runs_vm.nim
    nim c -r {{paths}} tests/test_trace_opener_vm.nim
    nim c -r {{paths}} tests/test_control_center_vm.nim
    nim c -r {{paths}} tests/test_nimcache_is_worktree_local.nim
    nim c -r {{paths}} tests/test_fixture_set_rebuilds_on_switch.nim

test-js:
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_activity_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_agent_harbor_fleet_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_agent_harbor_sessions_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_progress_pie.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_playback.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_session_timeline_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_changes_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_inbox_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_inbox_item_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_omnibox_composer_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_result_commands_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_suggested_actions_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_test_runs_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_trace_opener_vm.nim
    bash tools/nim-js-test-gate.sh {{paths}} tests/test_control_center_vm.nim

lint: lint-nim lint-nix

lint-nim:
    nim check {{paths}} src/nim_agents_isonim_viewmodels.nim
    nim check {{paths}} tests/test_activity_vm.nim
    nim check {{paths}} tests/test_agent_harbor_fleet_vm.nim
    nim check {{paths}} tests/test_agent_harbor_sessions_vm.nim
    nim check {{paths}} tests/test_progress_pie.nim
    nim check {{paths}} tests/test_playback.nim
    nim check {{paths}} tests/test_session_timeline_vm.nim
    nim check {{paths}} tests/test_changes_vm.nim
    nim check {{paths}} tests/test_inbox_vm.nim
    nim check {{paths}} tests/test_inbox_item_vm.nim
    nim check {{paths}} tests/test_omnibox_composer_vm.nim
    nim check {{paths}} tests/test_result_commands_vm.nim
    nim check {{paths}} tests/test_suggested_actions_vm.nim
    nim check {{paths}} tests/test_test_runs_vm.nim
    nim check {{paths}} tests/test_trace_opener_vm.nim
    nim check {{paths}} tests/test_nimcache_is_worktree_local.nim
    nim check {{paths}} tests/test_fixture_set_rebuilds_on_switch.nim

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    nimpretty src/nim_agents_isonim_viewmodels.nim src/nim_agents_isonim_viewmodels/*.nim src/nim_agents_isonim_viewmodels/agent_harbor/*.nim tests/*.nim

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i "s/^version       = .*/version       = \"{{version}}\"/" nim_agents_isonim_viewmodels.nimble
    printf "%s\n" "{{version}}" > VERSION
