import Foundation

/// Manages installation of the Claude Statistics-integrated status line script
struct StatusLineInstaller {
    static let scriptPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusline-command.sh")
    static let backupPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusline-command.sh.bak")
    static let marker = "# Claude Statistics Integration v1"

    /// Check if our integrated script is currently installed
    static var isInstalled: Bool {
        guard let content = try? String(contentsOfFile: scriptPath, encoding: .utf8) else { return false }
        return content.contains(marker)
    }

    /// Check if a backup exists
    static var hasBackup: Bool {
        FileManager.default.fileExists(atPath: backupPath)
    }

    /// Install the integrated status line script
    static func install() throws {
        let fm = FileManager.default

        // Backup current script if it exists and isn't ours
        if fm.fileExists(atPath: scriptPath) {
            let current = try String(contentsOfFile: scriptPath, encoding: .utf8)
            if !current.contains(marker) {
                if fm.fileExists(atPath: backupPath) {
                    try fm.removeItem(atPath: backupPath)
                }
                try fm.copyItem(atPath: scriptPath, toPath: backupPath)
            }
        }

        // Write new script
        try generatedScript().write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // Make executable
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    /// Restore the backup script
    static func restore() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else {
            throw StatusLineError.noBackup
        }
        if fm.fileExists(atPath: scriptPath) {
            try fm.removeItem(atPath: scriptPath)
        }
        try fm.copyItem(atPath: backupPath, toPath: scriptPath)
        try fm.removeItem(atPath: backupPath)
    }

    enum StatusLineError: LocalizedError {
        case noBackup
        var errorDescription: String? { "No backup file found" }
    }

    // MARK: - Script generation

    private static func generatedScript() -> String {
        let pricingPath = "~/.claude-statistics/pricing.json"
        let usageCachePath = "~/.claude-statistics/usage-cache.json"

        return """
        #!/usr/bin/env bash
        \(marker)
        # Two-line status bar based on oh-my-zsh "ys" theme
        # Requires Nerd Font for icons
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
        # ---------------------------------------------------------------------------
        TRANSCRIPT_CACHE_DIR="$HOME/.claude/statusline-cache"
        mkdir -p "$TRANSCRIPT_CACHE_DIR" 2>/dev/null

        total_input_tokens=0
        total_output_tokens=0
        cache_creation_tokens=0
        cache_read_tokens=0
        total_cost="0.00"

        PRICING_FILE="$HOME/.claude-statistics/pricing.json"

        if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
          cache_key=$(echo "$transcript_path" | md5 -q 2>/dev/null || echo "$transcript_path" | md5sum 2>/dev/null | cut -d' ' -f1)
          tcache="$TRANSCRIPT_CACHE_DIR/${cache_key}.json"
          file_size=$(stat -f%z "$transcript_path" 2>/dev/null || stat -c%s "$transcript_path" 2>/dev/null || echo 0)

          cached_size=0
          if [ -f "$tcache" ]; then
            cached_size=$(jq -r '.file_size // 0' "$tcache" 2>/dev/null)
          fi

          if [ "$file_size" != "$cached_size" ]; then
            transcript_stats=$(python3 -c "
        import json, sys, os

        # Load pricing from Claude Statistics app
        pricing_file = os.path.expanduser('$PRICING_FILE')
        app_pricing = {}
        try:
            with open(pricing_file) as f:
                data = json.load(f)
                app_pricing = data.get('models', {})
        except:
            pass

        # Fallback pricing per million tokens: (input, output, cache_write_1h, cache_read)
        FALLBACK = {
            'opus-4-6':   (5.0,  25.0, 10.0,  0.50),
            'opus-4-5':   (5.0,  25.0, 10.0,  0.50),
            'opus-4-1':   (15.0, 75.0, 30.0,  1.50),
            'opus-4':     (15.0, 75.0, 30.0,  1.50),
            'sonnet':     (3.0,  15.0, 6.0,   0.30),
            'haiku':      (0.80, 4.0,  1.60,  0.08),
        }

        def get_pricing(model_id):
            m = (model_id or '').lower()
            # Try app pricing first (exact match)
            if model_id in app_pricing:
                p = app_pricing[model_id]
                return (p.get('input', 3.0), p.get('output', 15.0),
                        p.get('cache_write_1h', 6.0), p.get('cache_read', 0.30))
            # Fuzzy match app pricing
            for key, p in app_pricing.items():
                if key.lower() in m or m in key.lower():
                    return (p.get('input', 3.0), p.get('output', 15.0),
                            p.get('cache_write_1h', 6.0), p.get('cache_read', 0.30))
            # Fallback
            for key, rates in FALLBACK.items():
                if key in m:
                    return rates
            return FALLBACK.get('sonnet', (3.0, 15.0, 6.0, 0.30))

        # Per-model token accumulators (deduplicated by message ID)
        model_tokens = {}  # model_id -> [inp, out, cc, cr]
        seen_ids = set()

        try:
            with open('$transcript_path', 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try:
                        entry = json.loads(line)
                    except: continue
                    if entry.get('type') != 'assistant': continue
                    msg = entry.get('message', {})
                    msg_id = msg.get('id', '')
                    if msg_id in seen_ids:
                        continue
                    if msg_id:
                        seen_ids.add(msg_id)
                    mid = msg.get('model') or '${model_id}'
                    if mid == '<synthetic>':
                        mid = '${model_id}'
                    u = msg.get('usage', {})
                    inp = u.get('input_tokens', 0)
                    out = u.get('output_tokens', 0)
                    cc  = u.get('cache_creation_input_tokens', 0)
                    cr  = u.get('cache_read_input_tokens', 0)
                    if mid not in model_tokens:
                        model_tokens[mid] = [0, 0, 0, 0]
                    model_tokens[mid][0] += inp
                    model_tokens[mid][1] += out
                    model_tokens[mid][2] += cc
                    model_tokens[mid][3] += cr
        except: pass

        # Calculate per-model cost
        M = 1_000_000
        total_cost = 0
        total_inp = total_out = total_cc = total_cr = 0
        for mid, (inp, out, cc, cr) in model_tokens.items():
            p = get_pricing(mid)
            total_cost += inp/M*p[0] + out/M*p[1] + cc/M*p[2] + cr/M*p[3]
            total_inp += inp
            total_out += out
            total_cc += cc
            total_cr += cr

        print(json.dumps({
            'input': total_inp, 'output': total_out,
            'cache_create': total_cc, 'cache_read': total_cr,
            'cost': round(total_cost, 4),
            'file_size': $file_size
        }))
        " 2>/dev/null)

            if [ -n "$transcript_stats" ]; then
              echo "$transcript_stats" > "$tcache"
            fi
          fi

          if [ -f "$tcache" ]; then
            total_input_tokens=$(jq -r '.input // 0' "$tcache" 2>/dev/null)
            total_output_tokens=$(jq -r '.output // 0' "$tcache" 2>/dev/null)
            cache_creation_tokens=$(jq -r '.cache_create // 0' "$tcache" 2>/dev/null)
            cache_read_tokens=$(jq -r '.cache_read // 0' "$tcache" 2>/dev/null)
            total_cost=$(jq -r '.cost // 0' "$tcache" 2>/dev/null)
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
        # Nerd Font icons
        # ---------------------------------------------------------------------------
        icon_folder=$'\\uf07c'
        icon_git=$'\\ue725'
        icon_ctx=$'\\uf1c0'
        icon_quota=$'\\uf0e4'
        icon_cost=$'\\uf155'
        icon_up=$'\\uf062'
        icon_down=$'\\uf063'
        icon_cwrite=$'\\uf0ee'
        icon_cread=$'\\uf0ed'
        icon_tree=$'\\uf1bb'

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

          icon_dirty=$'\\uf06a'
          icon_clean=$'\\uf00c'
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
            [ "$ahead" -gt 0 ] 2>/dev/null && git_ab="${git_ab}${green}+${ahead}${reset}"
            [ "$behind" -gt 0 ] 2>/dev/null && git_ab="${git_ab}${red}-${behind}${reset}"
          fi

          git_stash=""
          stash_n=$(git -C "$cwd" stash list 2>/dev/null | wc -l | tr -d ' ')
          [ "$stash_n" -gt 0 ] 2>/dev/null && git_stash=" ${lgray}s${yellow}${stash_n}${reset}"

          git_detail=""
          [ "$staged" -gt 0 ] 2>/dev/null && git_detail="${git_detail} ${green}s${staged}${reset}"
          [ "$modified" -gt 0 ] 2>/dev/null && git_detail="${git_detail} ${yellow}m${modified}${reset}"
          [ "$untracked" -gt 0 ] 2>/dev/null && git_detail="${git_detail} ${lgray}u${untracked}${reset}"

          git_section=" ${blue}${icon_git} ${cyan}${git_branch}${reset} ${git_dirty}"
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

        clean_pct() { echo "$1" | sed 's/\\.0$//'; }

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
        # Subscription usage — read from Claude Statistics app cache
        # ---------------------------------------------------------------------------
        APP_USAGE_CACHE="$HOME/.claude-statistics/usage-cache.json"
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
            ctx_str="${gray}${icon_ctx} $(color_pct "$used_pct")${gray}/${lgray}${ctx_total}${reset}"
          else
            ctx_str="${gray}${icon_ctx} $(color_pct "$used_pct")"
          fi
          [ -n "$meta" ] && meta="${meta} ${ctx_str}" || meta="${ctx_str}"
        fi

        # ---------------------------------------------------------------------------
        # Cost & usage section
        # ---------------------------------------------------------------------------
        cost_section=""

        cost_val=$(printf "%.2f" "$total_cost" 2>/dev/null || echo "0.00")
        cost_section="${yellow}${icon_cost} ${green}\\$${cost_val}${reset}"

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
          wt_part="${lgray}${icon_tree} ${cyan}${wt_name}${reset}"
          [ -n "$wt_branch" ] && wt_part="${wt_part} ${gray}> ${cyan}${wt_branch}${reset}"
        fi

        # ---------------------------------------------------------------------------
        # LINE 1: path  git-branch
        # OSC 8 hyperlink: cmd+click opens directory in VS Code
        # ---------------------------------------------------------------------------
        osc_start=$'\\033]8;;'
        osc_end=$'\\033]8;;\\007'
        vscode_url="vscode://file${cwd}"

        printf "${bold}${yellow}${icon_folder} ${osc_start}${vscode_url}\\007%s${osc_end}${reset}%s\\n" \\
          "$short_dir" "$git_section"

        # ---------------------------------------------------------------------------
        # LINE 2: model ctx | quota | cost tokens | worktree
        # ---------------------------------------------------------------------------
        line2="${meta}"
        [ -n "$quota_section" ] && line2="${line2}${sep}${gray}${icon_quota} ${reset}${quota_section}"
        [ -n "$cost_section" ]  && line2="${line2}${sep}${cost_section}"
        [ -n "$wt_part" ]       && line2="${line2}${sep}${wt_part}"
        [ -n "$session_part" ]  && line2="${line2}${session_part}"

        printf "  %s\\n" "$line2"
        """
    }
}
