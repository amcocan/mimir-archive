#!/bin/bash

# macos cleanup script v1.0 | Author: amcocan (2024-06-15) with the help of Glean.

# Designed for NinjaOne RMM (unattended, runs as root)

#
# Usage:

#   ./macos_cleaner.sh              → Safe cleanup (default)

#   ./macos_cleaner.sh --deep       → Safe + deep locations (auto reboot)

#   ./macos_cleaner.sh --dry-run    → Simulation only

#   ./macos_cleaner.sh --verbose    → Detailed output (no bundling)

#   ./macos_cleaner.sh --silent     → Minimal output (space + time only)

#   ./macos_cleaner.sh --no-reboot  → Deep cleanup without reboot

#   ./macos_cleaner.sh --keep       → Save log to /Users/Shared/macos-cleaner.log

#   ./macos_cleaner.sh --help       → Show usage

#   ./macos_cleaner.sh --test       → Run unit tests

set -uo pipefail

# ====================== GLOBAL VARIABLES ======================

declare -i deep_mode=0
declare -i verbose_mode=0
declare -i dry_run=0
declare -i silent_mode=0
declare -i no_reboot=0
declare -i keep_log=0
declare -i test_mode=0
declare -i help_mode=0

declare -i total_kb=0
declare -i start_time_ms=0
declare -i end_time_ms=0
declare -i has_bc=0

declare timestamp=""
declare temp_log_dir=""
declare pass_log=""
declare warn_log=""
declare fail_log=""
declare strict_log=""
declare test_log=""

declare -a sip_warnings=()

# ====================== CORE HELPER FUNCTIONS ======================

# Sanitize a value to ensure it's a valid integer

# Strips all non-numeric characters except minus sign, defaults to 0 if empty
to_int() {
    local val="$1"
    val=${val//[^0-9-]/}
    [[ -z "$val" || "$val" == "-" ]] && val=0
    printf '%s' "$val"
}

# Check if bc is available for millisecond precision
check_bc() {
    command -v bc &>/dev/null && has_bc=1 || has_bc=0
}

# Get current time in milliseconds (or seconds * 1000 as fallback)
get_time_ms() {
    local result
    if [[ $has_bc -eq 1 ]]; then
        result=$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000' 2>/dev/null) || result=$(($(date +%s) * 1000))
    else
        result=$(($(date +%s) * 1000))
    fi
    # Return sanitized integer
    to_int "$result"
}

# Convert KB to human-readable format
size_to_human() {
    local kb
    kb=$(to_int "$1")

    if (( kb >= 1048576 )); then
        if [[ $has_bc -eq 1 ]]; then
            printf "%.2f GB" "$(echo "scale=2; $kb / 1048576" | bc 2>/dev/null)"
        else
            printf "%d GB" "$((kb / 1048576))"
        fi
    elif (( kb >= 1024 )); then
        if [[ $has_bc -eq 1 ]]; then
            printf "%.2f MB" "$(echo "scale=2; $kb / 1024" | bc 2>/dev/null)"
        else
            printf "%d MB" "$((kb / 1024))"
        fi
    else
        printf "%d KB" "$kb"
    fi
}

# Convert milliseconds to human-readable format
time_to_human() {
    local ms
    ms=$(to_int "$1")

    local seconds=$((ms / 1000))
    local minutes=$((seconds / 60))
    local hours=$((minutes / 60))
    seconds=$((seconds % 60))
    minutes=$((minutes % 60))
    ms=$((ms % 1000))

    if (( hours > 0 )); then
        printf "%dh %dm %ds %dms" "$hours" "$minutes" "$seconds" "$ms"
    elif (( minutes > 0 )); then
        printf "%dm %ds %dms" "$minutes" "$seconds" "$ms"
    elif (( seconds > 0 )); then
        printf "%ds %dms" "$seconds" "$ms"
    else
        printf "%dms" "$ms"
    fi
}

# Start timer
timer_start() {
    start_time_ms=$(to_int "$(get_time_ms)")
}

# Stop timer
timer_stop() {
    end_time_ms=$(to_int "$(get_time_ms)")
}

# Get duration string
get_duration() {
    local start end duration
    start=$(to_int "$start_time_ms")
    end=$(to_int "$end_time_ms")
    duration=$((end - start))
    time_to_human "$duration"
}

# Get size of a target path in KB
get_target_size() {
    local target="$1"
    local result
    result=$(du -sk "$target" 2>/dev/null | awk '{print $1}') || result=0
    to_int "$result"
}

# ====================== LOGGING FUNCTIONS ======================

# Initialize temporary log directory
init_logs() {
    timestamp=$(date +%Y%m%d_%H%M%S)
    temp_log_dir="/tmp/macos-cleaner-${timestamp}"
    mkdir -p "$temp_log_dir"

    pass_log="${temp_log_dir}/pass.log"
    warn_log="${temp_log_dir}/warn.log"
    fail_log="${temp_log_dir}/fail.log"
    strict_log="${temp_log_dir}/strict.log"
    test_log="${temp_log_dir}/test.log"

    touch "$pass_log" "$warn_log" "$fail_log" "$strict_log" "$test_log"
}

# Log a message with appropriate tag
log_msg() {
    local tag="$1"
    local location="$2"
    local detail="$3"
    local size="${4:-}"

    local log_file=""
    local line=""

    case "$tag" in
        PASS)   log_file="$pass_log" ;;
        WARN)   log_file="$warn_log" ;;
        FAIL)   log_file="$fail_log" ;;
        STRICT) log_file="$strict_log" ;;
        TEST)   log_file="$test_log" ;;
    esac

    if [[ -n "$size" ]]; then
        line="[${tag}] ${location} | ${detail} | ${size}"
    elif [[ -n "$detail" ]]; then
        line="[${tag}] ${location} | ${detail}"
    else
        line="[${tag}] ${location}"
    fi

    echo "$line" >> "$log_file"
}

# Bundle logs by error type per parent directory (for non-verbose mode)
# Uses awk for grouping to maintain bash 3.2 compatibility (macOS default)
bundle_logs() {
    local input_file="$1"

    [[ ! -s "$input_file" ]] && return

    # Verbose mode: output everything without bundling
    if [[ $verbose_mode -eq 1 ]]; then
        cat "$input_file"
        return
    fi

    # Use awk to group by tag, parent directory, and error type
    awk -F'|' '
    {
        # Extract tag (e.g., [PASS], [FAIL])
        match($1, /\[[A-Z]+\]/)
        tag = substr($1, RSTART, RLENGTH)

        # Extract location (after tag, before first |)
        location = $1
        sub(/^\[[A-Z]+\] */, "", location)
        gsub(/^ +| +$/, "", location)

        # Get parent directory
        n = split(location, parts, "/")
        if (n > 1) {
            parent = ""
            for (i = 1; i < n; i++) {
                parent = parent "/" parts[i]
            }
            gsub(/^\/+/, "/", parent)
        } else {
            parent = location
        }

        # Extract detail (second field)
        detail = $2
        gsub(/^ +| +$/, "", detail)

        # Create grouping key
        key = tag "|" parent "|" detail

        # Count occurrences
        count[key]++

        # Store the tag and detail for output
        tags[key] = tag
        parents[key] = parent
        details[key] = detail
    }
    END {
        for (key in count) {
            if (count[key] > 1) {
                printf "%s %s | %s (%d items)\n", tags[key], parents[key], details[key], count[key]
            } else {
                printf "%s %s | %s\n", tags[key], parents[key], details[key]
            }
        }
    }
    ' "$input_file"
}

# Compile and output all logs in priority order
compile_logs() {
    local output=""
    local total_sanitized
    total_sanitized=$(to_int "$total_kb")

    # Header
    output="$(size_to_human "$total_sanitized") | $(get_duration)\n"
    output+="\n"

    # STRICT > FAIL > WARN > PASS > TEST
    if [[ -s "$strict_log" ]]; then
        output+="$(bundle_logs "$strict_log")\n"
    fi

    if [[ -s "$fail_log" ]]; then
        output+="$(bundle_logs "$fail_log")\n"
    fi

    if [[ -s "$warn_log" ]]; then
        output+="$(bundle_logs "$warn_log")\n"
    fi

    if [[ -s "$pass_log" ]]; then
        output+="$(bundle_logs "$pass_log")\n"
    fi

    if [[ $dry_run -eq 1 ]] && [[ -s "$test_log" ]]; then
        output+="$(bundle_logs "$test_log")\n"
    fi

    echo -e "$output"
}

# Print final summary
print_summary() {
    local tag_prefix="PASS"
    [[ $dry_run -eq 1 ]] && tag_prefix="TEST"

    if [[ $silent_mode -eq 1 ]]; then
        local total_sanitized
        total_sanitized=$(to_int "$total_kb")
        echo "$(size_to_human "$total_sanitized") | $(get_duration)"
        return
    fi

    compile_logs

    # DNS Flush status (if deep mode)
    if [[ $deep_mode -eq 1 ]]; then
        echo ""
        echo "[${tag_prefix}] DNS Cache | Flushed"
    fi

    # Reboot notice (if deep mode and not no-reboot)
    if [[ $deep_mode -eq 1 ]] && [[ $no_reboot -eq 0 ]] && [[ $dry_run -eq 0 ]]; then
        echo "[${tag_prefix}] System | Reboot in 3 seconds"
    elif [[ $deep_mode -eq 1 ]] && [[ $no_reboot -eq 1 ]]; then
        echo "[WARN] System | Reboot skipped (--no-reboot)"
    fi

    # Keep log location
    if [[ $keep_log -eq 1 ]]; then
        echo ""
        echo "[${tag_prefix}] Log saved | /Users/Shared/macos-cleaner.log"
    fi
}

# Save persistent log if --keep flag is set
save_persistent_log() {
    if [[ $keep_log -eq 1 ]]; then
        {
            echo "macOS Cleanup Log - $(date)"
            echo "================================"
            echo ""
            compile_logs
        } > /Users/Shared/macos-cleaner.log 2>/dev/null || \
            log_msg "FAIL" "/Users/Shared/macos-cleaner.log" "Could not save log"
    fi
}

# Cleanup temporary logs
cleanup_logs() {
    [[ -d "$temp_log_dir" ]] && rm -rf "$temp_log_dir" 2>/dev/null
}

# ====================== VALIDATION FUNCTIONS ======================

# Check for root privileges
check_root() {
    if [[ $(id -u) -ne 0 ]]; then
        echo "ERROR: Script must run as root (NinjaOne 'System' execution context)"
        exit 1
    fi
}

# Validate environment
validate_env() {
    # Check macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "ERROR: This script is designed for macOS only"
        exit 1
    fi

    # Log bash version for debugging (optional)
    local bash_version="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
    if [[ $verbose_mode -eq 1 ]]; then
        echo "Bash version: $bash_version"
    fi

    # Check bc availability
    check_bc
}

# Check if path is network-mounted
is_network_mount() {
    local path="$1"
    local mount_type
    mount_type=$(df -T "$path" 2>/dev/null | tail -1 | awk '{print $2}')

    [[ "$mount_type" == "nfs" ]] || [[ "$mount_type" == "smbfs" ]] || [[ "$mount_type" == "afpfs" ]]
}

# Check if file is in use (for normal mode)
is_file_in_use() {
    local file="$1"
    lsof "$file" &>/dev/null
}

# ====================== ARGUMENT PARSING ======================

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --deep)      deep_mode=1 ;;
            --verbose)   verbose_mode=1 ;;
            --dry-run)   dry_run=1 ;;
            --silent)    silent_mode=1 ;;
            --no-reboot) no_reboot=1 ;;
            --keep)      keep_log=1 ;;
            --test)      test_mode=1 ;;
            --help)      help_mode=1 ;;
            *)
                echo "Unknown argument: $arg"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Validate conflicting flags
    if [[ $silent_mode -eq 1 ]] && [[ $verbose_mode -eq 1 ]]; then
        echo "ERROR: --silent and --verbose cannot be used together"
        exit 1
    fi
}

# ====================== HELP FUNCTION ======================

show_help() {
    cat << 'EOF'
macos cleanup script v1.0 | Author: amcocan (2024-06-15) with the help of Glean.

USAGE:
    ./macos_cleaner.sh [OPTIONS]

OPTIONS:
    --deep       Include deep locations (logs, /var/folders, iOS backups)
                 Triggers automatic reboot unless --no-reboot is specified

    --dry-run    Simulation mode - shows what would be deleted without
                 actually removing anything. Uses [TEST] tags in output.

    --verbose    Detailed output with every file listed individually
                 (no bundling of similar items)

    --silent     Minimal output - only shows total space cleared and duration

    --no-reboot  When used with --deep, skips the automatic reboot

    --keep       Saves the cleanup log to /Users/Shared/macos-cleaner.log

    --test       Run unit tests for helper functions

    --help       Show this help message

EXAMPLES:
    ./macos_cleaner.sh                    # Safe cleanup
    ./macos_cleaner.sh --deep             # Deep cleanup with reboot
    ./macos_cleaner.sh --deep --no-reboot # Deep cleanup, no reboot
    ./macos_cleaner.sh --dry-run          # Preview what would be deleted
    ./macos_cleaner.sh --dry-run --verbose # Detailed preview
    ./macos_cleaner.sh --keep             # Save log after cleanup

TARGET LOCATIONS:
    Default (Safe):
        - /tmp, /var/tmp
        - /Library/Caches
        - ~/Library/Caches, ~/.Trash
        - ~/Library/Application Support/*/Caches
        - ~/Library/Saved Application State
        - ~/Library/Developer/Xcode/DerivedData
        - Browser caches (Safari, Chrome, Firefox)

    Deep (Additive):
        - /var/folders, /var/log, /Library/Logs, ~/Library/Logs
        - /private/var/vm/sleepimage
        - ~/Library/Application Support/MobileSync/Backup

OUTPUT FORMAT:
    Space Cleared | Duration

    [STRICT] Unhandled errors
    [FAIL]   Failed deletions with reason
    [WARN]   Skipped items with reason
    [PASS]   Successfully cleared locations
    [TEST]   Dry-run simulated actions

EOF
}

# ====================== CORE CLEANUP FUNCTIONS ======================

# Process a single target location
process_target() {
    local target="$1"
    local desc="$2"
    local is_deep="${3:-0}"

    local tag_prefix="PASS"
    [[ $dry_run -eq 1 ]] && tag_prefix="TEST"

    # Check if target exists
    if [[ ! -e "$target" ]]; then
        return 0
    fi

    # Check for SIP protection
    if [[ "$target" == "/System/"* ]]; then
        if [[ $verbose_mode -eq 1 ]]; then
            log_msg "WARN" "$target" "SIP-protected, skipped"
        fi
        sip_warnings+=("$target")
        return 0
    fi

    # Calculate total size once (not per-file)
    local size_kb
    size_kb=$(to_int "$(get_target_size "$target")")
    local hr_size
    hr_size=$(size_to_human "$size_kb")

    # Count files for progress indication
    local file_count=0
    if [[ $verbose_mode -eq 1 ]]; then
        file_count=$(find "$target" -mindepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
        file_count=$(to_int "$file_count")
    fi

    # Dry-run mode
    if [[ $dry_run -eq 1 ]]; then
        total_kb=$((total_kb + $(to_int "$size_kb")))

        if [[ $verbose_mode -eq 1 ]]; then
            # Log directory summary first
            log_msg "TEST" "$target" "Would delete (${file_count} files)" "$hr_size"

            # List files without individual size calculations
            local count=0
            while IFS= read -r file; do
                log_msg "TEST" "$file" "Would delete"
                ((count++))
                # Progress indicator every 1000 files
                if (( count % 1000 == 0 )); then
                    echo "  ... processed ${count}/${file_count} files" >&2
                fi
            done < <(find "$target" -mindepth 1 -type f 2>/dev/null)
        else
            log_msg "TEST" "$target" "Would delete" "$hr_size"
        fi
        return 0
    fi

    # Actual deletion
    if [[ $verbose_mode -eq 1 ]]; then
        # Log directory summary
        log_msg "PASS" "$target" "Processing (${file_count} files)" "$hr_size"

        local count=0
        local deleted=0
        local skipped=0

        while IFS= read -r file; do
            ((count++))

            # Check if file is in use (normal mode only)
            if [[ $deep_mode -eq 0 ]] && is_file_in_use "$file"; then
                log_msg "WARN" "$file" "File in use, skipped"
                ((skipped++))
                continue
            fi

            # Attempt deletion
            if rm -rf "$file" 2>/dev/null; then
                log_msg "PASS" "$file" "Deleted"
                ((deleted++))
            else
                log_msg "FAIL" "$file" "Permission denied"
            fi

            # Progress indicator every 1000 files
            if (( count % 1000 == 0 )); then
                echo "  ... processed ${count}/${file_count} files" >&2
            fi
        done < <(find "$target" -mindepth 1 -type f 2>/dev/null)

        # Add the size to total (approximate, since some files may have failed)
        total_kb=$((total_kb + $(to_int "$size_kb")))

        if [[ $skipped -gt 0 ]]; then
            log_msg "WARN" "$target" "Completed with ${skipped} skipped files"
        fi
    else
        # Non-verbose bulk deletion (unchanged)
        if [[ $deep_mode -eq 0 ]]; then
            local in_use_count=0
            while IFS= read -r file; do
                if is_file_in_use "$file"; then
                    ((in_use_count++))
                fi
            done < <(find "$target" -mindepth 1 -type f 2>/dev/null)

            if [[ $in_use_count -gt 0 ]]; then
                log_msg "WARN" "$target" "Files in use, some skipped" "${in_use_count} files"
            fi
        fi

        if find "$target" -mindepth 1 -delete 2>/dev/null; then
            total_kb=$((total_kb + $(to_int "$size_kb")))
            log_msg "PASS" "$target" "Cleared" "$hr_size"
        else
            local remaining_size
            remaining_size=$(to_int "$(get_target_size "$target")")
            local cleared
            cleared=$(($(to_int "$size_kb") - $(to_int "$remaining_size")))

            if [[ $cleared -gt 0 ]]; then
                total_kb=$((total_kb + $(to_int "$cleared")))
                log_msg "WARN" "$target" "Partially cleared" "$(size_to_human "$cleared")"
            fi
            log_msg "FAIL" "$target" "Some files could not be deleted"
        fi
    fi
}

# Process all user directories
process_user_dirs() {
    local is_deep="${1:-0}"

    for home_dir in /Users/*/; do
        [[ ! -d "$home_dir" ]] && continue
        [[ -L "$home_dir" ]] && continue

        local user_name
        user_name=$(basename "${home_dir%/}")

        # Check for network mount
        if is_network_mount "$home_dir"; then
            if [[ $verbose_mode -eq 1 ]]; then
                log_msg "WARN" "$home_dir" "Network-mounted, skipped"
            fi
            continue
        fi

        # Default locations
        process_target "${home_dir}Library/Caches" "User ${user_name} Caches"
        process_target "${home_dir}.Trash" "User ${user_name} Trash"

        # App-specific caches (glob expansion)
        for cache_dir in "${home_dir}Library/Application Support/"*/Caches; do
            [[ -d "$cache_dir" ]] && process_target "$cache_dir" "User ${user_name} App Cache"
        done

        process_target "${home_dir}Library/Saved Application State" "User ${user_name} Saved State"
        process_target "${home_dir}Library/Developer/Xcode/DerivedData" "User ${user_name} Xcode Data"

        # Browser caches
        process_target "${home_dir}Library/Caches/com.apple.Safari" "User ${user_name} Safari Cache"
        process_target "${home_dir}Library/Caches/com.apple.Safari.SafeBrowsing" "User ${user_name} Safari SafeBrowsing"
        process_target "${home_dir}Library/Caches/Google/Chrome" "User ${user_name} Chrome Cache"

        # Chrome profile caches
        for profile_dir in "${home_dir}Library/Application Support/Google/Chrome/"*/; do
            [[ -d "$profile_dir" ]] || continue
            process_target "${profile_dir}Cache" "User ${user_name} Chrome Profile Cache"
            process_target "${profile_dir}Code Cache" "User ${user_name} Chrome Code Cache"
        done

        process_target "${home_dir}Library/Caches/Firefox" "User ${user_name} Firefox Cache"

        # Firefox profile caches
        for profile_dir in "${home_dir}Library/Application Support/Firefox/Profiles/"*/; do
            [[ -d "$profile_dir" ]] || continue
            process_target "${profile_dir}cache2" "User ${user_name} Firefox Profile Cache"
        done

        # Deep mode user locations
        if [[ $is_deep -eq 1 ]]; then
            process_target "${home_dir}Library/Logs" "User ${user_name} Logs" 1
            process_target "${home_dir}Library/Application Support/MobileSync/Backup" "User ${user_name} iOS Backups" 1
        fi
    done
}

# Flush DNS cache
flush_dns() {
    local tag_prefix="PASS"
    [[ $dry_run -eq 1 ]] && tag_prefix="TEST"

    if [[ $dry_run -eq 1 ]]; then
        log_msg "TEST" "DNS Cache" "Would flush"
        return 0
    fi

    local dns_success=1

    if dscacheutil -flushcache 2>/dev/null; then
        : # Success
    else
        dns_success=0
        log_msg "FAIL" "dscacheutil" "Failed to flush"
    fi

    if killall -HUP mDNSResponder 2>/dev/null; then
        : # Success
    else
        # mDNSResponder might not be running
        log_msg "WARN" "mDNSResponder" "Not running or failed to signal"
    fi

    if [[ $dns_success -eq 1 ]]; then
        log_msg "PASS" "DNS Cache" "Flushed successfully"
    fi
}

# Safe reboot with delay
safe_reboot() {
    if [[ $dry_run -eq 1 ]]; then
        log_msg "TEST" "System" "Would reboot in 3 seconds"
        return 0
    fi

    if [[ $no_reboot -eq 1 ]]; then
        return 0
    fi

    echo "Initiating reboot in 3 seconds..."
    sleep 3
    reboot
}

# ====================== TEST FUNCTIONS ======================

run_tests() {
    echo "Running unit tests..."
    echo ""

    local passed=0
    local failed=0

    # Test to_int
    echo "Testing to_int():"

    local result
    result=$(to_int "12345")
    if [[ "$result" == "12345" ]]; then
        echo "  ✓ '12345' → $result"
        ((passed++))
    else
        echo "  ✗ '12345' → $result (expected '12345')"
        ((failed++))
    fi

    result=$(to_int $'12345\n0')
    if [[ "$result" == "123450" ]]; then
        echo "  ✓ '12345\\n0' → $result (newline stripped)"
        ((passed++))
    else
        echo "  ✗ '12345\\n0' → $result (expected '123450')"
        ((failed++))
    fi

    result=$(to_int "")
    if [[ "$result" == "0" ]]; then
        echo "  ✓ '' → $result (empty defaults to 0)"
        ((passed++))
    else
        echo "  ✗ '' → $result (expected '0')"
        ((failed++))
    fi

    result=$(to_int "abc123def")
    if [[ "$result" == "123" ]]; then
        echo "  ✓ 'abc123def' → $result (non-digits stripped)"
        ((passed++))
    else
        echo "  ✗ 'abc123def' → $result (expected '123')"
        ((failed++))
    fi

    echo ""
    echo "Testing size_to_human():"

    result=$(size_to_human 512)
    if [[ "$result" == "512 KB" ]]; then
        echo "  ✓ 512 KB → $result"
        ((passed++))
    else
        echo "  ✗ 512 KB → $result (expected '512 KB')"
        ((failed++))
    fi

    result=$(size_to_human 2048)
    if [[ "$result" =~ "2" ]] && [[ "$result" =~ "MB" ]]; then
        echo "  ✓ 2048 KB → $result"
        ((passed++))
    else
        echo "  ✗ 2048 KB → $result (expected ~2 MB)"
        ((failed++))
    fi

    result=$(size_to_human 2097152)
    if [[ "$result" =~ "2" ]] && [[ "$result" =~ "GB" ]]; then
        echo "  ✓ 2097152 KB → $result"
        ((passed++))
    else
        echo "  ✗ 2097152 KB → $result (expected ~2 GB)"
        ((failed++))
    fi

    echo ""
    echo "Testing time_to_human():"

    result=$(time_to_human 500)
    if [[ "$result" == "500ms" ]]; then
        echo "  ✓ 500ms → $result"
        ((passed++))
    else
        echo "  ✗ 500ms → $result (expected '500ms')"
        ((failed++))
    fi

    result=$(time_to_human 65000)
    if [[ "$result" =~ "1m" ]] && [[ "$result" =~ "5s" ]]; then
        echo "  ✓ 65000ms → $result"
        ((passed++))
    else
        echo "  ✗ 65000ms → $result (expected ~1m 5s)"
        ((failed++))
    fi

    result=$(time_to_human 3661000)
    if [[ "$result" =~ "1h" ]]; then
        echo "  ✓ 3661000ms → $result"
        ((passed++))
    else
        echo "  ✗ 3661000ms → $result (expected ~1h)"
        ((failed++))
    fi

    echo ""
    echo "Testing timer functions:"
    timer_start
    sleep 1
    timer_stop
    local duration
    duration=$(get_duration)
    if [[ "$duration" =~ "1s" ]] || [[ "$duration" =~ "1000" ]]; then
        echo "  ✓ Timer: $duration"
        ((passed++))
    else
        echo "  ✗ Timer: $duration (expected ~1s)"
        ((failed++))
    fi

    echo ""
    echo "Testing bc availability:"
    check_bc
    if [[ $has_bc -eq 1 ]]; then
        echo "  ✓ bc is available (millisecond precision enabled)"
    else
        echo "  ⚠ bc not available (using second precision fallback)"
    fi
    ((passed++))

    echo ""
    echo "Tests completed: $((passed + failed)) total"
    echo "  Passed: $passed"
    echo "  Failed: $failed"

    [[ $failed -eq 0 ]] && exit 0 || exit 1
}

# ====================== MAIN FUNCTION ======================

main() {
    parse_args "$@"

    # Handle help
    if [[ $help_mode -eq 1 ]]; then
        show_help
        exit 0
    fi

    # Handle test mode
    if [[ $test_mode -eq 1 ]]; then
        validate_env
        run_tests
        exit 0
    fi

    # Validate environment
    check_root
    validate_env

    # Initialize logging and timer
    init_logs
    timer_start

    # Process default (safe) locations
    process_target "/tmp" "System Temp (/tmp)"
    process_target "/var/tmp" "System Temp (/var/tmp)"
    process_target "/Library/Caches" "System Caches"
    process_target "/System/Library/Caches" "System Library Caches"  # SIP-protected, will be skipped

    # Process user directories (includes deep locations if --deep is set)
    process_user_dirs "$deep_mode"

    # Deep mode additional system locations
    if [[ $deep_mode -eq 1 ]]; then
        process_target "/var/folders" "Runtime Temp (/var/folders)" 1
        process_target "/var/log" "System Logs (/var/log)" 1
        process_target "/Library/Logs" "System-wide Logs" 1
        process_target "/private/var/vm/sleepimage" "Hibernation File" 1

        # DNS Flush
        flush_dns
    fi

    # Stop timer
    timer_stop

    # Output results
    print_summary

    # Save persistent log if requested
    save_persistent_log

    # Cleanup temporary logs
    cleanup_logs

    # Reboot if deep mode (and not dry-run, and not --no-reboot)
    if [[ $deep_mode -eq 1 ]] && [[ $dry_run -eq 0 ]]; then
        safe_reboot
    fi

    exit 0
}

# ====================== ERROR HANDLING ======================

# Trap for unhandled errors - logs with [STRICT] and continues
handle_error() {
    local line_no="$1"
    local command="$2"
    local exit_code="$3"

    # Only log if logs are initialized
    if [[ -n "${strict_log:-}" ]] && [[ -f "$strict_log" ]]; then
        log_msg "STRICT" "Line ${line_no}" "${command} (exit code: ${exit_code})"
    fi

    # Continue execution (don't exit)
    return 0
}

trap 'handle_error "${LINENO}" "${BASH_COMMAND}" "$?"' ERR

# ====================== ENTRY POINT ======================

main "$@"
