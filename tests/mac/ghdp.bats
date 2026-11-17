#!/usr/bin/env bats
# Tests for mac/ghdp. They use a throwaway home folder, so they never touch
# your real settings. Tests that need GitHub Desktop are skipped without it.
# Run: bats tests/mac

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GHDP="$REPO/mac/ghdp"
  export HOME="$BATS_TEST_TMPDIR/home"
  /bin/mkdir -p "$HOME/Library/Application Support"
  unset GHDP_GUI NODE_OPTIONS ELECTRON_RUN_AS_NODE
  # shellcheck source=mac/ghdp # (path from the repo root, where checks run)
  source "$GHDP"
  set +u # bats itself is not written for "set -u"
}

GOOD='{"version":1,"profiles":[
  {"name":"office","gitName":"Ada Lovelace","gitEmail":"1+ada-work@users.noreply.github.com"},
  {"name":"personal","gitName":"Ada L","gitEmail":"ada@example.org"}]}'

write_config() {
  ensure_private_dir "$(base_dir)"
  printf '%s' "$1" >"$(config_path)"
  /bin/chmod 600 "$(config_path)"
}

need_app() {
  [ -d "/Applications/GitHub Desktop.app" ] || skip "GitHub Desktop is not installed"
}

# Expect the last `run` to have failed with a message containing $1.
refused_with() {
  [ "$status" -ne 0 ] || { echo "expected a refusal, got success: $output"; return 1; }
  [[ $output == *"$1"* ]] || { echo "expected message containing: $1"; echo "got: $output"; return 1; }
}

# ---------------------------------------------------------------- names

@test "valid_name accepts good names" {
  local n
  for n in office Personal p_2 a-b 7 "$(printf 'a%.0s' {1..32})"; do
    valid_name "$n" || { echo "refused: $n"; return 1; }
  done
}

@test "valid_name refuses bad and tricky names" {
  local n
  # shellcheck disable=SC2016 # literal $ and backticks are the attack inputs
  for n in "" "-rf" "_x" "a b" "a/b" "../x" ".." "a.b" "$(printf 'a%.0s' {1..33})" \
    con Nul LPT1 COM9 $'of\nfice' $'office\n' "offïce" 'a$b' 'a;b' '`id`' '$(id)'; do
    if valid_name "$n"; then echo "accepted: $n"; return 1; fi
  done
}

@test "valid_email accepts and refuses the right things" {
  valid_email "1+ada@users.noreply.github.com"
  valid_email "a.b-c@example.co"
  local e
  for e in "CHANGE-ME" "a@b" "a b@c.com" "a@b.c" 'a"b@c.com' "$(printf 'a@b.com\nx')" "a@b.com " \
    "$(printf 'a%.0s' {1..250})@b.com"; do
    if valid_email "$e"; then echo "accepted: $e"; return 1; fi
  done
}

@test "valid_git_name allows real names and refuses unsafe ones" {
  valid_git_name "Ada Lovelace"
  valid_git_name "José Núñez"
  valid_git_name "O'Brien"
  local v
  for v in "" "CHANGE ME" 'a"b' 'a\b' " lead" "trail " "-dash" "$(printf 'a\tb')" "$(printf 'a\nb')" \
    "$(printf 'a%.0s' {1..101})"; do
    if valid_git_name "$v"; then echo "accepted: $v"; return 1; fi
  done
}

@test "norm_name ignores case and - versus _" {
  [ "$(norm_name Office_A)" = "office-a" ]
}

# ---------------------------------------------------------------- paths

@test "paths are built under the private base folder" {
  [ "$(profile_dir office)" = "$HOME/Library/Application Support/gh-desktop-profiles/profiles/office" ]
  [ "$(data_dir office)" = "$(profile_dir office)/desktop-data" ]
  [ "$(gitconfig_path office)" = "$(profile_dir office)/gitconfig" ]
  [ "$(launcher_path office)" = "$HOME/Applications/GitHub Desktop - office.app" ]
}

@test "path functions refuse bad names" {
  run profile_dir "../evil"
  refused_with "is not allowed"
  run launcher_path "a/b"
  refused_with "is not allowed"
}

@test "check_home refuses unusual home paths" {
  local h
  # shellcheck disable=SC2016 # literal $ and backticks are the attack inputs
  for h in '/tmp/a"b' '/tmp/a$b' '/tmp/a`b' 'relative/path' '/tmp/../etc' "/tmp/a
b"; do
    HOME="$h" run check_home
    refused_with "home folder" || { echo "for HOME=$h"; return 1; }
  done
  run check_home
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------- permissions

@test "ensure_private_dir creates a 700 folder" {
  ensure_private_dir "$HOME/p"
  [ "$(stat -f %Sp "$HOME/p")" = "drwx------" ]
}

@test "ensure_private_dir fixes a folder others can read" {
  /bin/mkdir -m 755 "$HOME/p"
  ensure_private_dir "$HOME/p"
  [ "$(stat -f %Sp "$HOME/p")" = "drwx------" ]
}

@test "ensure_private_dir removes extra access rules (ACLs)" {
  /bin/mkdir -m 700 "$HOME/p"
  /bin/chmod +a "everyone allow list,search" "$HOME/p"
  [[ $(stat -f %Sp "$HOME/p") == *+ ]]
  ensure_private_dir "$HOME/p"
  [ "$(stat -f %Sp "$HOME/p")" = "drwx------" ]
}

@test "ensure_private_dir refuses a symlink" {
  /bin/mkdir "$HOME/target"
  /bin/ln -s "$HOME/target" "$HOME/link"
  run ensure_private_dir "$HOME/link"
  refused_with "is a link"
}

@test "ensure_private_dir refuses a file where a folder should be" {
  : >"$HOME/file"
  run ensure_private_dir "$HOME/file"
  refused_with "is not a folder"
}

@test "ensure_private_file fixes the mode and refuses a symlink" {
  : >"$HOME/f"
  /bin/chmod 644 "$HOME/f"
  ensure_private_file "$HOME/f" 600
  [ "$(stat -f %Lp "$HOME/f")" = "600" ]
  /bin/ln -s "$HOME/f" "$HOME/flink"
  run ensure_private_file "$HOME/flink" 600
  refused_with "is a link"
}

@test "writable_by_others spots group and other write access" {
  : >"$HOME/f"
  /bin/chmod 700 "$HOME/f"
  run writable_by_others "$HOME/f"
  [ "$status" -ne 0 ]
  /bin/chmod 770 "$HOME/f"
  writable_by_others "$HOME/f"
  /bin/chmod 702 "$HOME/f"
  writable_by_others "$HOME/f"
}

# --------------------------------------------------------------- config

@test "a good config loads both profiles" {
  write_config "$GOOD"
  load_config
  [ "${#P_NAMES[@]}" -eq 2 ]
  [ "${P_NAMES[0]}" = "office" ]
  [ "${P_GIT_NAMES[0]}" = "Ada Lovelace" ]
  [ "${P_GIT_EMAILS[1]}" = "ada@example.org" ]
}

@test "the example config is valid JSON but refused until edited" {
  write_config "$(cat "$REPO/profiles.example.json")"
  run load_config
  refused_with "CHANGE ME"
}

@test "missing config tells you to run init" {
  run load_config
  refused_with "ghdp init"
}

@test "config with wrong permissions is fixed to 600" {
  write_config "$GOOD"
  /bin/chmod 644 "$(config_path)"
  load_config
  [ "$(stat -f %Lp "$(config_path)")" = "600" ]
}

@test "a symlinked config is refused" {
  ensure_private_dir "$(base_dir)"
  printf '%s' "$GOOD" >"$HOME/elsewhere.json"
  /bin/ln -s "$HOME/elsewhere.json" "$(config_path)"
  run load_config
  refused_with "is a link"
}

@test "config problems are refused with a clear message" {
  local cases=(
    '{bad json|not valid JSON'
    '[1,2]|"version": 1'
    '{"version":2,"profiles":[]}|"version": 1'
    '{"version":"1","profiles":[]}|"version": 1'
    '{"version":1}|"profiles" list'
    '{"version":1,"profiles":[]}|between 1 and'
    '{"version":1,"profiles":[],"extra":true}|Unknown setting "extra"'
    '{"version":1,"profiles":["office"]}|not an object'
    '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmial":"a@b.co"}]}|Unknown setting "gitEmial"'
    '{"version":1,"profiles":[{"name":"o","gitName":"A"}]}|"gitEmail" as text'
    '{"version":1,"profiles":[{"name":5,"gitName":"A","gitEmail":"a@b.co"}]}|"name" as text'
    '{"version":1,"profiles":[{"name":"../x","gitName":"A","gitEmail":"a@b.co"}]}|is not allowed'
    '{"version":1,"profiles":[{"name":"o","gitName":"A\"B","gitEmail":"a@b.co"}]}|gitName'
    '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"nope"}]}|not a valid email'
    '{"version":1,"profiles":[{"name":"Office","gitName":"A","gitEmail":"a@b.co"},{"name":"office","gitName":"B","gitEmail":"b@b.co"}]}|same name'
    '{"version":1,"profiles":[{"name":"a_b","gitName":"A","gitEmail":"a@b.co"},{"name":"a-b","gitName":"B","gitEmail":"b@b.co"}]}|same name'
    '{"version":1,"profiles":[{"name":{"n":"o"},"gitName":"A","gitEmail":"a@b.co"}]}|"name" as text'
    '{"version":1,"profiles":[{"name":"o","gitName":"A\nB","gitEmail":"a@b.co"}]}|line break'
    '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"a@b.co","folders":"~/w"}]}|as a list'
    '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"a@b.co","repos":"a/b"}]}|as a list'
    '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"a@b.co","repos":["not a repo"]}]}|"repos" item that is not allowed'
  )
  local c json want
  for c in "${cases[@]}"; do
    json="${c%|*}"
    want="${c##*|}"
    write_config "$json"
    run load_config
    refused_with "$want" || { echo "for config: $json"; return 1; }
  done
}

@test "more than 20 profiles is refused" {
  local i list=""
  for i in $(seq 1 21); do list="$list{\"name\":\"p$i\",\"gitName\":\"A\",\"gitEmail\":\"a@b.co\"},"; done
  write_config "{\"version\":1,\"profiles\":[${list%,}]}"
  run load_config
  refused_with "between 1 and 20"
}

# --------------------------------------------------------------- launch

@test "launch refuses bad arguments" {
  write_config "$GOOD"
  run main launch
  refused_with "Which profile"
  run main launch --evil
  refused_with "Unknown option"
  run main launch office personal
  refused_with "only one profile"
  run main launch "../x"
  refused_with "is not allowed"
  run main launch nobody
  refused_with "no profile called"
}

@test "launch refuses when NODE_OPTIONS is set" {
  write_config "$GOOD"
  NODE_OPTIONS="--require /tmp/evil.js" run main launch office --dry-run
  refused_with "NODE_OPTIONS"
  ELECTRON_RUN_AS_NODE=1 run main launch office --dry-run
  refused_with "ELECTRON_RUN_AS_NODE"
}

@test "launch --dry-run shows fixed arguments and changes nothing" {
  need_app
  write_config "$GOOD"
  run main launch office --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"--user-data-dir=$HOME/Library/Application Support/gh-desktop-profiles/profiles/office/desktop-data"* ]]
  [[ $output == *"GIT_AUTHOR_EMAIL=1+ada-work@users.noreply.github.com"* ]]
  [[ $output == *"GIT_COMMITTER_NAME=Ada Lovelace"* ]]
  [[ $output == *"GHDP_PROFILE=office"* ]]
  [ ! -e "$(profile_dir office)" ]
}

# -------------------------------------------------------------- install

@test "install creates private folders, gitconfig and launchers" {
  need_app
  write_config "$GOOD"
  run main install
  [ "$status" -eq 0 ]
  [ "$(stat -f %Sp "$(data_dir office)")" = "drwx------" ]
  [ "$(stat -f %Lp "$(gitconfig_path office)")" = "600" ]
  [ "$(stat -f %Lp "$(bin_path)")" = "700" ]
  grep -q "email = 1+ada-work@users.noreply.github.com" "$(gitconfig_path office)"
  grep -q "path = ~/.gitconfig" "$(gitconfig_path office)"
  local l
  l="$(launcher_path office)"
  [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$l/Contents/Info.plist")" = "io.github.gh-desktop-profiles.office" ]
  [ "$(stat -f %Sp "$l/Contents/MacOS/launch")" = "-rwx------" ]
  [ "$(tail -n 1 "$l/Contents/MacOS/launch")" = "exec /bin/bash \"$(bin_path)\" launch \"office\"" ]
}

@test "install says the launchers are in your home folder's Applications, not the main one" {
  need_app
  write_config "$GOOD"
  run main install
  [ "$status" -eq 0 ]
  [[ $output == *"$HOME/Applications"* ]] || false
  [[ $output == *"NOT the main Applications folder"* ]] || false
}

@test "install twice gives the same result (idempotent)" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  local before after
  before="$(cat "$(gitconfig_path office)")"
  run main install
  [ "$status" -eq 0 ]
  after="$(cat "$(gitconfig_path office)")"
  [ "$before" = "$after" ]
  [ "$(grep -c '^\[user\]' "$(gitconfig_path office)")" -eq 1 ]
}

@test "install keeps settings GitHub Desktop added and resets name and email" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  local git="/Applications/GitHub Desktop.app/Contents/Resources/app/git/bin/git"
  "$git" config --file "$(gitconfig_path office)" init.defaultBranch trunk
  "$git" config --file "$(gitconfig_path office)" user.email someone@else.com
  main install >/dev/null
  [ "$("$git" config --file "$(gitconfig_path office)" init.defaultBranch)" = "trunk" ]
  [ "$("$git" config --file "$(gitconfig_path office)" user.email)" = "1+ada-work@users.noreply.github.com" ]
}

@test "install never overwrites an app it did not make" {
  need_app
  write_config "$GOOD"
  local l
  l="$(launcher_path office)"
  /bin/mkdir -p "$l/Contents"
  printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>' >"$l/Contents/Info.plist"
  run main install
  refused_with "was not made by this tool"
}

# ---------------------------------------------------------- setup wizard

# A fake "normal GitHub Desktop" data folder with things that must NOT be
# copied (cache, logs, lock link, a link pointing outside).
make_normal_data() {
  local n
  n="$(normal_data_dir)"
  /bin/mkdir -p "$n/Local Storage/leveldb" "$n/IndexedDB/file__0.indexeddb.leveldb" "$n/Cache/Cache_Data" "$n/logs"
  echo users >"$n/Local Storage/leveldb/000003.log"
  : >"$n/Local Storage/leveldb/LOCK"
  echo repos >"$n/IndexedDB/file__0.indexeddb.leveldb/000005.log"
  echo big >"$n/Cache/Cache_Data/f"
  echo log >"$n/logs/a.log"
  /bin/ln -s /etc/hosts "$n/SingletonLock"
  /bin/ln -s /etc "$n/evil-link"
}

@test "desktop_holds_data sees when a program holds the database lock" {
  make_normal_data
  run desktop_holds_data "$(normal_data_dir)"
  [ "$status" -ne 0 ]
  # Hold the lock open on fd 8 (bats itself uses fd 3).
  exec 8<"$(normal_data_dir)/Local Storage/leveldb/LOCK"
  desktop_holds_data "$(normal_data_dir)"
  exec 8<&-
}

@test "copy_desktop_data skips caches, logs and links, and never overwrites" {
  make_normal_data
  ensure_private_dir "$(base_dir)"
  copy_desktop_data "$(normal_data_dir)" "$HOME/copy"
  [ -f "$HOME/copy/Local Storage/leveldb/000003.log" ]
  [ -f "$HOME/copy/IndexedDB/file__0.indexeddb.leveldb/000005.log" ]
  [ ! -e "$HOME/copy/Cache" ]
  [ ! -e "$HOME/copy/logs" ]
  [ ! -e "$HOME/copy/SingletonLock" ] && [ ! -L "$HOME/copy/SingletonLock" ]
  [ ! -e "$HOME/copy/evil-link" ] && [ ! -L "$HOME/copy/evil-link" ]
  [ "$(stat -f %Sp "$HOME/copy")" = "drwx------" ]
  run copy_desktop_data "$(normal_data_dir)" "$HOME/copy"
  refused_with "already exists"
}

@test "setup asks again on bad answers, imports, and leaves the original alone" {
  need_app
  make_normal_data
  local before
  before="$(cd "$(normal_data_dir)" && find . | sort | shasum)"
  run main setup <<<$'\nbad name!\npersonal\n\nAda L\n\nada@example.org\n~/code/personal\n\n\nPersonal\noffice\n\nnope\n1+ada-work@users.noreply.github.com\n~/work, ../bad\n~/work\nacme, Bad_Owner\nacme\n\n\n'
  [ "$status" -eq 0 ]
  [[ $output == *"That name is not allowed"* ]]
  [[ $output == *"Please type your name"* ]]
  [[ $output == *"already have a profile with that name"* ]]
  [[ $output == *"does not look like an email"* ]]
  load_config
  [ "${P_NAMES[*]}" = "personal office" ]
  [ "${P_GIT_EMAILS[1]}" = "1+ada-work@users.noreply.github.com" ]
  [ "$(expand_folder "${P_FOLDERS[1]}")" = "$HOME/work" ]
  [ "${P_OWNERS[1]}" = "acme" ]
  [ "$(expand_folder "${P_FOLDERS[0]}")" = "$HOME/code/personal" ]
  [ -z "${P_OWNERS[0]}" ]
  [[ $output == *"\"../bad\" is not allowed"* ]]
  [[ $output == *"\"Bad_Owner\" is not allowed"* ]]
  [ -f "$(data_dir personal)/Local Storage/leveldb/000003.log" ]
  [ ! -e "$(data_dir personal)/Cache" ]
  [ -z "$(ls -A "$(data_dir office)")" ]
  [ -d "$(launcher_path office)" ]
  [ "$before" = "$(cd "$(normal_data_dir)" && find . | sort | shasum)" ]
}

@test "setup without existing GitHub Desktop data just asks for profiles" {
  need_app
  run main setup <<<$'solo\nAda\na@b.co\n\n\nn\nn\n\n'
  [ "$status" -eq 0 ]
  [[ $output != *"Copy them into your first profile"* ]]
  load_config
  [ "${P_NAMES[*]}" = "solo" ]
}

@test "setup cancelled half way writes nothing" {
  need_app
  run main setup <<<$'solo\nAda\n'
  refused_with "Setup was cancelled"
  [ ! -e "$(config_path)" ]
}

@test "setup with profiles: option 4 only refreshes launchers, option 3 starts over and backs up" {
  need_app
  write_config "$GOOD"
  run main setup <<<$'4\n'
  [ "$status" -eq 0 ]
  [[ $output == *"Ready: office"* ]]
  [ "$(cat "$(config_path)")" = "$GOOD" ]
  [ -d "$(launcher_path personal)" ]
  run main setup <<<$'3\nsolo\nAda\na@b.co\n\n\nn\nn\n\n'
  [ "$status" -eq 0 ]
  [ "$(cat "$(config_path).bak")" = "$GOOD" ]
  [ "$(stat -f %Lp "$(config_path).bak")" = "600" ]
}

# ------------------------------------------------- icons, cleanup, uninstall

# A launcher-like app made by someone else, which must never be touched.
make_foreign_app() {
  /bin/mkdir -p "$HOME/Applications/Other.app/Contents"
  printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>' \
    >"$HOME/Applications/Other.app/Contents/Info.plist"
}

@test "install gives each launcher a badge icon" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  run /usr/bin/file -b "$(launcher_path office)/Contents/Resources/AppIcon.icns"
  [[ $output == "Mac OS X icon"* ]]
  [ "$(badge_color 0)" != "$(badge_color 1)" ]
}

@test "install removes launchers of old profiles but nothing else" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  make_foreign_app
  write_config '{"version":1,"profiles":[{"name":"office","gitName":"Ada","gitEmail":"a@b.co"}]}'
  run main install
  [ "$status" -eq 0 ]
  [[ $output == *"Removed the launcher of an old profile"* ]]
  [ ! -e "$(launcher_path personal)" ]
  [ -d "$(launcher_path office)" ]
  [ -d "$HOME/Applications/Other.app" ]
}

@test "our_launchers ignores other apps and symlinks" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  make_foreign_app
  /bin/ln -s "$(launcher_path office)" "$HOME/Applications/Link.app"
  run our_launchers
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  [[ $output != *"Other.app"* ]]
  [[ $output != *"Link.app"* ]]
}

@test "uninstall does nothing unless you say yes" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  run main uninstall <<<$'\n'
  [ "$status" -eq 0 ]
  [[ $output == *"Nothing changed"* ]]
  [ -d "$(launcher_path office)" ]
}

@test "uninstall removes launchers and the tool, keeps data if you say no" {
  need_app
  make_normal_data
  local before
  before="$(cd "$(normal_data_dir)" && find . | sort | shasum)"
  write_config "$GOOD"
  main install >/dev/null
  make_foreign_app
  run main uninstall <<<$'y\nn\n'
  [ "$status" -eq 0 ]
  [ ! -e "$(launcher_path office)" ] && [ ! -e "$(launcher_path personal)" ]
  [ ! -e "$(bin_path)" ]
  [ -f "$(config_path)" ]
  [ -d "$(data_dir office)" ]
  [ -d "$HOME/Applications/Other.app" ]
  [ "$before" = "$(cd "$(normal_data_dir)" && find . | sort | shasum)" ]
  [[ $output == *"Keychain"* ]] || false
  # The downloaded project folder is left alone, but you are told you can delete it.
  [[ $output == *"You can now delete the folder you downloaded"* ]] || false
  [[ $output == *"$(cd "$REPO" && pwd -P)"* ]] || false
  [ -f "$REPO/mac/ghdp" ]
}

@test "uninstall from the installed copy does not point at a download folder" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  run /bin/bash "$(bin_path)" uninstall <<<$'y\nn\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output != *"You can now delete the folder you downloaded"* ]] || false
}

@test "uninstall moves profile data to the Trash only when you say yes" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  # Use a Trash inside the test home instead of your real Trash.
  move_to_trash() { /bin/mkdir -p "$HOME/.Trash" && /bin/mv "$1" "$HOME/.Trash/"; }
  run main uninstall <<<$'y\ny\n'
  [ "$status" -eq 0 ]
  [ ! -e "$(base_dir)" ]
  [ -f "$HOME/.Trash/gh-desktop-profiles/profiles.json" ]
}

@test "double-click files run setup and uninstall from the project folder" {
  [ -x "$REPO/install-mac.command" ] && [ -x "$REPO/uninstall-mac.command" ]
  grep -q '/bin/bash ./mac/ghdp setup' "$REPO/install-mac.command"
  grep -q '/bin/bash ./mac/ghdp uninstall' "$REPO/uninstall-mac.command"
}

# --------------------------------------------------- wrong-account guard
# These run real Git, exactly as a GitHub Desktop profile would (same
# settings), in throwaway repos inside the test home folder.

setup_guard() {
  write_config '{"version":1,"profiles":[
    {"name":"office","gitName":"Ada","gitEmail":"ada@work.example","folders":["~/work"],"owners":["Acme"]},
    {"name":"personal","gitName":"Ada","gitEmail":"ada@home.example","folders":["~/personal"]}]}'
  load_config
  ensure_private_dir "$(base_dir)/profiles"
  local i=0 pd
  while [ "$i" -lt "${#P_NAMES[@]}" ]; do
    pd="$(profile_dir "${P_NAMES[$i]}")"
    ensure_private_dir "$pd"
    write_guard "$i" "$pd"
    i=$((i + 1))
  done
}

# Run a command with the Git settings the launcher gives a profile.
as_profile() {
  local i
  i="$(find_profile "$1")"
  shift
  /usr/bin/env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME="${P_GIT_NAMES[$i]}" GIT_AUTHOR_EMAIL="${P_GIT_EMAILS[$i]}" \
    GIT_COMMITTER_NAME="${P_GIT_NAMES[$i]}" GIT_COMMITTER_EMAIL="${P_GIT_EMAILS[$i]}" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$(profile_dir "${P_NAMES[$i]}")/hooks" \
    "$@"
}

# A repo with one staged file and an optional origin URL.
new_repo() {
  /bin/mkdir -p "$1"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$1" init -q -b main
  if [ -n "${2:-}" ]; then git -C "$1" remote add origin "$2"; fi
  echo x >"$1/f"
  git -C "$1" add f
}

ZERO="$(printf '0%.0s' {1..40})"

@test "guard rules hold expanded folders and lowercase owners" {
  setup_guard
  grep -qx "email=ada@work.example" "$(profile_dir office)/guard.rules"
  grep -qx "folder=$HOME/work" "$(profile_dir office)/guard.rules"
  grep -qx "owner=acme" "$(profile_dir office)/guard.rules"
  [ -x "$(profile_dir office)/hooks/pre-commit" ] && [ -x "$(profile_dir office)/hooks/commit-msg" ]
  [ "$(stat -f %Lp "$(profile_dir office)/guard.rules")" = "600" ]
}

@test "guard allows a commit in the right folder with the right account" {
  setup_guard
  new_repo "$HOME/work/app" "https://github.com/acme/app.git"
  run as_profile office git -C "$HOME/work/app" commit -q -m test
  [ "$status" -eq 0 ]
}

@test "guard stops a repo of another profile and names that profile" {
  setup_guard
  new_repo "$HOME/work/app"
  run as_profile personal git -C "$HOME/work/app" commit -q -m test
  refused_with 'belongs to the "office" profile'
}

@test "guard stops a repo outside this profile's folders" {
  setup_guard
  new_repo "$HOME/elsewhere/x"
  run as_profile office git -C "$HOME/elsewhere/x" commit -q -m test
  refused_with "outside the folders"
}

@test "guard stops a repo of a GitHub owner this profile does not use" {
  setup_guard
  new_repo "$HOME/work/evil" "git@github.com:EvilCorp/x.git"
  run as_profile office git -C "$HOME/work/evil" commit -q -m test
  # The owner is shown as the remote writes it, not lower-cased.
  refused_with 'belongs to "EvilCorp"'
}

@test "guard stops a commit with the wrong email" {
  setup_guard
  new_repo "$HOME/work/app"
  run as_profile office env GIT_AUTHOR_EMAIL=someone@else.example git -C "$HOME/work/app" commit -q -m test
  refused_with 'would use the email "someone@else.example"'
}

@test "guard never shows a token from a remote URL" {
  setup_guard
  new_repo "$HOME/work/tok" "https://user:SECRET123@github.com/evilcorp/x.git"
  run as_profile office git -C "$HOME/work/tok" commit -q -m test
  refused_with "evilcorp"
  [[ $output != *"SECRET123"* ]]
}

@test "repo hooks still run after the guard, and can still block" {
  setup_guard
  new_repo "$HOME/work/h"
  printf '#!/bin/sh\ntouch "%s/pre"\n' "$HOME" >"$HOME/work/h/.git/hooks/pre-commit"
  printf '#!/bin/sh\ntouch "%s/msg"\n' "$HOME" >"$HOME/work/h/.git/hooks/commit-msg"
  chmod +x "$HOME/work/h/.git/hooks/pre-commit" "$HOME/work/h/.git/hooks/commit-msg"
  run as_profile office git -C "$HOME/work/h" commit -q -m test
  [ "$status" -eq 0 ]
  [ -f "$HOME/pre" ] && [ -f "$HOME/msg" ]
  printf '#!/bin/sh\necho "repo hook says no" >&2\nexit 1\n' >"$HOME/work/h/.git/hooks/pre-commit"
  echo y >"$HOME/work/h/f" && git -C "$HOME/work/h" add f
  run as_profile office git -C "$HOME/work/h" commit -q -m test2
  refused_with "repo hook says no"
}

@test "guard also runs in repos with their own hooks folder (husky style)" {
  setup_guard
  new_repo "$HOME/work/hk"
  git -C "$HOME/work/hk" config core.hooksPath .husky
  /bin/mkdir -p "$HOME/work/hk/.husky"
  printf '#!/bin/sh\ntouch "%s/husky"\n' "$HOME" >"$HOME/work/hk/.husky/pre-commit"
  chmod +x "$HOME/work/hk/.husky/pre-commit"
  run as_profile office git -C "$HOME/work/hk" commit -q -m test
  [ "$status" -eq 0 ]
  [ -f "$HOME/husky" ]
  new_repo "$HOME/elsewhere/hk2"
  git -C "$HOME/elsewhere/hk2" config core.hooksPath .husky
  run as_profile office git -C "$HOME/elsewhere/hk2" commit -q -m test
  refused_with "outside the folders"
}

@test "pre-push stops a push to an owner this profile does not use" {
  setup_guard
  new_repo "$HOME/work/p" "https://github.com/acme/p.git"
  as_profile office git -C "$HOME/work/p" commit -q -m test
  cd "$HOME/work/p"
  run as_profile office "$(profile_dir office)/hooks/pre-push" other https://github.com/evilcorp/p.git \
    <<<"refs/heads/main $(git rev-parse HEAD) refs/heads/main $ZERO"
  refused_with 'belongs to "evilcorp"'
  run as_profile office "$(profile_dir office)/hooks/pre-push" origin https://github.com/acme/p.git \
    <<<"refs/heads/main $(git rev-parse HEAD) refs/heads/main $ZERO"
  [ "$status" -eq 0 ]
}

@test "pre-push stops commits that were made with another email" {
  setup_guard
  new_repo "$HOME/work/q" "https://github.com/acme/q.git"
  as_profile office env GIT_COMMITTER_EMAIL=other@else.example git -C "$HOME/work/q" commit -q --no-verify -m sneaky
  cd "$HOME/work/q"
  run as_profile office "$(profile_dir office)/hooks/pre-push" origin https://github.com/acme/q.git \
    <<<"refs/heads/main $(git rev-parse HEAD) refs/heads/main $ZERO"
  refused_with "other@else.example"
}

@test "write_guard never writes through a planted link" {
  setup_guard
  echo keep >"$HOME/target"
  /bin/rm -f "$(profile_dir office)/guard.rules"
  /bin/ln -s "$HOME/target" "$(profile_dir office)/guard.rules"
  write_guard 0 "$(profile_dir office)"
  [ "$(cat "$HOME/target")" = "keep" ]
  [ -f "$(profile_dir office)/guard.rules" ] && [ ! -L "$(profile_dir office)/guard.rules" ]
}

@test "the generated hook passes shellcheck as POSIX sh" {
  command -v shellcheck >/dev/null || skip "shellcheck is not installed"
  hook_script >"$HOME/hook.sh"
  run shellcheck --shell=sh --severity=style "$HOME/hook.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "launch --dry-run points Git at the profile's guard hooks" {
  need_app
  write_config "$GOOD"
  run main launch office --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"GIT_CONFIG_KEY_0=core.hooksPath"* ]]
  [[ $output == *"GIT_CONFIG_VALUE_0=$(profile_dir office)/hooks"* ]]
}

@test "a profile without rules still cannot commit another profile's repo" {
  write_config '{"version":1,"profiles":[
    {"name":"office","gitName":"Ada","gitEmail":"ada@work.example","folders":["~/work"],"owners":["acme"]},
    {"name":"personal","gitName":"Ada","gitEmail":"ada@home.example"}]}'
  load_config
  ensure_private_dir "$(base_dir)/profiles"
  ensure_private_dir "$(profile_dir office)" && write_guard 0 "$(profile_dir office)"
  ensure_private_dir "$(profile_dir personal)" && write_guard 1 "$(profile_dir personal)"
  new_repo "$HOME/work/app"
  run as_profile personal git -C "$HOME/work/app" commit -q -m test
  refused_with 'belongs to the "office" profile'
  new_repo "$HOME/stuff/acme-tool" "https://github.com/ACME/tool.git"
  run as_profile personal git -C "$HOME/stuff/acme-tool" commit -q -m test
  refused_with 'set for the "office" profile'
  new_repo "$HOME/stuff/mine" "https://github.com/me/mine.git"
  run as_profile personal git -C "$HOME/stuff/mine" commit -q -m test
  [ "$status" -eq 0 ]
}

# ------------------------------------------- security review: attack tests
# Each test repeats an attack from the security review and checks that
# it now fails. See docs/SECURITY_REVIEW.md.

@test "attack: a planted link at profiles.json.bak is never written through" {
  need_app
  write_config "$GOOD"
  echo "VICTIM" >"$HOME/victim.txt"
  /bin/ln -s "$HOME/victim.txt" "$(config_path).bak"
  run main setup <<<$'3\nsolo\nAda\na@b.co\n\n\nn\nn\n\n'
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/victim.txt")" = "VICTIM" ]
  [ -f "$(config_path).bak" ] && [ ! -L "$(config_path).bak" ]
}

@test "attack: a planted link inside a launcher is never written through" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  echo "VICTIM" >"$HOME/victim.txt"
  /bin/ln -sf "$HOME/victim.txt" "$(launcher_path office)/Contents/MacOS/launch"
  run main install
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/victim.txt")" = "VICTIM" ]
  [ ! -L "$(launcher_path office)/Contents/MacOS/launch" ]
}

@test "attack: a launcher folder replaced by a link is refused" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  /bin/mkdir -p "$HOME/elsewhere"
  /bin/mv "$(launcher_path office)/Contents/MacOS" "$HOME/elsewhere/MacOS"
  /bin/ln -s "$HOME/elsewhere/MacOS" "$(launcher_path office)/Contents/MacOS"
  local before
  before="$(cd "$HOME/elsewhere" && find . -type f -exec shasum {} + | sort)"
  run main install
  [ "$status" -eq 0 ]
  # The link is thrown away with the old app: nothing is written through it.
  [ ! -L "$(launcher_path office)/Contents/MacOS" ]
  [ "$before" = "$(cd "$HOME/elsewhere" && find . -type f -exec shasum {} + | sort)" ]
  launcher_signature_ok "$(launcher_path office)"
}

@test "attack: a remote URL with a newline cannot fool the owner check" {
  setup_guard
  new_repo "$HOME/work/nl"
  git -C "$HOME/work/nl" config remote.origin.url "$(printf 'https://github.com/acme\n/evilcorp/x')"
  run as_profile office git -C "$HOME/work/nl" commit -q -m test
  refused_with "unusual characters"
}

@test "attack: control characters in a folder name are not printed" {
  setup_guard
  local weird
  weird="$HOME/elsewhere/$(printf 'bad\033[31mname')"
  new_repo "$weird"
  run as_profile office git -C "$weird" commit -q -m test
  refused_with "outside the folders"
  [[ $output != *$'\033'* ]]
}

@test "import never copies cookies" {
  make_normal_data
  echo "session" >"$(normal_data_dir)/Cookies"
  echo "journal" >"$(normal_data_dir)/Cookies-journal"
  ensure_private_dir "$(base_dir)"
  copy_desktop_data "$(normal_data_dir)" "$HOME/copy"
  [ ! -e "$HOME/copy/Cookies" ] && [ ! -e "$HOME/copy/Cookies-journal" ]
  [ -f "$HOME/copy/Local Storage/leveldb/000003.log" ]
}

# ------------------------------------------------------- wizard guidance

@test "setup offers to add owners when a profile has no guard rules" {
  need_app
  run main setup <<<$'solo\nAda\na@b.co\n\n\ny\nacme, my-org\nn\n\n'
  [ "$status" -eq 0 ]
  [[ $output == *"can only check the email"* ]]
  load_config
  [ "$(printf '%s' "${P_OWNERS[0]}" | tr '\n' ' ')" = "acme my-org" ]
  grep -qx "owner=acme" "$(profile_dir solo)/guard.rules"
}

@test "setup summary says when a profile only checks the email" {
  need_app
  run main setup <<<$'solo\nAda\na@b.co\n\n\nn\nn\n\n'
  [ "$status" -eq 0 ]
  [[ $output == *"guard: email check only"* ]]
}

@test "setup explains the clean-up after copying the old repo list" {
  need_app
  make_normal_data
  run main setup <<<$'\npersonal\nAda\nada@example.org\n~/p\n\nn\n\n'
  [ "$status" -eq 0 ]
  [[ $output == *"WHOLE repo list is copied"* ]]
  [[ $output == *"One clean-up step"* ]]
  [[ $output == *"File > Add Local Repository"* ]]
}

# ------------------------------------------------- guard: review fixes

# A shared "GitHub" remote on disk, plus a teammate who pushes to it.
setup_remote_with_teammate() {
  REMOTE="$HOME/remote.git"
  GIT_CONFIG_GLOBAL=/dev/null git init -q --bare -b main "$REMOTE"
  GIT_CONFIG_GLOBAL=/dev/null git init -q -b main "$HOME/mate"
  git -C "$HOME/mate" remote add origin "$REMOTE"
  teammate_commit A
}

teammate_commit() {
  echo "$1" >"$HOME/mate/$1"
  git -C "$HOME/mate" add "$1"
  GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=Mate GIT_AUTHOR_EMAIL=mate@team.example \
    GIT_COMMITTER_NAME=Mate GIT_COMMITTER_EMAIL=mate@team.example git -C "$HOME/mate" commit -q -m "$1"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$HOME/mate" push -q origin main
}

@test "pre-push allows teammates' commits after merging main into your branch" {
  setup_guard
  setup_remote_with_teammate
  GIT_CONFIG_GLOBAL=/dev/null git clone -q "$REMOTE" "$HOME/work/app"
  cd "$HOME/work/app"
  git checkout -q -b feature
  echo f >f && git add f
  as_profile office git commit -q -m feature
  GIT_CONFIG_GLOBAL=/dev/null git push -q --no-verify origin feature
  local old_tip
  old_tip="$(git rev-parse HEAD)"
  teammate_commit B
  GIT_CONFIG_GLOBAL=/dev/null git fetch -q origin
  as_profile office git merge -q --no-edit origin/main
  run as_profile office "$(profile_dir office)/hooks/pre-push" origin "$REMOTE" \
    <<<"refs/heads/feature $(git rev-parse HEAD) refs/heads/feature $old_tip"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "pre-push fails closed when the remote tip is unknown (force-push)" {
  setup_guard
  new_repo "$HOME/work/fp" "https://github.com/acme/fp.git"
  as_profile office env GIT_COMMITTER_EMAIL=other@else.example git -C "$HOME/work/fp" commit -q --no-verify -m sneaky
  cd "$HOME/work/fp"
  run as_profile office "$(profile_dir office)/hooks/pre-push" origin https://github.com/acme/fp.git \
    <<<"refs/heads/main $(git rev-parse HEAD) refs/heads/main $(printf 'a%.0s' {1..40})"
  refused_with "other@else.example"
  run as_profile office "$(profile_dir office)/hooks/pre-push" origin https://github.com/acme/fp.git \
    <<<"refs/heads/main $(printf 'b%.0s' {1..40}) refs/heads/main $ZERO"
  refused_with "Could not list the commits"
}

@test "guard reads owners from SSH host aliases" {
  setup_guard
  new_repo "$HOME/work/alias" "work-github:EvilCorp/x.git"
  run as_profile office git -C "$HOME/work/alias" commit -q -m test
  refused_with 'belongs to "EvilCorp"'
}

@test "guard allows a local remote path with spaces" {
  setup_guard
  new_repo "$HOME/work/sp" "$HOME/My Backups/sp.git"
  run as_profile office git -C "$HOME/work/sp" commit -q -m test
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "guard refuses a remote whose owner cannot be read" {
  setup_guard
  new_repo "$HOME/work/odd" "https://github.com/ac_me/x.git"
  run as_profile office git -C "$HOME/work/odd" commit -q -m test
  refused_with "Could not read the GitHub owner"
  # A %-escape is stopped even earlier, as an unusual URL shape.
  git -C "$HOME/work/odd" remote set-url origin "https://github.com/ac%me/x.git"
  run as_profile office git -C "$HOME/work/odd" commit -q -m test
  refused_with "unusual shape"
}

@test "merge commits are guarded too" {
  setup_guard
  new_repo "$HOME/work/m"
  cd "$HOME/work/m"
  run as_profile personal "$(profile_dir personal)/hooks/pre-merge-commit"
  refused_with 'belongs to the "office" profile'
}

@test "guard rules of removed profiles are cleaned up, case-insensitively" {
  setup_guard
  write_config '{"version":1,"profiles":[{"name":"Office","gitName":"Ada","gitEmail":"ada@work.example"}]}'
  load_config
  remove_stale_guards
  [ ! -e "$(base_dir)/profiles/personal/guard.rules" ]
  [ -f "$(base_dir)/profiles/office/guard.rules" ]
}

@test "renaming a profile (my_work -> my-work) removes its old launcher" {
  need_app
  write_config '{"version":1,"profiles":[{"name":"my_work","gitName":"Ada","gitEmail":"a@b.co"}]}'
  main install >/dev/null
  [ -d "$(launcher_path my_work)" ]
  write_config '{"version":1,"profiles":[{"name":"my-work","gitName":"Ada","gitEmail":"a@b.co"}]}'
  run main install
  [ "$status" -eq 0 ]
  [ ! -e "$(launcher_path my_work)" ]
  [ -d "$(launcher_path my-work)" ]
}

@test "a folder planted where a hook goes is refused" {
  setup_guard
  /bin/rm -f "$(profile_dir office)/hooks/pre-commit"
  /bin/mkdir "$(profile_dir office)/hooks/pre-commit"
  run write_guard 0 "$(profile_dir office)"
  refused_with "is a folder"
}

@test "list flags a launcher whose script is missing" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  /bin/rm -f "$(launcher_path office)/Contents/MacOS/launch"
  run main list
  [[ $output == *"office"*"LAUNCHER UNSAFE"* ]]
}

@test "a failed copy leaves no profile data and no config behind" {
  need_app
  make_normal_data
  local f
  f="$(normal_data_dir)/Local Storage/leveldb/000009.ldb"
  echo data >"$f"
  /bin/chmod 000 "$f"
  run main setup <<<$'\npersonal\nAda\nada@example.org\n~/p\n\nn\n\n'
  /bin/chmod 600 "$f"
  refused_with "Copying your GitHub Desktop data failed"
  [ ! -e "$(data_dir personal)" ]
  [ ! -e "$(config_path)" ]
}

# ------------------------------------------- allow: one repo of another owner

# Two accounts, no folder rules, so only the owner check is in play.
setup_owner_guard() {
  write_config '{"version":1,"profiles":[
    {"name":"office","gitName":"Ada","gitEmail":"ada@work.example","owners":["Acme"]},
    {"name":"personal","gitName":"Ada","gitEmail":"ada@home.example","owners":["me"]}]}'
  load_config
  ensure_private_dir "$(base_dir)/profiles"
  local i=0 pd
  while [ "$i" -lt "${#P_NAMES[@]}" ]; do
    pd="$(profile_dir "${P_NAMES[$i]}")"
    ensure_private_dir "$pd"
    write_guard "$i" "$pd"
    i=$((i + 1))
  done
}

@test "valid_repo accepts owner/name and refuses everything else" {
  local ok bad
  # shellcheck disable=SC2016 # the $( ) below is text to refuse, not to run
  for ok in a/b Acme/tool my-org/my.repo_2 a/.github; do valid_repo "$ok" || { echo "should be valid: $ok"; return 1; }; done
  # shellcheck disable=SC2016 # same: text to refuse
  for bad in "" a /b a/ a/b/c "a b/c" a/b.git a/. a/.. -a/b "a/b;x" 'a/$(x)' 'a/b
c'; do
    if valid_repo "$bad"; then echo "should be refused: $bad"; return 1; fi
  done
}

@test "allow lets a profile use one repo of an owner it does not use" {
  setup_owner_guard
  new_repo "$HOME/stuff/tool" "https://github.com/ACME/tool.git"
  run as_profile personal git -C "$HOME/stuff/tool" commit -q -m test
  refused_with 'set for the "office" profile'
  refused_with 'mac/ghdp allow personal acme/tool'
  run cmd_allow personal "https://github.com/ACME/Tool.git"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'repo=acme/tool' "$(profile_dir personal)/guard.rules"
  run as_profile personal git -C "$HOME/stuff/tool" commit -q -m test
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "allow is exact: other repos of that owner stay protected" {
  setup_owner_guard
  cmd_allow personal acme/tool >/dev/null
  local url
  for url in "https://github.com/acme/tool-two.git" "https://github.com/acme/other" "https://github.com/acme/too" "https://github.com/acme-evil/tool"; do
    rm -rf "$HOME/stuff/x"
    new_repo "$HOME/stuff/x" "$url"
    run as_profile personal git -C "$HOME/stuff/x" commit -q -m test
    [ "$status" -ne 0 ] || { echo "should be refused: $url"; return 1; }
  done
}

@test "allow works for every kind of remote URL" {
  setup_owner_guard
  cmd_allow personal acme/tool >/dev/null
  local url
  for url in "git@github.com:Acme/Tool.git" "ssh://git@github.com/acme/tool" "work-github:ACME/tool.git" "https://user@github.com/acme/tool/"; do
    rm -rf "$HOME/stuff/x"
    new_repo "$HOME/stuff/x" "$url"
    run as_profile personal git -C "$HOME/stuff/x" commit -q -m test
    [ "$status" -eq 0 ] || { echo "should be allowed: $url"; echo "$output"; return 1; }
  done
}

@test "allow changes only that profile" {
  setup_owner_guard
  cmd_allow personal acme/tool >/dev/null
  run grep -q '^repo=' "$(profile_dir office)/guard.rules"
  [ "$status" -ne 0 ]
  grep -qx 'owner=acme' "$(profile_dir office)/guard.rules"
  # The allowed repo is still refused for the email check: wrong email stops it.
  new_repo "$HOME/stuff/tool" "https://github.com/acme/tool.git"
  run /usr/bin/env GIT_AUTHOR_EMAIL=other@x.example GIT_COMMITTER_EMAIL=other@x.example \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=A GIT_COMMITTER_NAME=A \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$(profile_dir personal)/hooks" \
    git -C "$HOME/stuff/tool" commit -q -m test
  refused_with "email"
}

@test "allow is saved in profiles.json, kept as a backup, and safe to repeat" {
  setup_owner_guard
  run cmd_allow personal Acme/Tool
  [ "$status" -eq 0 ]
  [ -f "$(config_path).bak" ]
  [ "$(stat -f %Lp "$(config_path)")" = "600" ]
  run cmd_allow personal acme/tool
  [ "$status" -eq 0 ]
  [[ $output == *"already"* ]]
  load_config
  [ "${P_REPOS[1]}" = "acme/tool" ]
  [ -z "${P_REPOS[0]}" ]
  # The other settings survive the rewrite.
  [ "${P_OWNERS[0]}" = "Acme" ] && [ "${P_GIT_EMAILS[1]}" = "ada@home.example" ]
}

@test "allow refuses unknown profiles, bad repos and too many repos" {
  setup_owner_guard
  run cmd_allow nobody acme/tool
  refused_with 'no profile called "nobody"'
  run cmd_allow personal acme
  refused_with "owner/name"
  run cmd_allow personal 'acme/tool;rm -rf ~'
  refused_with "owner/name"
  run cmd_allow personal
  refused_with "needs a profile name and a repo"
  local n
  for n in 1 2 3 4 5 6 7 8 9 10; do cmd_allow personal "acme/r$n" >/dev/null; done
  run cmd_allow personal acme/r11
  refused_with "limit"
}

@test "list shows allowed repos" {
  setup_owner_guard
  cmd_allow personal acme/tool >/dev/null
  run cmd_list
  [[ $output == *"allowed repos: acme/tool"* ]]
}

@test "a repo name in the hint is shown only when it is plain text" {
  setup_owner_guard
  # shellcheck disable=SC2016 # $IFS is part of the bad URL, not to be expanded
  new_repo "$HOME/stuff/x" 'https://github.com/acme/x;touch$IFS/tmp/pwned'
  run as_profile personal git -C "$HOME/stuff/x" commit -q -m test
  refused_with "mac/ghdp allow personal owner/repo"
  local hint
  hint="$(grep 'mac/ghdp allow' <<<"$output")"
  [[ $hint != *touch* ]]
}

# ------------------------------------------ add and remove a profile

# Answers for "add": name, commit name (default), email, folders, owners, confirm.
ADD_CROSSED=$'crashed\n\nnew@x.example\n\nnew-acct\n\n'

installed_good() {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  echo keep >"$(data_dir office)/marker"
  echo keep >"$(data_dir personal)/marker"
}

@test "double-clicking setup with profiles offers a menu, and adding is the default" {
  installed_good
  run main setup <<<$'\ncrashed\n\nnew@x.example\n\nnew-acct\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"You have 2 profile(s): office, personal."* ]]
  [[ $output == *"1) Add a profile"* ]]
  [[ $output != *"Name for profile 1"* ]]
  load_config
  [ "${P_NAMES[*]}" = "office personal crashed" ]
}

@test "add keeps your other profiles exactly as they were" {
  installed_good
  run main add <<<"$ADD_CROSSED"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  load_config
  [ "${P_NAMES[*]}" = "office personal crashed" ]
  [ "${P_GIT_NAMES[0]}" = "Ada Lovelace" ] && [ "${P_GIT_EMAILS[0]}" = "1+ada-work@users.noreply.github.com" ]
  [ "${P_GIT_NAMES[1]}" = "Ada L" ] && [ "${P_GIT_EMAILS[1]}" = "ada@example.org" ]
  [ "${P_GIT_NAMES[2]}" = "Ada L" ] && [ "${P_GIT_EMAILS[2]}" = "new@x.example" ]
  [ "${P_OWNERS[2]}" = "new-acct" ]
  [ "$(cat "$(config_path).bak")" = "$GOOD" ]
  [ "$(stat -f %Lp "$(config_path)")" = "600" ]
  [ "$(cat "$(data_dir office)/marker")" = "keep" ] && [ "$(cat "$(data_dir personal)/marker")" = "keep" ]
  [ -d "$(launcher_path crashed)" ] && [ -d "$(launcher_path office)" ] && [ -d "$(launcher_path personal)" ]
  grep -qx "owner=new-acct" "$(profile_dir crashed)/guard.rules"
  [[ $output == *'open "GitHub Desktop - crashed"'* ]]
  # Short output: nothing about the profiles that did not change.
  [[ $output != *"Ready: office"* ]] && [[ $output != *"Ready: personal"* ]]
}

@test "add keeps folders, owners and allowed repos of the others" {
  need_app
  write_config '{"version":1,"profiles":[
    {"name":"office","gitName":"Ada","gitEmail":"ada@work.example","folders":["~/work"],"owners":["Acme","acme-labs"]},
    {"name":"personal","gitName":"Ada","gitEmail":"ada@home.example","owners":["me"],"repos":["acme/tool"]}]}'
  main install >/dev/null
  run main add <<<"$ADD_CROSSED"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  load_config
  # shellcheck disable=SC2088 # "~/work" is the text kept in profiles.json
  [ "${P_FOLDERS[0]}" = "~/work" ]
  [ "$(printf '%s' "${P_OWNERS[0]}" | tr '\n' ' ')" = "Acme acme-labs" ]
  [ "${P_REPOS[1]}" = "acme/tool" ] && [ -z "${P_REPOS[0]}" ] && [ -z "${P_REPOS[2]}" ]
  grep -qx "repo=acme/tool" "$(profile_dir personal)/guard.rules"
}

@test "add can be run again and again" {
  installed_good
  main add <<<"$ADD_CROSSED" >/dev/null
  run main add <<<$'third\n\nthird@x.example\n\nthird-acct\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  load_config
  [ "${P_NAMES[*]}" = "office personal crashed third" ]
  [ -d "$(launcher_path third)" ]
}

@test "add asks again for a bad or used name, a bad name on commits and a bad email" {
  installed_good
  mkdir -p "$(data_dir leftover)"
  run main add <<<$'Office\nbad name!\nleftover\ncrashed\nA"B\nAda\nnope\nnew@x.example\n\nnew-acct\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"already have a profile with that name"* ]]
  [[ $output == *"That name is not allowed"* ]]
  [[ $output == *'A profile called "leftover" already has data on this Mac'* ]]
  [[ $output == *"Please type your name"* ]]
  [[ $output == *"does not look like an email"* ]]
  load_config
  [ "${P_NAMES[*]}" = "office personal crashed" ]
  [ "${P_GIT_NAMES[2]}" = "Ada" ]
}

@test "add: saying no at the end changes nothing" {
  installed_good
  run main add <<<$'crashed\n\nnew@x.example\n\nnew-acct\nn\n'
  [ "$status" -eq 0 ]
  [[ $output == *"Nothing changed"* ]]
  [ "$(cat "$(config_path)")" = "$GOOD" ]
  [ ! -e "$(launcher_path crashed)" ] && [ ! -e "$(data_dir crashed)" ]
}

@test "add: cancelling half way (end of input) changes nothing" {
  installed_good
  run main add <<<$'crashed\n'
  refused_with "cancelled"
  [ "$(cat "$(config_path)")" = "$GOOD" ]
  [ ! -e "$(launcher_path crashed)" ]
}

@test "add refuses at 20 profiles, with the next step" {
  need_app
  local json='{"version":1,"profiles":[' i sep=""
  for i in $(seq 1 20); do
    json="$json$sep{\"name\":\"p$i\",\"gitName\":\"Ada\",\"gitEmail\":\"p$i@x.example\"}"
    sep=","
  done
  write_config "$json]}"
  run main add <<<$'p21\n'
  refused_with "limit"
  refused_with "ghdp remove"
}

@test "add refuses without profiles or with a broken profiles.json, and never overwrites" {
  need_app
  run main add <<<$'x\n'
  refused_with "No profiles.json"
  write_config '{bad json'
  run main add <<<$'x\n'
  refused_with "not valid JSON"
  [ "$(cat "$(config_path)")" = '{bad json' ]
}

@test "setup menu: asks again on a wrong choice, and 4 refreshes without changes" {
  installed_good
  run main setup <<<$'x\n9\n4\n'
  [ "$status" -eq 0 ]
  [[ $output == *"Please type 1, 2, 3 or 4"* ]]
  [[ $output == *"Ready: personal"* ]]
  [ "$(cat "$(config_path)")" = "$GOOD" ]
}

@test "setup with a broken profiles.json explains it instead of showing the menu" {
  need_app
  write_config '{bad json'
  run main setup <<<$'n\n'
  refused_with "not valid JSON"
  [[ $output == *"has a problem"* ]]
  [[ $output != *"1) Add a profile"* ]]
  [ "$(cat "$(config_path)")" = '{bad json' ]
}

@test "remove takes a profile away and keeps its data" {
  installed_good
  run main remove personal <<<$'y\nn\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  load_config
  [ "${P_NAMES[*]}" = "office" ]
  [ "${P_GIT_EMAILS[0]}" = "1+ada-work@users.noreply.github.com" ]
  [ ! -e "$(launcher_path personal)" ] && [ -d "$(launcher_path office)" ]
  [ ! -e "$(profile_dir personal)/guard.rules" ]
  [ "$(cat "$(data_dir personal)/marker")" = "keep" ]
  [ "$(cat "$(data_dir office)/marker")" = "keep" ]
  [ "$(cat "$(config_path).bak")" = "$GOOD" ]
  [[ $output == *"Its data is still here"* ]]
}

@test "remove asks for the name when you give none, and is case-insensitive about nothing else" {
  installed_good
  run main remove <<<$'nobody\n'
  refused_with 'no profile called "nobody"'
  run main remove <<<$'personal\ny\nn\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  load_config
  [ "${P_NAMES[*]}" = "office" ]
}

@test "remove: saying no changes nothing" {
  installed_good
  run main remove personal <<<$'n\n'
  [ "$status" -eq 0 ]
  [[ $output == *"Nothing changed"* ]]
  [ "$(cat "$(config_path)")" = "$GOOD" ]
  [ -d "$(launcher_path personal)" ]
}

@test "remove moves the data to the Trash only when you say yes" {
  installed_good
  move_to_trash() { /bin/mkdir -p "$HOME/.Trash" && /bin/mv "$1" "$HOME/.Trash/"; }
  run main remove personal <<<$'y\ny\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$(profile_dir personal)" ]
  [ -f "$HOME/.Trash/personal/desktop-data/marker" ]
  [ -d "$(data_dir office)" ]
}

@test "remove does nothing while that profile's GitHub Desktop is still open" {
  installed_good
  /bin/mkdir -p "$(data_dir personal)/Local Storage/leveldb"
  : >"$(data_dir personal)/Local Storage/leveldb/LOCK"
  exec 8<"$(data_dir personal)/Local Storage/leveldb/LOCK"
  run main remove personal <<<$'y\ny\n'
  exec 8<&-
  refused_with "Nothing was changed"
  [ "$(cat "$(config_path)")" = "$GOOD" ]
  [ -d "$(launcher_path personal)" ] && [ -f "$(data_dir personal)/marker" ]
}

@test "remove refuses the last profile and unknown names" {
  need_app
  write_config '{"version":1,"profiles":[{"name":"solo","gitName":"Ada","gitEmail":"a@b.co"}]}'
  main install >/dev/null
  run main remove solo <<<$'y\n'
  refused_with "only profile"
  refused_with "uninstall-mac.command"
  write_config "$GOOD"
  run main remove ghost
  refused_with 'no profile called "ghost"'
  run main remove a b
  refused_with "one profile name"
}

@test "after remove, the guard no longer points to the removed profile" {
  need_app
  write_config '{"version":1,"profiles":[
    {"name":"office","gitName":"Ada","gitEmail":"ada@work.example","owners":["Acme"]},
    {"name":"personal","gitName":"Ada","gitEmail":"ada@home.example","owners":["me"]}]}'
  main install >/dev/null
  load_config
  new_repo "$HOME/stuff/x" "https://github.com/acme/x.git"
  run as_profile personal git -C "$HOME/stuff/x" commit -q -m test
  refused_with 'set for the "office" profile'
  main remove office <<<$'y\nn\n' >/dev/null
  run as_profile personal git -C "$HOME/stuff/x" commit -q -m test
  refused_with "which this profile does not use"
  [[ $output != *'"office" profile'* ]]
}

@test "setup menu option 2 removes a profile" {
  installed_good
  run main setup <<<$'2\npersonal\ny\nn\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  load_config
  [ "${P_NAMES[*]}" = "office" ]
}

@test "a removed profile's name needs a new name when added again (its old data is kept apart)" {
  installed_good
  main remove personal <<<$'y\nn\n' >/dev/null
  run main add <<<$'personal\nagain\n\nagain@x.example\n\nagain-acct\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *'A profile called "personal" already has data'* ]]
  load_config
  [ "${P_NAMES[*]}" = "office again" ]
}

# --- add and remove: more cases

@test "removing the middle profile keeps every other profile's own settings in line" {
  need_app
  write_config '{"version":1,"profiles":[
    {"name":"one","gitName":"A One","gitEmail":"one@x.example","folders":["~/one"],"owners":["own-one"]},
    {"name":"two","gitName":"A Two","gitEmail":"two@x.example","owners":["own-two"],"repos":["own-one/shared"]},
    {"name":"three","gitName":"A Three","gitEmail":"three@x.example","folders":["~/three"],"repos":["own-two/tool"]}]}'
  main install >/dev/null
  run main remove two <<<$'y\nn\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  load_config
  [ "${P_NAMES[*]}" = "one three" ]
  [ "${P_GIT_NAMES[0]}" = "A One" ] && [ "${P_GIT_EMAILS[0]}" = "one@x.example" ]
  [ "${P_GIT_NAMES[1]}" = "A Three" ] && [ "${P_GIT_EMAILS[1]}" = "three@x.example" ]
  # shellcheck disable=SC2088 # text kept in profiles.json
  [ "${P_FOLDERS[0]}" = "~/one" ] && [ "${P_FOLDERS[1]}" = "~/three" ]
  [ "${P_OWNERS[0]}" = "own-one" ] && [ -z "${P_OWNERS[1]}" ]
  [ -z "${P_REPOS[0]}" ] && [ "${P_REPOS[1]}" = "own-two/tool" ]
  grep -qx "repo=own-two/tool" "$(profile_dir three)/guard.rules"
  run grep -q "own-one/shared" "$(profile_dir three)/guard.rules"
  [ "$status" -ne 0 ]
}

@test "removing the first and then the last profile works too" {
  installed_good
  main add <<<"$ADD_CROSSED" >/dev/null
  run main remove office <<<$'y\nn\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run main remove crashed <<<$'y\nn\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  load_config
  [ "${P_NAMES[*]}" = "personal" ] && [ "${P_GIT_EMAILS[0]}" = "ada@example.org" ]
  [ -d "$(launcher_path personal)" ] && [ ! -e "$(launcher_path office)" ] && [ ! -e "$(launcher_path crashed)" ]
}

@test "add without folders or owners nudges for owners, and you can skip it" {
  installed_good
  run main add <<<$'solo\n\nsolo@x.example\n\n\ny\nacme\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"can only check the email"* ]]
  load_config
  [ "${P_OWNERS[2]}" = "acme" ]
  run main add <<<$'lone\n\nlone@x.example\n\n\nn\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"New profile: lone"* ]]
  load_config
  [ "${P_NAMES[*]}" = "office personal solo lone" ] && [ -z "${P_OWNERS[3]}" ]
}

@test "add and remove stop when GitHub Desktop is missing" {
  installed_good
  find_app() { return 1; }
  run main add <<<"$ADD_CROSSED"
  refused_with "GitHub Desktop is not installed"
  [ "$(cat "$(config_path)")" = "$GOOD" ]
}

@test "attack: a planted link at profiles.json.bak is not written through when adding" {
  installed_good
  echo VICTIM >"$HOME/victim.txt"
  /bin/rm -f "$(config_path).bak"
  /bin/ln -s "$HOME/victim.txt" "$(config_path).bak"
  run main add <<<"$ADD_CROSSED"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$HOME/victim.txt")" = "VICTIM" ]
  [ -f "$(config_path).bak" ] && [ ! -L "$(config_path).bak" ]
}

@test "attack: a linked profile folder is never deleted or followed by remove" {
  installed_good
  /bin/mkdir -p "$HOME/elsewhere"
  echo keep >"$HOME/elsewhere/guard.rules"
  echo keep >"$HOME/elsewhere/data.txt"
  /bin/rm -rf "$(profile_dir personal)"
  /bin/ln -s "$HOME/elsewhere" "$(profile_dir personal)"
  main remove personal <<<$'y\ny\n' >/dev/null 2>&1 || true
  [ "$(cat "$HOME/elsewhere/guard.rules")" = "keep" ]
  [ "$(cat "$HOME/elsewhere/data.txt")" = "keep" ]
}

# --- independent review: URL tricks, half-finished installs, changed config

# Run the generated pre-push hook of a profile for one remote URL.
push_check() {
  run as_profile "$1" sh "$(profile_dir "$1")/hooks/pre-push" origin "$2" </dev/null
}

@test "attack: URL tricks cannot make the guard read a different owner than Git contacts" {
  setup_owner_guard
  cmd_allow personal acme/tool >/dev/null
  load_config
  local url
  # shellcheck disable=SC2016 # no expansion wanted in these URLs
  for url in \
    "https://github.com/me/x/../../acme/secret" \
    "https://github.com/acme/tool/../../acme/secret" \
    "https://github.com/me/x/./y" \
    "https://github.com/me/x%2f..%2facme/secret" \
    "https://github.com/me/x?y=1" \
    "https://github.com/me/x#y" \
    "https://github.com/me/x y" \
    'https://github.com/me/x\y' \
    "https://github.com/me/éx" \
    "work-github:../acme/secret"; do
    push_check personal "$url"
    [ "$status" -ne 0 ] || { echo "should be refused: $url"; return 1; }
  done
}

@test "an allowed repo means exactly owner/name, nothing longer or similar" {
  setup_owner_guard
  cmd_allow personal acme/tool >/dev/null
  load_config
  local url
  for url in "https://github.com/acme/tool.git/extra" "https://github.com/acme/tool/more/x" \
    "https://github.com/acme/tool-two" "https://github.com/acme/too" "https://github.com/acme/other"; do
    push_check personal "$url"
    [ "$status" -ne 0 ] || { echo "should be refused: $url"; return 1; }
  done
}

@test "normal remotes still pass the shape check" {
  setup_owner_guard
  cmd_allow personal acme/tool >/dev/null
  load_config
  local url
  for url in "https://github.com/me/x" "https://github.com/ME/X.git/" "https://user:p%40ss@github.com/me/x" \
    "git@github.com:me/x.git" "ssh://git@github.com/me/x" "https://github.com/acme/tool.git" \
    "$HOME/My Backups/x.git" "file:///tmp/some where/x.git"; do
    push_check personal "$url"
    [ "$status" -eq 0 ] || { echo "should be allowed: $url"; echo "$output"; return 1; }
  done
}

@test "the guard's lowercase step does not depend on the user's language settings" {
  grep -q "LC_ALL=C tr '\[:upper:\]' '\[:lower:\]'" <(hook_script)
}

@test "add stops with a clear hint if the launchers cannot be finished, and cleans up" {
  installed_good
  # shellcheck disable=SC2329 # called by the tool, not by this test
  make_launcher() { die "Pretend problem." "Fix it."; }
  run main add <<<"$ADD_CROSSED"
  refused_with "profiles.json was already updated"
  refused_with "ghdp install"
  load_config
  [ "${P_NAMES[*]}" = "office personal crashed" ]
}

@test "remove cleans the removed profile's guard rules even if installing fails afterwards" {
  installed_good
  # shellcheck disable=SC2329 # called by the tool, not by this test
  make_launcher() { die "Pretend problem." "Fix it."; }
  run main remove personal <<<$'y\nn\n'
  refused_with "profiles.json was already updated"
  [ ! -e "$(profile_dir personal)/guard.rules" ]
  [ -f "$(data_dir personal)/marker" ]
}

@test "add and remove do not overwrite a profiles.json that changed while you answered" {
  installed_good
  # shellcheck disable=SC2329 # called by the tool, not by this test
  ask_email() { cmd_allow personal acme/tool >/dev/null; printf '%s' new@x.example; }
  run main add <<<$'crashed\n\n\nnew-acct\n\n'
  refused_with "changed while you were answering"
  load_config
  [ "${P_NAMES[*]}" = "office personal" ]
  [ "${P_REPOS[1]}" = "acme/tool" ]
  unset -f ask_email
  # shellcheck disable=SC2329 # called by the tool, not by this test
  ask_yes() { cmd_allow office acme/tool2 >/dev/null; return 0; }
  run main remove personal
  refused_with "changed while you were answering"
  load_config
  [ "${P_NAMES[*]}" = "office personal" ] && [ "${P_REPOS[0]}" = "acme/tool2" ]
}

# --- quick first-time setup and "open it now"

write_global_git() { printf '[user]\n\tname = %s\n\temail = %s\n' "$1" "$2" >"$HOME/.gitconfig"; }

@test "owner_from_email reads the GitHub username out of a noreply email only" {
  [ "$(owner_from_email "12345+ada-l@users.noreply.github.com")" = "ada-l" ]
  [ "$(owner_from_email "ada-l@users.noreply.github.com")" = "ada-l" ]
  [ "$(owner_from_email "9+Ada@users.noreply.github.com")" = "Ada" ]
  [ -z "$(owner_from_email "ada@example.org")" ]
  [ -z "$(owner_from_email "1+x@users.noreply.github.com.evil.example")" ]
  [ -z "$(owner_from_email "1+-bad@users.noreply.github.com")" ]
  [ -z "$(owner_from_email "")" ]
}

@test "quick setup: you confirm the account, then one Return makes a profile named after it" {
  need_app
  make_normal_data
  write_global_git "Ada L" "12345+ada-l@users.noreply.github.com"
  run main setup <<<$'\ny\n\nn\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"Settings > Accounts"* ]] || false
  [[ $output == *"Your Git email 12345+ada-l@users.noreply.github.com belongs to the GitHub account \"ada-l\"."* ]] || false
  [[ $output == *"Quick setup"* ]] || false
  [[ $output == *"account:  ada-l"* ]] || false
  [[ $output != *"Name for profile 1"* ]] || false
  load_config
  # Named after the GitHub account, not a guessed "personal".
  [ "${P_NAMES[*]}" = "ada-l" ]
  [ "${P_GIT_NAMES[0]}" = "Ada L" ] && [ "${P_GIT_EMAILS[0]}" = "12345+ada-l@users.noreply.github.com" ] || false
  [ "${P_OWNERS[0]}" = "ada-l" ] && [ -z "${P_FOLDERS[0]}" ] || false
  [ -f "$(data_dir ada-l)/Local Storage/leveldb/000003.log" ]
  [ -d "$(launcher_path ada-l)" ]
  grep -qx "owner=ada-l" "$(profile_dir ada-l)/guard.rules"
}

@test "quick setup never assumes the account: Return alone is not an answer" {
  need_app
  make_normal_data
  write_global_git "Ada L" "12345+ada-l@users.noreply.github.com"
  run main setup <<<$'\n\ny\n\nn\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"Please type y or n."* ]] || false
  load_config
  [ "${P_NAMES[*]}" = "ada-l" ]
}

@test "quick setup: GitHub Desktop signed in to another account never gets your Git email" {
  # GitHub Desktop is signed in to a work account, but the Git email is the
  # personal account's noreply email. The copied profile must not take it.
  need_app
  make_normal_data
  write_global_git "Ada L" "12345+ada-l@users.noreply.github.com"
  run main setup <<<$'\nn\nwork\n\n\nada@work.example\n\n\nn\n\npersonal\n\n\n\n\nn\n\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output != *"Quick setup"* ]] || false
  [[ $output == *"That does not look like an email address."* ]] || false
  load_config
  [ "${P_NAMES[*]}" = "work personal" ]
  [ "${P_GIT_EMAILS[0]}" = "ada@work.example" ]
  # The Git email is offered for the next profile instead.
  [ "${P_GIT_EMAILS[1]}" = "12345+ada-l@users.noreply.github.com" ]
  [ -f "$(data_dir work)/Local Storage/leveldb/000003.log" ]
  [ ! -e "$(data_dir personal)/Local Storage/leveldb/000003.log" ]
}

@test "quick setup: saying no to the summary lets you choose every answer yourself" {
  need_app
  make_normal_data
  write_global_git "Ada L" "12345+ada-l@users.noreply.github.com"
  run main setup <<<$'\ny\nn\nmine\n\n\n\n\nn\nn\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"Quick setup"* ]] || false
  load_config
  [ "${P_NAMES[*]}" = "mine" ]
  [ "${P_GIT_EMAILS[0]}" = "12345+ada-l@users.noreply.github.com" ]
  [ -z "${P_OWNERS[0]}" ]
}

@test "quick setup is skipped without a noreply email, a usable name, or when the profile already has data" {
  need_app
  make_normal_data
  write_global_git "Ada L" "ada@example.org"
  run main setup <<<$'\npersonal\n\n\n\n\nn\nn\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output != *"Quick setup"* ]] && [[ $output != *"belongs to the GitHub account"* ]] || false
  # The copy question still says where to see the account.
  [[ $output == *"To see which GitHub account it uses: open GitHub Desktop > Settings > Accounts."* ]] || false
  load_config
  [ "${P_NAMES[*]}" = "personal" ] && [ "${P_GIT_EMAILS[0]}" = "ada@example.org" ] && [ -z "${P_OWNERS[0]}" ] || false
  # The account is still checked (y here), only the quick summary is skipped.
  /bin/rm -rf "$(base_dir)"
  write_global_git "Ada L" "12345+ada-l@users.noreply.github.com"
  mkdir -p "$(data_dir ada-l)"
  run main setup <<<$'\ny\nother\n\n\n\n\nn\nn\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output != *"Quick setup"* ]] || false
  load_config
  [ "${P_NAMES[*]}" = "other" ] && [ "${P_GIT_EMAILS[0]}" = "12345+ada-l@users.noreply.github.com" ] || false
  # A GitHub username too long for a profile name (33+ letters).
  /bin/rm -rf "$(base_dir)"
  write_global_git "Ada L" "12345+$(printf 'a%.0s' {1..33})@users.noreply.github.com"
  run main setup <<<$'\ny\nlong\n\n\n\n\nn\nn\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output != *"Quick setup"* ]] || false
  load_config
  [ "${P_NAMES[*]}" = "long" ]
}

@test "the account check runs even when quick setup cannot, and a no keeps your Git email off the copy" {
  need_app
  make_normal_data
  write_global_git "Ada L" "12345+ada-l@users.noreply.github.com"
  mkdir -p "$(data_dir ada-l)"
  run main setup <<<$'\nn\nwork\n\n\nada@work.example\n\n\nn\nn\n\n'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"belongs to the GitHub account \"ada-l\""* ]] || false
  [[ $output == *"That does not look like an email address."* ]] || false
  load_config
  [ "${P_NAMES[*]}" = "work" ] && [ "${P_GIT_EMAILS[0]}" = "ada@work.example" ] || false
}

@test "after_setup offers to open the profile, then shows the launchers in Finder" {
  # shellcheck disable=SC2329 # called by after_setup, not by this test
  cmd_launch() { echo "launch $1" >>"$HOME/steps"; }
  # shellcheck disable=SC2329 # called by after_setup, not by this test
  reveal_launchers() { echo "reveal $1" >>"$HOME/steps"; }
  run after_setup personal <<<$'\n'
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/steps")" = $'launch personal\nreveal personal' ]
  /bin/rm -f "$HOME/steps"
  run after_setup personal <<<$'n\n'
  [ "$status" -eq 0 ] && [ "$(cat "$HOME/steps")" = "reveal personal" ] || false
}

@test "open_after launches the profile on yes and does nothing on no" {
  # shellcheck disable=SC2329 # called by open_after, not by this test
  cmd_launch() { echo "$1" >"$HOME/launched"; }
  run open_after personal <<<$'\n'
  [ "$status" -eq 0 ] && [ "$(cat "$HOME/launched")" = "personal" ] || false
  /bin/rm -f "$HOME/launched"
  run open_after personal <<<$'n\n'
  [ "$status" -eq 0 ] && [ ! -e "$HOME/launched" ] || false
}

@test "offer_open asks nobody and opens nothing when no person is typing (scripts, tests)" {
  # shellcheck disable=SC2329 # called by offer_open, not by this test
  cmd_launch() { echo "$1" >"$HOME/launched"; }
  # shellcheck disable=SC2329 # called by offer_open, not by this test
  reveal_launchers() { echo "$1" >"$HOME/revealed"; }
  run offer_open personal <<<$'\n'
  [ "$status" -eq 0 ] && [ ! -e "$HOME/launched" ] && [ ! -e "$HOME/revealed" ] || false
}

# --- a profile's app: the Dock icon you pin IS the app that runs

app_setup() {
  need_app
  write_config "$GOOD"
  load_config
  APP="$(verified_app)"
  L="$(launcher_path office)"
  ensure_private_dir "$(base_dir)/bin"
  install_self
}

@test "the profile app is a signed clone of GitHub Desktop with its own id, name, icon and start file" {
  app_setup
  make_launcher office "$APP" 0
  launcher_signature_ok "$L"
  launcher_fresh office "$APP" 0
  [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$L/Contents/Info.plist")" = "io.github.gh-desktop-profiles.office" ]
  [ "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$L/Contents/Info.plist")" = "launch" ]
  [ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$L/Contents/Info.plist")" = "GitHub Desktop - office" ]
  # GitHub's own icon name would override our badge icon, so it is removed.
  run /usr/bin/plutil -extract CFBundleIconName raw -o - "$L/Contents/Info.plist"
  [ "$status" -ne 0 ]
  [ "$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$L/Contents/Info.plist")" = "AppIcon" ]
  # Not hidden from the Dock: no LSUIElement.
  run /usr/bin/plutil -extract LSUIElement raw -o - "$L/Contents/Info.plist"
  [ "$status" -ne 0 ]
  # Same program as the original (only the signature stored in the file differs).
  [ -x "$L/Contents/MacOS/GitHub Desktop" ]
  [ "$(/usr/bin/file -b "$L/Contents/MacOS/GitHub Desktop")" = "$(/usr/bin/file -b "$APP/Contents/MacOS/GitHub Desktop")" ]
  [ "$(stat -f %Sp "$L/Contents/MacOS/launch")" = "-rwx------" ]
}

@test "making the profile app never changes the real GitHub Desktop" {
  app_setup
  make_launcher office "$APP" 0
  app_signature_ok "$APP"
  [ ! -e "$APP/Icon"$'\r' ]
  [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = "com.github.GitHubClient" ]
}

@test "a current profile app is kept, and a changed one is made again" {
  app_setup
  make_launcher office "$APP" 0
  echo marker >"$L/Contents/Resources/marker"
  # An added file breaks the seal, so it is made again (and the marker goes).
  run launcher_signature_ok "$L"
  [ "$status" -ne 0 ]
  make_launcher office "$APP" 0
  [ ! -e "$L/Contents/Resources/marker" ]
  launcher_fresh office "$APP" 0
  # A clean app is left alone.
  /usr/bin/touch -t 202001010000 "$L/Contents/Info.plist"
  make_launcher office "$APP" 0
  [ "$(stat -f %Sm -t %Y "$L/Contents/Info.plist")" = "2020" ]
}

@test "a profile app of an older GitHub Desktop is made again" {
  app_setup
  make_launcher office "$APP" 0
  echo x >"$L/Contents/Resources/marker"
  app_version() { case $1 in "$APP") printf 'new' ;; *) printf 'old' ;; esac; }
  run launcher_fresh office "$APP" 0
  [ "$status" -ne 0 ]
}

@test "the icon letter and color are remembered, and a changed start file is noticed" {
  app_setup
  make_launcher office "$APP" 0
  [ "$(/usr/bin/plutil -extract GHDPIconKey raw -o - "$L/Contents/Info.plist")" = "O-37,99,235" ]
  # Same profile in another list position: another color, so made again.
  run launcher_fresh office "$APP" 1
  [ "$status" -ne 0 ]
  # A start file that does something else is never trusted.
  /bin/chmod 700 "$L/Contents/MacOS/launch"
  printf '#!/bin/bash\necho evil\n' >"$L/Contents/MacOS/launch"
  run launcher_fresh office "$APP" 0
  [ "$status" -ne 0 ]
}

@test "attack: a fake app in the profile app's place is replaced, and a link is refused" {
  app_setup
  mkdir -p "$L/Contents/MacOS"
  printf '#!/bin/sh\necho fake\n' >"$L/Contents/MacOS/GitHub Desktop"
  /usr/bin/plutil -create xml1 "$L/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "io.github.gh-desktop-profiles.office" "$L/Contents/Info.plist"
  make_launcher office "$APP" 0
  launcher_fresh office "$APP" 0
  [ "$(head -c 2 "$L/Contents/MacOS/GitHub Desktop")" != "#!" ] # the fake script is gone
  # A link in the app's place is never followed.
  /bin/rm -rf "$L"
  /bin/ln -s "$APP" "$L"
  run make_launcher office "$APP" 0
  refused_with "was not made by this tool"
  app_signature_ok "$APP"
}

@test "the profile app is refused when Applications can be changed by other people" {
  app_setup
  mkdir -p "$HOME/Applications"
  /bin/chmod 777 "$HOME/Applications"
  run make_launcher office "$APP" 0
  /bin/chmod 755 "$HOME/Applications"
  refused_with "can be changed by other users"
  [ ! -e "$L" ]
}

@test "a failed build leaves no half-made app and no build folder behind" {
  app_setup
  # shellcheck disable=SC2329 # called by make_launcher
  patch_info_plist() { return 1; }
  run make_launcher office "$APP" 0
  refused_with "Could not finish the app"
  [ ! -e "$L" ]
  local leftover=("$HOME/Applications"/.ghdp-build.*)
  [ ! -e "${leftover[0]}" ]
}

@test "the old hidden private copies are removed on install and uninstall, links never followed" {
  need_app
  write_config "$GOOD"
  main install >/dev/null
  mkdir -p "$HOME/elsewhere" "$HOME/Applications/.gh-desktop-profiles/office"
  echo keep >"$HOME/elsewhere/data.txt"
  /bin/ln -s "$HOME/elsewhere" "$HOME/Applications/.gh-desktop-profiles/ghost"
  main install >/dev/null
  [ ! -e "$HOME/Applications/.gh-desktop-profiles" ]
  [ "$(cat "$HOME/elsewhere/data.txt")" = "keep" ]
  mkdir -p "$HOME/Applications/.gh-desktop-profiles/office"
  main uninstall <<<$'y\nn\n' >/dev/null
  [ ! -e "$HOME/Applications/.gh-desktop-profiles" ]
}

@test "attack: a linked old-copies folder is never followed" {
  need_app
  write_config "$GOOD"
  mkdir -p "$HOME/elsewhere" "$HOME/Applications"
  echo keep >"$HOME/elsewhere/data.txt"
  /bin/ln -s "$HOME/elsewhere" "$HOME/Applications/.gh-desktop-profiles"
  main install >/dev/null
  [ "$(cat "$HOME/elsewhere/data.txt")" = "keep" ]
}

# --- launching: the app you click is the app that runs

@test "launch (default) names the profile app's own program and the fixed settings" {
  need_app
  write_config "$GOOD"
  run main launch office --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"$(launcher_path office)/Contents/MacOS/GitHub Desktop"* ]]
  [[ $output == *"--user-data-dir=$(data_dir office)"* ]]
  [[ $output == *"GIT_AUTHOR_EMAIL=1+ada-work@users.noreply.github.com"* ]]
  [ ! -e "$(launcher_path office)" ]
}

@test "launch --plain opens the normal GitHub Desktop and --own-icon is still accepted" {
  need_app
  write_config "$GOOD"
  run main launch office --plain --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"/Applications/GitHub Desktop.app"* ]]
  [[ $output == *"--env=GHDP_PROFILE=office"* ]]
  run main launch office --own-icon --dry-run
  [ "$status" -eq 0 ]
}

@test "each profile app only ever gets its own profile's identity and data folder" {
  need_app
  write_config "$GOOD"
  local o p
  o="$(main launch office --dry-run)"
  p="$(main launch personal --dry-run)"
  [[ $o == *"GIT_AUTHOR_EMAIL=1+ada-work@users.noreply.github.com"* ]]
  [[ $o != *"ada@example.org"* ]]
  [[ $o != *"desktop-data"*"personal"* ]]
  [[ $p == *"GIT_AUTHOR_EMAIL=ada@example.org"* ]]
  [[ $p != *"ada-work"* ]]
  [[ $p == *"--user-data-dir=$(data_dir personal)"* ]]
}
