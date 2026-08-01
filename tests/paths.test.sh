# tests/paths.test.sh — Windows <-> WSL path contract
. "$(dirname "$0")/harness.sh"

t_begin "paths: Windows -> WSL conversion"

t_assert_eq "$(fmw_path_to_wsl 'C:\CivilPlan')"        "/mnt/c/CivilPlan"        "to_wsl C:\CivilPlan"
t_assert_eq "$(fmw_path_to_wsl 'C:\Foo Bar\Baz')"      "/mnt/c/Foo Bar/Baz"      "to_wsl with spaces"
if wslpath -u 'D:\Repo' >/dev/null 2>&1; then
  t_assert_eq "$(fmw_path_to_wsl 'D:\Repo')" "/mnt/d/Repo" "to_wsl drive D: (mounted in this WSL)"
else
  t_ok "to_wsl unmounted drive -> fails (environment without D:)"
  t_assert_false fmw_path_to_wsl 'D:\Repo'
fi
t_assert_eq "$(fmw_path_to_wsl 'C:\Prueba ñandú\áéí')" "/mnt/c/Prueba ñandú/áéí" "to_wsl unicode"
t_assert_eq "$(fmw_path_to_wsl 'C:/Slashes/Ok')"       "/mnt/c/Slashes/Ok"       "to_wsl with /"

t_begin "paths: WSL -> Windows conversion"

t_assert_eq "$(fmw_path_to_windows '/mnt/c/CivilPlan')" "C:\\CivilPlan"          "to_windows /mnt/c/CivilPlan"
t_assert_eq "$(fmw_path_to_windows '/mnt/c/Foo Bar/Baz')" "C:\\Foo Bar\\Baz"     "to_windows with spaces"

t_begin "paths: canonicalization"

t_assert_eq "$(fmw_path_canonical '/mnt/C/CivilPlan')"  "/mnt/c/CivilPlan"       "uppercase drive -> lowercase"
t_assert_eq "$(fmw_path_canonical '/mnt/c/CivilPlan/')" "/mnt/c/CivilPlan"       "trailing slash removed"
t_assert_eq "$(fmw_path_canonical '/mnt/c/a/../b')"     "/mnt/c/b"               ".. resolved"

t_begin "paths: is_windows_mounted"

t_assert_true  fmw_path_is_windows_mounted "/mnt/c/FirstmateWorktrees"
t_assert_true  fmw_path_is_windows_mounted "/mnt/d/Repo"
t_assert_false fmw_path_is_windows_mounted "/home/leo/foo"
t_assert_false fmw_path_is_windows_mounted "/tmp/foo"
t_assert_false fmw_path_is_windows_mounted "/root/foo"

t_begin "paths: is_under"

t_assert_true  fmw_path_is_under "/mnt/c/FirstmateWorktrees/CivilPlan/t1" "/mnt/c/FirstmateWorktrees"
t_assert_true  fmw_path_is_under "/mnt/c/FirstmateWorktrees" "/mnt/c/FirstmateWorktrees"
t_assert_false fmw_path_is_under "/mnt/c/OtherWorktrees/t1" "/mnt/c/FirstmateWorktrees"
t_assert_false fmw_path_is_under "/mnt/c/FirstmateWorktreesX/t1" "/mnt/c/FirstmateWorktrees"

t_begin "paths: native WSL filesystem rejection"

t_assert_false fmw_path_reject_native_wsl "/home/leo/worktree"
t_assert_false fmw_path_reject_native_wsl "/tmp/wt"
t_assert_false fmw_path_reject_native_wsl "/var/wt"
t_assert_false fmw_path_reject_native_wsl "/root/wt"
t_assert_true  fmw_path_reject_native_wsl "/mnt/c/FirstmateWorktrees/wt"

t_begin "paths: task ID"

t_assert_true  fmw_task_id_valid "mudslab-audit"
t_assert_true  fmw_task_id_valid "a"
t_assert_true  fmw_task_id_valid "a1-b2-c3"
t_assert_false fmw_task_id_valid ""
t_assert_false fmw_task_id_valid "../../foo"
t_assert_false fmw_task_id_valid "A"
t_assert_false fmw_task_id_valid "id with space"
t_assert_false fmw_task_id_valid "id/with/slash"
t_assert_false fmw_task_id_valid "id\\with\\backslash"
t_assert_false fmw_task_id_valid "-lead"
t_assert_false fmw_task_id_valid "$(printf 'x%.0s' $(seq 1 64))"  # 64 chars > 63
t_assert_false fmw_task_id_valid 'a;rm -rf /'
t_assert_false fmw_task_id_valid '$(touch /tmp/pwned)'

t_begin "paths: validate_worktree_target (fail-closed)"

mkdir -p /mnt/c/FirstmateWorktrees/TestLab
t_assert_false fmw_path_validate_worktree_target "/mnt/c/FirstmateWorktrees/TestLab/wt/../../escape" "/mnt/c/FirstmateWorktrees/TestLab" "escape"  # outside root
t_assert_false fmw_path_validate_worktree_target "/mnt/c/FirstmateWorktrees/TestLab/otroid" "/mnt/c/FirstmateWorktrees/TestLab" "taskid"    # basename != id
t_assert_false fmw_path_validate_worktree_target "/home/leo/wt/taskid" "/home/leo/wt" "taskid"                                            # root not /mnt
t_assert_false fmw_path_validate_worktree_target "/tmp/wt/taskid" "/tmp/wt" "taskid"                                                    # root /tmp
t_assert_false fmw_path_validate_worktree_target "/mnt/c/FirstmateWorktrees/TestLab" "/mnt/c/FirstmateWorktrees/TestLab" "TestLab"      # exists (collision)

t_summary
