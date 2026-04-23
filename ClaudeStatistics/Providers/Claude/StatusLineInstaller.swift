import Foundation

/// Manages installation of the Claude Statistics-integrated status line script
struct StatusLineInstaller {
    private static let managedRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-statistics")
    private static let managedBinDirectory = (managedRoot as NSString).appendingPathComponent("bin")
    static let scriptPath = (managedBinDirectory as NSString).appendingPathComponent("claude-stats-statusline")
    static let backupPath = (managedBinDirectory as NSString).appendingPathComponent("claude-stats-statusline.bak")
    private static let legacyScriptPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusline-command.sh")
    private static let legacyBackupPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusline-command.sh.bak")
    static let marker = "# Claude Statistics Integration v3"
    private static let markerPrefix = "# Claude Statistics Integration"
    static let settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    static let settingsBackupPath = (managedRoot as NSString).appendingPathComponent("statusline-settings.bak.json")
    private static let legacySettingsBackupPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusline-settings.bak.json")
    private static let expectedCommand = "bash ~/.claude-statistics/bin/claude-stats-statusline"
    private static let legacyExpectedCommand = "bash ~/.claude/statusline-command.sh"

    /// Check if our integrated script is currently installed and settings.json is synced
    static var isInstalled: Bool {
        if scriptContainsMarker(at: scriptPath), isSettingsSynced(with: expectedCommands) {
            return true
        }

        // Treat the old ~/.claude install as installed so app startup can migrate it.
        return scriptContainsMarker(at: legacyScriptPath) && isSettingsSynced(with: legacyExpectedCommands)
    }

    /// Check if settings.json statusLine points to our script
    private static func isSettingsSynced(with commands: Set<String>) -> Bool {
        guard let settings = readSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return commands.contains(command)
    }

    /// Check if a backup exists
    static var hasBackup: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: backupPath) || fm.fileExists(atPath: legacyBackupPath)
    }

    /// Install the integrated status line script
    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: managedBinDirectory, withIntermediateDirectories: true)

        try backupScriptIfNeeded(at: scriptPath, to: backupPath)

        // Write new script
        try generatedScript().write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // Make executable
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        try removeLegacyManagedScriptIfNeeded()

        // Sync settings.json to point statusLine to our script
        try syncSettingsOnInstall()
    }

    /// Restore the backup script
    static func restore() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: backupPath) {
            try restoreBackup(from: backupPath, to: scriptPath)
        } else if fm.fileExists(atPath: legacyBackupPath) {
            if scriptContainsMarker(at: scriptPath) {
                try? fm.removeItem(atPath: scriptPath)
            }
            try restoreBackup(from: legacyBackupPath, to: legacyScriptPath)
        } else {
            throw StatusLineError.noBackup
        }

        // Restore original statusLine config in settings.json
        try syncSettingsOnRestore()
    }

    enum StatusLineError: LocalizedError {
        case noBackup
        var errorDescription: String? { "No backup file found" }
    }

    private static var expectedCommands: Set<String> {
        [expectedCommand, "bash \(scriptPath)"]
    }

    private static var legacyExpectedCommands: Set<String> {
        [legacyExpectedCommand, "bash \(legacyScriptPath)"]
    }

    private static func scriptContainsMarker(at path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return content.contains(markerPrefix)
    }

    private static func backupScriptIfNeeded(at path: String, to backupPath: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        let current = try String(contentsOfFile: path, encoding: .utf8)
        guard !current.contains(markerPrefix) else { return }

        if fm.fileExists(atPath: backupPath) {
            try fm.removeItem(atPath: backupPath)
        }
        try fm.copyItem(atPath: path, toPath: backupPath)
    }

    private static func removeLegacyManagedScriptIfNeeded() throws {
        let fm = FileManager.default
        guard scriptContainsMarker(at: legacyScriptPath) else { return }
        try fm.removeItem(atPath: legacyScriptPath)
    }

    private static func restoreBackup(from backupPath: String, to destinationPath: String) throws {
        let fm = FileManager.default
        let parentDirectory = (destinationPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parentDirectory, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destinationPath) {
            try fm.removeItem(atPath: destinationPath)
        }
        try fm.copyItem(atPath: backupPath, toPath: destinationPath)
        try fm.removeItem(atPath: backupPath)
    }

    // MARK: - Settings.json sync

    private static func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private static func syncSettingsOnInstall() throws {
        var settings = readSettings() ?? [:]
        let fm = FileManager.default
        try fm.createDirectory(atPath: managedRoot, withIntermediateDirectories: true)

        // Backup current statusLine config on first install only
        if !fm.fileExists(atPath: settingsBackupPath),
           !fm.fileExists(atPath: legacySettingsBackupPath),
           let current = settings["statusLine"] {
            let backupData = try JSONSerialization.data(withJSONObject: current, options: .prettyPrinted)
            try backupData.write(to: URL(fileURLWithPath: settingsBackupPath), options: .atomic)
        }

        settings["statusLine"] = [
            "type": "command",
            "command": expectedCommand
        ]

        try writeSettings(settings)
    }

    private static func syncSettingsOnRestore() throws {
        var settings = readSettings() ?? [:]
        let fm = FileManager.default

        let backupPath = fm.fileExists(atPath: settingsBackupPath) ? settingsBackupPath : legacySettingsBackupPath
        if fm.fileExists(atPath: backupPath),
           let data = fm.contents(atPath: backupPath),
           let oldConfig = try? JSONSerialization.jsonObject(with: data) {
            settings["statusLine"] = oldConfig
            try fm.removeItem(atPath: backupPath)
        } else {
            settings.removeValue(forKey: "statusLine")
        }

        try writeSettings(settings)
    }

    // MARK: - Script generation

    private static func generatedScript() -> String {
        let pricingPath = "~/.claude-statistics/pricing.json"
        let usageCachePath = "~/.claude-statistics/usage-cache.json"

        return """
        #!/usr/bin/env bash
        \(marker)
        # Two-line status bar based on oh-my-zsh "ys" theme
        # Icons: auto-detects Nerd Font, falls back to plain text
        # Receives Claude Code JSON on stdin
        #
        # Cost: uses pricing from Claude Statistics app (\(pricingPath))
        # Usage: reads from Claude Statistics app cache (\(usageCachePath))

        input=$(cat)

        # ---------------------------------------------------------------------------
        # Extract Claude Code context
        # ---------------------------------------------------------------------------
        cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
        model=$(echo "$input" | jq -r '.model.display_name // empty')
        used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
        session_name=$(echo "$input" | jq -r '.session_name // empty')

        # Worktree info
        wt_name=$(echo "$input" | jq -r '.worktree.name // empty')
        wt_branch=$(echo "$input" | jq -r '.worktree.branch // empty')

        # Context window size
        ctx_window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')

        # Transcript path for cumulative stats
        transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
        model_id=$(echo "$input" | jq -r '.model.id // empty')

        # ---------------------------------------------------------------------------
        # Parse transcript JSONL for cumulative token usage & cost
        # Uses pricing from Claude Statistics app for accurate per-model costs
        # Includes subagent transcripts; incremental parse via per-file size cache
        # Debug: export CLAUDE_STATUSLINE_DEBUG=1 to see parse stats on stderr
        # ---------------------------------------------------------------------------
        TRANSCRIPT_CACHE_DIR="$HOME/.claude-statistics/statusline-cache"
        mkdir -p "$TRANSCRIPT_CACHE_DIR" 2>/dev/null

        total_input_tokens=0
        total_output_tokens=0
        cache_creation_tokens=0
        cache_read_tokens=0
        total_cost="0.00"

        PRICING_FILE="$HOME/.claude-statistics/pricing.json"

        # Portable file size: macOS -f%z / Linux -c%s
        _stat_size() {
          stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
        }

        if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
          cache_key=$(echo "$transcript_path" | md5 -q 2>/dev/null || echo "$transcript_path" | md5sum 2>/dev/null | cut -d' ' -f1)
          # _v2 cache: per-file sizes + totals; supports incremental parse + subagents
          tcache="$TRANSCRIPT_CACHE_DIR/${cache_key}_v2.json"

          # Subagent transcripts live at <transcript_dir>/<session_id>/subagents/*.jsonl
          _tp_dir=$(dirname "$transcript_path")
          _tp_base=$(basename "$transcript_path" .jsonl)
          subagent_dir="$_tp_dir/$_tp_base/subagents"

          all_files=("$transcript_path")
          if [ -d "$subagent_dir" ]; then
            for _f in "$subagent_dir"/*.jsonl; do
              [ -f "$_f" ] && all_files+=("$_f")
            done
          fi

          # L1 fast path: fingerprint = concatenated file sizes. If unchanged, skip Python.
          fp=""
          for _f in "${all_files[@]}"; do
            fp="${fp}$(_stat_size "$_f"):"
          done

          cached_fp=""
          if [ -f "$tcache" ]; then
            cached_fp=$(jq -r '.fp // ""' "$tcache" 2>/dev/null)
          fi

          if [ "$fp" != "$cached_fp" ] || [ -z "$cached_fp" ]; then
            # L2: incremental parse - seek past previously-parsed bytes per file
            _files_newline=$(printf '%s\\n' "${all_files[@]}")
            _py_stderr=/dev/null
            [ "$CLAUDE_STATUSLINE_DEBUG" = "1" ] && _py_stderr=/dev/stderr
            CS_FILES="$_files_newline" CS_FP="$fp" CS_TCACHE="$tcache" \\
            CS_PRICING="$PRICING_FILE" CS_MODEL_ID="$model_id" \\
            python3 -c '
        import json, os, sys, time

        files = [p for p in os.environ.get("CS_FILES", "").split("\\n") if p]
        fp = os.environ.get("CS_FP", "")
        tcache_path = os.environ.get("CS_TCACHE", "")
        pricing_file = os.environ.get("CS_PRICING", "")
        default_model_id = os.environ.get("CS_MODEL_ID", "")
        debug = os.environ.get("CLAUDE_STATUSLINE_DEBUG") == "1"
        t0 = time.time()
        app_pricing = {}
        try:
            with open(pricing_file) as f:
                app_pricing = json.load(f).get("models", {})
        except Exception:
            pass

        # Fallback pricing per million tokens: (input, output, cache_write_1h, cache_read)
        FALLBACK = {
            "opus-4-7":   (5.0,  25.0, 10.0,  0.50),
            "opus-4-6":   (5.0,  25.0, 10.0,  0.50),
            "opus-4-5":   (5.0,  25.0, 10.0,  0.50),
            "opus-4-1":   (15.0, 75.0, 30.0,  1.50),
            "opus-4":     (15.0, 75.0, 30.0,  1.50),
            "sonnet":     (3.0,  15.0, 6.0,   0.30),
            "haiku":      (0.80, 4.0,  1.60,  0.08),
        }

        def get_pricing(mid):
            m = (mid or "").lower()
            if mid in app_pricing:
                p = app_pricing[mid]
                return (p.get("input", 3.0), p.get("output", 15.0),
                        p.get("cache_write_1h", 6.0), p.get("cache_read", 0.30))
            for k, p in app_pricing.items():
                if k.lower() in m or m in k.lower():
                    return (p.get("input", 3.0), p.get("output", 15.0),
                            p.get("cache_write_1h", 6.0), p.get("cache_read", 0.30))
            for k, r in FALLBACK.items():
                if k in m:
                    return r
            return FALLBACK["sonnet"]

        # Load existing v2 cache; start fresh if missing or older schema
        cache = {"version": 2, "files": {}}
        try:
            with open(tcache_path) as f:
                loaded = json.load(f)
                if loaded.get("version") == 2:
                    cache = loaded
                    cache.setdefault("files", {})
        except Exception:
            pass

        # Drop entries for files that no longer exist (e.g. deleted subagents)
        current = set(files)
        for k in list(cache["files"].keys()):
            if k not in current:
                del cache["files"][k]

        # Parse JSONL from byte offset. JSONL is append-only so offset lands on a line boundary.
        def parse_from(path, offset, tokens, seen):
            try:
                with open(path, "r") as f:
                    f.seek(offset)
                    for line in f:
                        line = line.strip()
                        if not line: continue
                        try:
                            e = json.loads(line)
                        except Exception:
                            continue
                        if e.get("type") != "assistant": continue
                        msg = e.get("message", {})
                        mid_ = msg.get("id", "")
                        if mid_:
                            if mid_ in seen:
                                continue
                            seen.add(mid_)
                        model = msg.get("model") or default_model_id
                        if model == "<synthetic>":
                            model = default_model_id
                        u = msg.get("usage", {})
                        if model not in tokens:
                            tokens[model] = [0, 0, 0, 0]
                        tokens[model][0] += u.get("input_tokens", 0)
                        tokens[model][1] += u.get("output_tokens", 0)
                        tokens[model][2] += u.get("cache_creation_input_tokens", 0)
                        tokens[model][3] += u.get("cache_read_input_tokens", 0)
            except Exception:
                pass

        bytes_parsed = 0
        for path in files:
            try:
                cur_size = os.path.getsize(path)
            except Exception:
                continue
            entry = cache["files"].get(path)
            if entry and entry.get("size", 0) <= cur_size:
                # Incremental: seek past previously-parsed bytes
                tokens = {k: list(v) for k, v in entry.get("tokens", {}).items()}
                seen = set(entry.get("seen", []))
                prev = entry.get("size", 0)
                if cur_size > prev:
                    parse_from(path, prev, tokens, seen)
                    bytes_parsed += cur_size - prev
            else:
                # New file (or shrunk - rare; full re-parse)
                tokens = {}
                seen = set()
                parse_from(path, 0, tokens, seen)
                bytes_parsed += cur_size
            cache["files"][path] = {"size": cur_size, "tokens": tokens, "seen": list(seen)}

        # Aggregate per-model tokens -> cost
        M = 1_000_000
        tc = 0.0
        ti = to = tcc = tcr = 0
        for e in cache["files"].values():
            for mid_, vals in e.get("tokens", {}).items():
                i_ = vals[0] if len(vals) > 0 else 0
                o_ = vals[1] if len(vals) > 1 else 0
                cc_ = vals[2] if len(vals) > 2 else 0
                cr_ = vals[3] if len(vals) > 3 else 0
                p = get_pricing(mid_)
                tc += i_/M*p[0] + o_/M*p[1] + cc_/M*p[2] + cr_/M*p[3]
                ti += i_; to += o_; tcc += cc_; tcr += cr_

        cache["fp"] = fp
        cache["totals"] = {"input": ti, "output": to, "cc": tcc, "cr": tcr, "cost": round(tc, 4)}

        # Atomic write
        try:
            tmp = tcache_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(cache, f)
            os.replace(tmp, tcache_path)
        except Exception:
            pass

        if debug:
            sys.stderr.write(
                "[statusline] files=%d parsed=%dB elapsed=%.1fms\\n"
                % (len(files), bytes_parsed, (time.time() - t0) * 1000)
            )
        ' 2>"$_py_stderr"
          fi

          if [ -f "$tcache" ]; then
            total_input_tokens=$(jq -r '.totals.input // 0' "$tcache" 2>/dev/null)
            total_output_tokens=$(jq -r '.totals.output // 0' "$tcache" 2>/dev/null)
            cache_creation_tokens=$(jq -r '.totals.cc // 0' "$tcache" 2>/dev/null)
            cache_read_tokens=$(jq -r '.totals.cr // 0' "$tcache" 2>/dev/null)
            total_cost=$(jq -r '.totals.cost // 0' "$tcache" 2>/dev/null)
          fi
        fi

        # Fall back to real cwd if not provided
        [ -z "$cwd" ] && cwd="$(pwd)"

        # ---------------------------------------------------------------------------
        # ANSI colors — auto-detect light/dark terminal background.
        # ---------------------------------------------------------------------------
        detect_theme() {
          if [ -n "$CLAUDE_STATUSLINE_THEME" ]; then
            echo "$CLAUDE_STATUSLINE_THEME"
            return
          fi
          if command -v defaults &>/dev/null; then
            local style
            style=$(defaults read -g AppleInterfaceStyle 2>/dev/null)
            if [ "$style" = "Dark" ]; then echo "dark"; else echo "light"; fi
            return
          fi
          echo "dark"
        }

        theme=$(detect_theme)
        bold=$'\\033[1m'
        reset=$'\\033[0m'

        if [ "$theme" = "light" ]; then
          blue=$'\\033[34m'; cyan=$'\\033[36m'; green=$'\\033[32m'; yellow=$'\\033[33m'
          red=$'\\033[31m'; magenta=$'\\033[35m'; white=$'\\033[30m'
          gray=$'\\033[37m'; lgray=$'\\033[90m'
        else
          blue=$'\\033[94m'; cyan=$'\\033[96m'; green=$'\\033[92m'; yellow=$'\\033[93m'
          red=$'\\033[91m'; magenta=$'\\033[95m'; white=$'\\033[97m'
          gray=$'\\033[90m'; lgray=$'\\033[37m'
        fi

        # ---------------------------------------------------------------------------
        # Icons — Nerd Font with auto-detection, plain text fallback
        # ---------------------------------------------------------------------------
        _nf=false
        for _d in "$HOME/Library/Fonts" "/Library/Fonts"; do
          ls "$_d"/*Nerd* "$_d"/*nerd* "$_d"/MesloLGS* "$_d"/*NF-* "$_d"/*NFM-* 2>/dev/null | head -1 | grep -q . && _nf=true && break
        done

        if $_nf; then
          icon_folder=$'\\uf07c'; icon_git=$'\\ue725'
          icon_ctx=$'\\uf1c0';    icon_quota=$'\\uf0e4'
          icon_cost=$'\\uf155';   icon_up=$'\\uf062';    icon_down=$'\\uf063'
          icon_cwrite=$'\\uf0ee'; icon_cread=$'\\uf0ed';  icon_tree=$'\\uf1bb'
        else
          icon_folder="";  icon_git=""
          icon_ctx="";     icon_quota=""
          icon_cost="\\$";  icon_up="↑";    icon_down="↓"
          icon_cwrite="⇡"; icon_cread="⇣"; icon_tree=""
        fi

        sep="${gray} | ${reset}"

        # ---------------------------------------------------------------------------
        # Basic identity
        # ---------------------------------------------------------------------------
        short_dir="${cwd/#$HOME/~}"

        # ---------------------------------------------------------------------------
        # Git information
        # ---------------------------------------------------------------------------
        git_section=""

        if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
          git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \\
                       || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

          porcelain=$(git -C "$cwd" status --porcelain 2>/dev/null)
          staged=$(echo "$porcelain" | grep -c '^[MADRC]' 2>/dev/null || echo 0)
          modified=$(echo "$porcelain" | grep -c '^.[MD]' 2>/dev/null || echo 0)
          untracked=$(echo "$porcelain" | grep -c '^??' 2>/dev/null || echo 0)

          if $_nf; then icon_dirty=$'\\uf06a'; icon_clean=$'\\uf00c'
          else          icon_dirty="×";       icon_clean="✓"
          fi
          if [ -n "$porcelain" ]; then
            git_dirty="${red}${icon_dirty}${reset}"
          else
            git_dirty="${green}${icon_clean}${reset}"
          fi

          git_ab=""
          ab=$(git -C "$cwd" rev-list --left-right --count "@{upstream}...HEAD" 2>/dev/null)
          if [ -n "$ab" ]; then
            behind=$(echo "$ab" | awk '{print $1}')
            ahead=$(echo "$ab" | awk '{print $2}')
            [ "$ahead" -gt 0 ] 2>/dev/null && git_ab="${git_ab}${green}ahead:${ahead}${reset}"
            [ "$behind" -gt 0 ] 2>/dev/null && git_ab="${git_ab} ${red}behind:${behind}${reset}"
          fi

          git_stash=""
          stash_n=$(git -C "$cwd" stash list 2>/dev/null | wc -l | tr -d ' ')
          [ "$stash_n" -gt 0 ] 2>/dev/null && git_stash=" ${lgray}stash:${yellow}${stash_n}${reset}"

          git_detail=""
          [ "$staged" -gt 0 ] 2>/dev/null && git_detail="${git_detail} ${green}stage:${staged}${reset}"
          [ "$modified" -gt 0 ] 2>/dev/null && git_detail="${git_detail} ${yellow}mod:${modified}${reset}"
          [ "$untracked" -gt 0 ] 2>/dev/null && git_detail="${git_detail} ${lgray}new:${untracked}${reset}"

          git_section=" ${icon_git:+${blue}${icon_git} }${cyan}${git_branch}${reset} ${git_dirty}"
          [ -n "$git_ab" ] && git_section="${git_section} ${git_ab}"
          git_section="${git_section}${git_detail}${git_stash}"
        fi

        # ---------------------------------------------------------------------------
        # Format tokens
        # ---------------------------------------------------------------------------
        format_tokens() {
          local n=$1
          if [ "$n" -ge 1000000 ] 2>/dev/null; then
            printf "%.1fM" "$(echo "scale=1; $n / 1000000" | bc 2>/dev/null)"
          elif [ "$n" -ge 100000 ] 2>/dev/null; then
            printf "%dk" "$(( n / 1000 ))"
          elif [ "$n" -ge 1000 ] 2>/dev/null; then
            printf "%.1fk" "$(echo "scale=1; $n / 1000" | bc 2>/dev/null)"
          else
            printf "%d" "$n"
          fi
        }

        clean_pct() { printf "%.0f" "$1" 2>/dev/null || echo "$1"; }

        color_pct() {
          local val=$(clean_pct "$1")
          local int_val=${val%.*}
          if   [ "$int_val" -ge 80 ] 2>/dev/null; then printf "${red}%s%%${reset}" "$val"
          elif [ "$int_val" -ge 50 ] 2>/dev/null; then printf "${yellow}%s%%${reset}" "$val"
          else                                          printf "${green}%s%%${reset}" "$val"
          fi
        }

        format_remaining() {
          python3 -c "
        from datetime import datetime, timezone
        try:
            reset = datetime.fromisoformat('$1')
            now = datetime.now(timezone.utc)
            remaining = int((reset - now).total_seconds())
            if remaining > 0:
                h, m = remaining // 3600, (remaining % 3600) // 60
                print(f'{h}h{m:02d}m' if h > 0 else f'{m}m')
        except:
            pass
        " 2>/dev/null
        }

        format_remaining_days() {
          python3 -c "
        from datetime import datetime, timezone
        try:
            reset = datetime.fromisoformat('$1')
            now = datetime.now(timezone.utc)
            remaining = int((reset - now).total_seconds())
            if remaining > 0:
                d, h = remaining // 86400, (remaining % 86400) // 3600
                print(f'{d}d{h}h' if d > 0 else f'{h}h')
        except:
            pass
        " 2>/dev/null
        }

        # ---------------------------------------------------------------------------
        # Rate limits from stdin — write to usage cache (no API call needed)
        # Requires Claude Code v2.1.80+; silently skipped on older versions
        # ---------------------------------------------------------------------------
        APP_USAGE_CACHE="$HOME/.claude-statistics/usage-cache.json"

        rl_5h_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
        rl_5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
        rl_7d_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
        rl_7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

        if [ -n "$rl_5h_pct" ] && [ -n "$rl_7d_pct" ]; then
          python3 -c "
        import json, os, time
        from datetime import datetime, timezone

        def ts_to_iso(ts):
            return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

        now_ts = int(time.time())
        stdin_5h = float('$rl_5h_pct')
        stdin_7d = float('$rl_7d_pct')
        stdin_5h_r = int('$rl_5h_reset')
        stdin_7d_r = int('$rl_7d_reset')

        def make_window(utilization, reset_iso):
            return {'utilization': utilization, 'resets_at': reset_iso}

        def parse_reset_ts(s):
            if not s:
                return None
            try:
                # Supports '...Z' and '...+00:00', with/without fractional seconds.
                return datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()
            except Exception:
                return None

        def same_reset_window(a, b):
            if a == b:
                return True
            ta, tb = parse_reset_ts(a), parse_reset_ts(b)
            if ta is None or tb is None:
                return False
            return abs(ta - tb) < 60

        def merge_window(api_window, api_fetched_at, stdin_window, stdin_fetched_at):
            if not api_window:
                return stdin_window
            if not stdin_window:
                return api_window

            api_reset = api_window.get('resets_at') or ''
            stdin_reset = stdin_window.get('resets_at') or ''
            if same_reset_window(api_reset, stdin_reset):
                return {
                    'utilization': max(float(api_window.get('utilization', 0)), float(stdin_window.get('utilization', 0))),
                    'resets_at': api_reset or stdin_reset or None,
                }

            api_ts = int(api_fetched_at or 0)
            stdin_ts = int(stdin_fetched_at or 0)
            return stdin_window if stdin_ts >= api_ts else api_window

        # --- Update usage-cache.json ---
        try:
            with open('$APP_USAGE_CACHE') as f:
                out = json.load(f)
        except:
            out = {'fetched_at': '0', 'data': {}, 'sources': {}}

        data = out.get('data', {}) or {}
        sources = out.get('sources', {}) or {}
        api_source = sources.get('api', {}) or {}
        stdin_source = sources.get('stdin', {}) or {}

        if not api_source and isinstance(data, dict):
            api_source = {'fetched_at': str(out.get('fetched_at', '0'))}
            if isinstance(data.get('five_hour'), dict):
                api_source['five_hour'] = data.get('five_hour')
            if isinstance(data.get('seven_day'), dict):
                api_source['seven_day'] = data.get('seven_day')

        new_5h_r = ts_to_iso(stdin_5h_r)
        new_7d_r = ts_to_iso(stdin_7d_r)
        stdin_source = {
            'fetched_at': str(now_ts),
            'five_hour': make_window(stdin_5h, new_5h_r),
            'seven_day': make_window(stdin_7d, new_7d_r),
        }

        merged_five_hour = merge_window(
            api_source.get('five_hour'),
            api_source.get('fetched_at'),
            stdin_source.get('five_hour'),
            stdin_source.get('fetched_at'),
        )
        merged_seven_day = merge_window(
            api_source.get('seven_day'),
            api_source.get('fetched_at'),
            stdin_source.get('seven_day'),
            stdin_source.get('fetched_at'),
        )

        if merged_five_hour:
            data['five_hour'] = merged_five_hour
        else:
            data.pop('five_hour', None)

        if merged_seven_day:
            data['seven_day'] = merged_seven_day
        else:
            data.pop('seven_day', None)

        out['data'] = data
        out['sources'] = {'api': api_source, 'stdin': stdin_source}
        out['fetched_at'] = str(now_ts)
        with open('$APP_USAGE_CACHE', 'w') as f:
            json.dump(out, f)

        # --- Append to usage-history.jsonl ---
        # Dedup: skip if same values within 5 minutes
        history_path = os.path.expanduser('~/.claude-statistics/usage-history.jsonl')
        entry = {'ts': now_ts, 'fh': stdin_5h, 'fh_r': stdin_5h_r, 'sd': stdin_7d, 'sd_r': stdin_7d_r}

        should_append = True
        try:
            with open(history_path, 'rb') as f:
                f.seek(0, 2)
                size = f.tell()
                if size > 0:
                    f.seek(max(0, size - 256))
                    last_line = f.read().decode('utf-8', errors='ignore').strip().split('\\n')[-1]
                    last = json.loads(last_line)
                    if (now_ts - last.get('ts', 0) < 300 and
                            last.get('fh') == stdin_5h and last.get('sd') == stdin_7d and
                            last.get('fh_r') == stdin_5h_r and last.get('sd_r') == stdin_7d_r):
                        should_append = False
        except:
            pass

        if should_append:
            with open(history_path, 'a') as f:
                f.write(json.dumps(entry) + '\\n')
        " 2>/dev/null
        fi

        # ---------------------------------------------------------------------------
        # Subscription usage — read from Claude Statistics app cache
        # ---------------------------------------------------------------------------
        quota_section=""

        if [ -f "$APP_USAGE_CACHE" ]; then
          usage_data=$(jq -r '.data' "$APP_USAGE_CACHE" 2>/dev/null)

          five_h_util=$(echo "$usage_data" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
          five_h_reset=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
          seven_d_util=$(echo "$usage_data" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
          seven_d_reset=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)

          if [ -n "$five_h_util" ]; then
            five_remaining=$(format_remaining "$five_h_reset")
            quota_section="${lgray}5h $(color_pct "$five_h_util")"
            [ -n "$five_remaining" ] && quota_section="${quota_section}${gray}(${lgray}${five_remaining}${gray})${reset}"
          fi

          if [ -n "$seven_d_util" ]; then
            seven_remaining=$(format_remaining_days "$seven_d_reset")
            quota_section="${quota_section} ${lgray}7d $(color_pct "$seven_d_util")"
            [ -n "$seven_remaining" ] && quota_section="${quota_section}${gray}(${lgray}${seven_remaining}${gray})${reset}"
          fi
        fi

        # ---------------------------------------------------------------------------
        # Model + context window
        # ---------------------------------------------------------------------------
        meta=""
        model_short=$(echo "$model" | sed 's/ ([0-9]*[KkMm] context)//')
        [ -n "$model_short" ] && meta="${bold}${cyan}${model_short}${reset}"

        if [ -n "$used_pct" ]; then
          if [ "$ctx_window_size" -gt 0 ] 2>/dev/null; then
            ctx_total=$(format_tokens "$ctx_window_size")
            ctx_str="${gray}${icon_ctx:+${icon_ctx} }$(color_pct "$used_pct")${gray}/${lgray}${ctx_total}${reset}"
          else
            ctx_str="${gray}${icon_ctx:+${icon_ctx} }$(color_pct "$used_pct")"
          fi
          [ -n "$meta" ] && meta="${meta} ${ctx_str}" || meta="${ctx_str}"
        fi

        # ---------------------------------------------------------------------------
        # Cost & usage section
        # ---------------------------------------------------------------------------
        cost_section=""

        cost_val=$(printf "%.2f" "$total_cost" 2>/dev/null || echo "0.00")
        cost_section="${yellow}${icon_cost} ${green}${cost_val}${reset}"

        in_tok=$(format_tokens "$total_input_tokens")
        out_tok=$(format_tokens "$total_output_tokens")
        cost_section="${cost_section} ${cyan}${icon_up} ${in_tok}${reset} ${magenta}${icon_down} ${out_tok}${reset}"

        if [ "$cache_creation_tokens" -gt 0 ] 2>/dev/null || [ "$cache_read_tokens" -gt 0 ] 2>/dev/null; then
          cc_tok=$(format_tokens "$cache_creation_tokens")
          cr_tok=$(format_tokens "$cache_read_tokens")
          cost_section="${cost_section} ${yellow}${icon_cwrite} ${cc_tok} ${icon_cread} ${cr_tok}${reset}"
        fi

        # ---------------------------------------------------------------------------
        # Session name & Worktree
        # ---------------------------------------------------------------------------
        session_part=""
        [ -n "$session_name" ] && session_part="  ${gray}[${session_name}]${reset}"

        wt_part=""
        if [ -n "$wt_name" ]; then
          wt_part="${icon_tree:+${lgray}${icon_tree} }${cyan}${wt_name}${reset}"
          [ -n "$wt_branch" ] && wt_part="${wt_part} ${gray}> ${cyan}${wt_branch}${reset}"
        fi

        # ---------------------------------------------------------------------------
        # LINE 1: path  git-branch
        # OSC 8 hyperlink: cmd+click opens directory in VS Code
        # ---------------------------------------------------------------------------
        osc_start=$'\\033]8;;'
        osc_end=$'\\033]8;;\\007'
        vscode_url="vscode://file${cwd}"

        printf "${bold}${yellow}${icon_folder:+${icon_folder} }${osc_start}${vscode_url}\\007%s${osc_end}${reset}%s\\n" \\
          "$short_dir" "$git_section"

        # ---------------------------------------------------------------------------
        # LINE 2: model ctx | quota | cost tokens | worktree
        # ---------------------------------------------------------------------------
        line2="${meta}"
        [ -n "$quota_section" ] && line2="${line2}${sep}${icon_quota:+${gray}${icon_quota} ${reset}}${quota_section}"
        [ -n "$cost_section" ]  && line2="${line2}${sep}${cost_section}"
        [ -n "$wt_part" ]       && line2="${line2}${sep}${wt_part}"
        [ -n "$session_part" ]  && line2="${line2}${session_part}"

        printf "  %s\\n" "$line2"
        """
    }
}
