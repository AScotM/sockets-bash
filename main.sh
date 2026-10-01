#!/usr/bin/env bash

VERSION="2.0.0"

SOCKSTAT_PATH="/proc/net/sockstat"
SOCKSTAT6_PATH="/proc/net/sockstat6"

JSON_OUTPUT=0
EXTENDED=0
SHOW_PERFORMANCE=0
QUIET=0
WATCH_INTERVAL=""
OUTPUT_FILE=""

declare -A STATS

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

show_version() {
    printf 'Socket Statistics Tool %s\n' "$VERSION"
    printf 'Bash %s\n' "$BASH_VERSION"
}

show_help() {
    cat <<EOF
Socket Statistics Tool $VERSION

Usage:
  $(basename "$0") [OPTIONS]

Options:
  --json
      Output statistics as JSON

  --extended
      Include UNIX, Netlink, Packet and protocol table counts

  --performance
      Show execution-time information

  --watch SECONDS
      Continuously refresh statistics

  --path FILE
      Use an alternative IPv4 sockstat file

  --path6 FILE
      Use an alternative IPv6 sockstat file

  --output FILE
      Write output to a file

  --quiet
      Suppress normal terminal output

  --version
      Show version

  --help
      Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --extended
  $(basename "$0") --json
  $(basename "$0") --json --extended
  $(basename "$0") --performance
  $(basename "$0") --watch 2
  $(basename "$0") --extended --watch 1
  $(basename "$0") --json --output sockets.json
EOF
}

require_argument() {
    local option="$1"
    local value="${2-}"

    [[ -n "$value" ]] || die "$option requires an argument"
}

is_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_number() {
    [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || return 1

    awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

json_escape() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}

    printf '%s' "$value"
}

reset_stats() {
    STATS=(
        ["sockets_used"]=0
        ["tcp_in_use"]=0
        ["tcp_orphan"]=0
        ["tcp_time_wait"]=0
        ["tcp_allocated"]=0
        ["tcp_memory"]=0
        ["udp_in_use"]=0
        ["udp_memory"]=0
        ["udplite_in_use"]=0
        ["raw_in_use"]=0
        ["frag_in_use"]=0
        ["frag_memory"]=0
        ["tcp6_in_use"]=0
        ["udp6_in_use"]=0
        ["udplite6_in_use"]=0
        ["raw6_in_use"]=0
        ["frag6_in_use"]=0
        ["frag6_memory"]=0
        ["unix_count"]=0
        ["netlink_count"]=0
        ["packet_count"]=0
        ["tcp_entries"]=0
        ["tcp6_entries"]=0
        ["udp_entries"]=0
        ["udp6_entries"]=0
    )
}

check_readable_file() {
    local path="$1"
    local description="$2"

    [[ -e "$path" ]] || die "$description '$path' does not exist"
    [[ ! -d "$path" ]] || die "$description '$path' is a directory"
    [[ -r "$path" ]] || die "$description '$path' is not readable"
}

set_stat() {
    local key="$1"
    local value="$2"

    if is_nonnegative_integer "$value"; then
        STATS["$key"]="$value"
    fi
}

parse_key_value_line() {
    local prefix="$1"
    shift

    local -a fields=("$@")
    local index
    local key
    local value

    for ((index = 0; index + 1 < ${#fields[@]}; index += 2)); do
        key="${fields[index]}"
        value="${fields[index + 1]}"

        case "${prefix}:${key}" in
            tcp:inuse)
                set_stat "tcp_in_use" "$value"
                ;;
            tcp:orphan)
                set_stat "tcp_orphan" "$value"
                ;;
            tcp:tw)
                set_stat "tcp_time_wait" "$value"
                ;;
            tcp:alloc)
                set_stat "tcp_allocated" "$value"
                ;;
            tcp:mem)
                set_stat "tcp_memory" "$value"
                ;;
            udp:inuse)
                set_stat "udp_in_use" "$value"
                ;;
            udp:mem)
                set_stat "udp_memory" "$value"
                ;;
            udplite:inuse)
                set_stat "udplite_in_use" "$value"
                ;;
            raw:inuse)
                set_stat "raw_in_use" "$value"
                ;;
            frag:inuse)
                set_stat "frag_in_use" "$value"
                ;;
            frag:memory)
                set_stat "frag_memory" "$value"
                ;;
            tcp6:inuse)
                set_stat "tcp6_in_use" "$value"
                ;;
            udp6:inuse)
                set_stat "udp6_in_use" "$value"
                ;;
            udplite6:inuse)
                set_stat "udplite6_in_use" "$value"
                ;;
            raw6:inuse)
                set_stat "raw6_in_use" "$value"
                ;;
            frag6:inuse)
                set_stat "frag6_in_use" "$value"
                ;;
            frag6:memory)
                set_stat "frag6_memory" "$value"
                ;;
        esac
    done
}

parse_sockstat_file() {
    local path="$1"
    local ipv6="$2"

    local line
    local section
    local -a fields

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue

        read -r -a fields <<< "$line"

        [[ ${#fields[@]} -gt 0 ]] || continue

        section="${fields[0]}"
        section="${section%:}"

        case "$section" in
            sockets)
                if [[ "$ipv6" -eq 0 ]] &&
                   [[ ${#fields[@]} -ge 3 ]] &&
                   [[ "${fields[1]}" == "used" ]]; then
                    set_stat "sockets_used" "${fields[2]}"
                fi
                ;;
            TCP)
                if [[ "$ipv6" -eq 0 ]]; then
                    parse_key_value_line "tcp" "${fields[@]:1}"
                else
                    parse_key_value_line "tcp6" "${fields[@]:1}"
                fi
                ;;
            TCP6)
                parse_key_value_line "tcp6" "${fields[@]:1}"
                ;;
            UDP)
                if [[ "$ipv6" -eq 0 ]]; then
                    parse_key_value_line "udp" "${fields[@]:1}"
                else
                    parse_key_value_line "udp6" "${fields[@]:1}"
                fi
                ;;
            UDP6)
                parse_key_value_line "udp6" "${fields[@]:1}"
                ;;
            UDPLITE)
                if [[ "$ipv6" -eq 0 ]]; then
                    parse_key_value_line "udplite" "${fields[@]:1}"
                else
                    parse_key_value_line "udplite6" "${fields[@]:1}"
                fi
                ;;
            UDPLITE6)
                parse_key_value_line "udplite6" "${fields[@]:1}"
                ;;
            RAW)
                if [[ "$ipv6" -eq 0 ]]; then
                    parse_key_value_line "raw" "${fields[@]:1}"
                else
                    parse_key_value_line "raw6" "${fields[@]:1}"
                fi
                ;;
            RAW6)
                parse_key_value_line "raw6" "${fields[@]:1}"
                ;;
            FRAG)
                if [[ "$ipv6" -eq 0 ]]; then
                    parse_key_value_line "frag" "${fields[@]:1}"
                else
                    parse_key_value_line "frag6" "${fields[@]:1}"
                fi
                ;;
            FRAG6)
                parse_key_value_line "frag6" "${fields[@]:1}"
                ;;
        esac
    done < "$path"
}

count_table_entries() {
    local path="$1"
    local count=0
    local line

    if [[ ! -r "$path" ]]; then
        printf '0'
        return
    fi

    {
        IFS= read -r line || true

        while IFS= read -r line; do
            [[ -n "$line" ]] && ((count++))
        done
    } < "$path"

    printf '%d' "$count"
}

load_extended_stats() {
    STATS["unix_count"]="$(count_table_entries "/proc/net/unix")"
    STATS["netlink_count"]="$(count_table_entries "/proc/net/netlink")"
    STATS["packet_count"]="$(count_table_entries "/proc/net/packet")"
    STATS["tcp_entries"]="$(count_table_entries "/proc/net/tcp")"
    STATS["tcp6_entries"]="$(count_table_entries "/proc/net/tcp6")"
    STATS["udp_entries"]="$(count_table_entries "/proc/net/udp")"
    STATS["udp6_entries"]="$(count_table_entries "/proc/net/udp6")"
}

collect_stats() {
    reset_stats

    check_readable_file "$SOCKSTAT_PATH" "Socket statistics file"

    parse_sockstat_file "$SOCKSTAT_PATH" 0

    if [[ -e "$SOCKSTAT6_PATH" ]]; then
        check_readable_file "$SOCKSTAT6_PATH" "IPv6 socket statistics file"
        parse_sockstat_file "$SOCKSTAT6_PATH" 1
    fi

    if [[ "$EXTENDED" -eq 1 ]]; then
        load_extended_stats
    fi
}

get_hostname() {
    hostname 2>/dev/null ||
        uname -n 2>/dev/null ||
        printf 'unknown'
}

get_timestamp() {
    date --iso-8601=seconds 2>/dev/null ||
        date '+%Y-%m-%dT%H:%M:%S%z'
}

generate_human_output() {
    local hostname_value
    local timestamp

    hostname_value="$(get_hostname)"
    timestamp="$(get_timestamp)"

    printf 'Socket Statistics\n'
    printf '=================\n'
    printf 'Generated: %s\n' "$timestamp"
    printf 'Hostname:  %s\n' "$hostname_value"
    printf 'Source:    %s\n' "$SOCKSTAT_PATH"

    if [[ -e "$SOCKSTAT6_PATH" ]]; then
        printf 'Source v6: %s\n' "$SOCKSTAT6_PATH"
    fi

    printf '\n'
    printf 'Sockets used: %s\n' "${STATS["sockets_used"]}"

    printf '\nTCP IPv4\n'
    printf '  In use:     %s\n' "${STATS["tcp_in_use"]}"
    printf '  Orphan:     %s\n' "${STATS["tcp_orphan"]}"
    printf '  Time wait:  %s\n' "${STATS["tcp_time_wait"]}"
    printf '  Allocated:  %s\n' "${STATS["tcp_allocated"]}"
    printf '  Memory:     %s pages\n' "${STATS["tcp_memory"]}"

    printf '\nTCP IPv6\n'
    printf '  In use:     %s\n' "${STATS["tcp6_in_use"]}"

    printf '\nUDP IPv4\n'
    printf '  In use:     %s\n' "${STATS["udp_in_use"]}"
    printf '  Memory:     %s pages\n' "${STATS["udp_memory"]}"

    printf '\nUDP IPv6\n'
    printf '  In use:     %s\n' "${STATS["udp6_in_use"]}"

    printf '\nUDPLite IPv4\n'
    printf '  In use:     %s\n' "${STATS["udplite_in_use"]}"

    printf '\nUDPLite IPv6\n'
    printf '  In use:     %s\n' "${STATS["udplite6_in_use"]}"

    printf '\nRAW IPv4\n'
    printf '  In use:     %s\n' "${STATS["raw_in_use"]}"

    printf '\nRAW IPv6\n'
    printf '  In use:     %s\n' "${STATS["raw6_in_use"]}"

    printf '\nFragment IPv4\n'
    printf '  In use:     %s\n' "${STATS["frag_in_use"]}"
    printf '  Memory:     %s\n' "${STATS["frag_memory"]}"

    printf '\nFragment IPv6\n'
    printf '  In use:     %s\n' "${STATS["frag6_in_use"]}"
    printf '  Memory:     %s\n' "${STATS["frag6_memory"]}"

    if [[ "$EXTENDED" -eq 1 ]]; then
        printf '\nExtended\n'
        printf '  UNIX sockets:     %s\n' "${STATS["unix_count"]}"
        printf '  Netlink sockets:  %s\n' "${STATS["netlink_count"]}"
        printf '  Packet sockets:   %s\n' "${STATS["packet_count"]}"
        printf '  TCP IPv4 entries: %s\n' "${STATS["tcp_entries"]}"
        printf '  TCP IPv6 entries: %s\n' "${STATS["tcp6_entries"]}"
        printf '  UDP IPv4 entries: %s\n' "${STATS["udp_entries"]}"
        printf '  UDP IPv6 entries: %s\n' "${STATS["udp6_entries"]}"
    fi
}

generate_json_output() {
    local hostname_value
    local timestamp
    local source
    local source6

    hostname_value="$(json_escape "$(get_hostname)")"
    timestamp="$(json_escape "$(get_timestamp)")"
    source="$(json_escape "$SOCKSTAT_PATH")"
    source6="$(json_escape "$SOCKSTAT6_PATH")"

    printf '{\n'
    printf '  "metadata": {\n'
    printf '    "version": "%s",\n' "$(json_escape "$VERSION")"
    printf '    "generated_at": "%s",\n' "$timestamp"
    printf '    "hostname": "%s",\n' "$hostname_value"
    printf '    "source": "%s",\n' "$source"
    printf '    "source6": "%s"\n' "$source6"
    printf '  },\n'
    printf '  "sockets": {\n'
    printf '    "used": %s\n' "${STATS["sockets_used"]}"
    printf '  },\n'
    printf '  "tcp": {\n'
    printf '    "ipv4": {\n'
    printf '      "in_use": %s,\n' "${STATS["tcp_in_use"]}"
    printf '      "orphan": %s,\n' "${STATS["tcp_orphan"]}"
    printf '      "time_wait": %s,\n' "${STATS["tcp_time_wait"]}"
    printf '      "allocated": %s,\n' "${STATS["tcp_allocated"]}"
    printf '      "memory_pages": %s\n' "${STATS["tcp_memory"]}"
    printf '    },\n'
    printf '    "ipv6": {\n'
    printf '      "in_use": %s\n' "${STATS["tcp6_in_use"]}"
    printf '    }\n'
    printf '  },\n'
    printf '  "udp": {\n'
    printf '    "ipv4": {\n'
    printf '      "in_use": %s,\n' "${STATS["udp_in_use"]}"
    printf '      "memory_pages": %s\n' "${STATS["udp_memory"]}"
    printf '    },\n'
    printf '    "ipv6": {\n'
    printf '      "in_use": %s\n' "${STATS["udp6_in_use"]}"
    printf '    }\n'
    printf '  },\n'
    printf '  "udplite": {\n'
    printf '    "ipv4": {\n'
    printf '      "in_use": %s\n' "${STATS["udplite_in_use"]}"
    printf '    },\n'
    printf '    "ipv6": {\n'
    printf '      "in_use": %s\n' "${STATS["udplite6_in_use"]}"
    printf '    }\n'
    printf '  },\n'
    printf '  "raw": {\n'
    printf '    "ipv4": {\n'
    printf '      "in_use": %s\n' "${STATS["raw_in_use"]}"
    printf '    },\n'
    printf '    "ipv6": {\n'
    printf '      "in_use": %s\n' "${STATS["raw6_in_use"]}"
    printf '    }\n'
    printf '  },\n'
    printf '  "fragment": {\n'
    printf '    "ipv4": {\n'
    printf '      "in_use": %s,\n' "${STATS["frag_in_use"]}"
    printf '      "memory": %s\n' "${STATS["frag_memory"]}"
    printf '    },\n'
    printf '    "ipv6": {\n'
    printf '      "in_use": %s,\n' "${STATS["frag6_in_use"]}"
    printf '      "memory": %s\n' "${STATS["frag6_memory"]}"
    printf '    }\n'
    printf '  }'

    if [[ "$EXTENDED" -eq 1 ]]; then
        printf ',\n'
        printf '  "extended": {\n'
        printf '    "unix_sockets": %s,\n' "${STATS["unix_count"]}"
        printf '    "netlink_sockets": %s,\n' "${STATS["netlink_count"]}"
        printf '    "packet_sockets": %s,\n' "${STATS["packet_count"]}"
        printf '    "protocol_tables": {\n'
        printf '      "tcp_ipv4": %s,\n' "${STATS["tcp_entries"]}"
        printf '      "tcp_ipv6": %s,\n' "${STATS["tcp6_entries"]}"
        printf '      "udp_ipv4": %s,\n' "${STATS["udp_entries"]}"
        printf '      "udp_ipv6": %s\n' "${STATS["udp6_entries"]}"
        printf '    }\n'
        printf '  }'
    fi

    printf '\n}\n'
}

generate_output() {
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        generate_json_output
    else
        generate_human_output
    fi
}

write_output() {
    local output="$1"

    if [[ -n "$OUTPUT_FILE" ]]; then
        local directory

        directory="$(dirname -- "$OUTPUT_FILE")"

        [[ -d "$directory" ]] ||
            die "output directory '$directory' does not exist"

        printf '%s\n' "$output" > "$OUTPUT_FILE" ||
            die "cannot write to '$OUTPUT_FILE'"
    fi

    if [[ "$QUIET" -eq 0 ]]; then
        printf '%s\n' "$output"
    fi
}

now_nanoseconds() {
    date +%s%N 2>/dev/null || printf '0'
}

show_performance() {
    local start_ns="$1"
    local end_ns
    local elapsed_ns
    local seconds
    local milliseconds

    end_ns="$(now_nanoseconds)"

    if is_nonnegative_integer "$start_ns" &&
       is_nonnegative_integer "$end_ns" &&
       [[ "$start_ns" -gt 0 ]] &&
       [[ "$end_ns" -ge "$start_ns" ]]; then

        elapsed_ns=$((end_ns - start_ns))
        seconds=$((elapsed_ns / 1000000000))
        milliseconds=$(((elapsed_ns % 1000000000) / 1000000))

        printf 'Performance\n'
        printf '===========\n'
        printf 'Execution time: %d.%03d seconds\n' "$seconds" "$milliseconds"
    else
        printf 'Performance\n'
        printf '===========\n'
        printf 'Execution time unavailable\n'
    fi
}

clear_screen() {
    if [[ -t 1 ]]; then
        printf '\033[H\033[2J'
    fi
}

run_once() {
    local start_ns
    local output

    start_ns="$(now_nanoseconds)"

    collect_stats
    output="$(generate_output)"

    write_output "$output"

    if [[ "$SHOW_PERFORMANCE" -eq 1 ]] &&
       [[ "$QUIET" -eq 0 ]] &&
       [[ "$JSON_OUTPUT" -eq 0 ]]; then
        printf '\n'
        show_performance "$start_ns"
    fi
}

run_watch() {
    while true; do
        clear_screen
        run_once
        sleep "$WATCH_INTERVAL"
    done
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                JSON_OUTPUT=1
                shift
                ;;
            --extended)
                EXTENDED=1
                shift
                ;;
            --performance)
                SHOW_PERFORMANCE=1
                shift
                ;;
            --quiet)
                QUIET=1
                shift
                ;;
            --watch)
                require_argument "$1" "${2-}"

                is_positive_number "$2" ||
                    die "--watch requires a positive number of seconds"

                WATCH_INTERVAL="$2"
                shift 2
                ;;
            --path)
                require_argument "$1" "${2-}"
                SOCKSTAT_PATH="$2"
                shift 2
                ;;
            --path6)
                require_argument "$1" "${2-}"
                SOCKSTAT6_PATH="$2"
                shift 2
                ;;
            --output)
                require_argument "$1" "${2-}"
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --version)
                show_version
                exit 0
                ;;
            --help)
                show_help
                exit 0
                ;;
            --)
                shift

                [[ $# -eq 0 ]] ||
                    die "unexpected positional argument '$1'"

                break
                ;;
            -*)
                die "unknown option '$1'"
                ;;
            *)
                die "unexpected positional argument '$1'"
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"

    if [[ "$JSON_OUTPUT" -eq 1 ]] &&
       [[ "$SHOW_PERFORMANCE" -eq 1 ]]; then
        die "--performance cannot currently be combined with --json"
    fi

    if [[ -n "$WATCH_INTERVAL" ]] &&
       [[ -n "$OUTPUT_FILE" ]]; then
        die "--watch cannot be combined with --output"
    fi

    if [[ -n "$WATCH_INTERVAL" ]]; then
        trap 'printf "\n"; exit 0' INT TERM
        run_watch
    else
        run_once
    fi
}

main "$@"
