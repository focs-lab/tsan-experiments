#!/usr/bin/env python3

from collections import Counter
import sys

MULTI_THREAD = -1
BYTE_STATS_FLAG = "--byte-stats"
SKIP_BYTE_STATS_FLAG = "--skip-byte-stats"
MALFORMED_LINE_EXAMPLES_LIMIT = 5


def parse_non_negative_int(value: str, base: int = 10) -> int | None:
    try:
        parsed = int(value, base)
    except ValueError:
        return None

    if parsed < 0:
        return None

    return parsed


def parse_trace_line(line: str) -> tuple[tuple[str, int, int, int] | None, str | None]:
    parts = line.split()

    if not parts:
        return None, "empty trace line"

    if parts[0] != ">":
        return None, "missing trace marker"

    if len(parts) == 5:
        _, pointer_text, size_text, access_type, thread_text = parts
    elif len(parts) == 6:
        _, access_type, pointer_text, size_text, thread_text, _ = parts
    else:
        return None, f"unexpected field count ({len(parts)})"

    pointer = parse_non_negative_int(pointer_text, 16)
    if pointer is None:
        return None, "invalid pointer"

    size = parse_non_negative_int(size_text)
    if size is None:
        return None, "invalid size"

    thread = parse_non_negative_int(thread_text)
    if thread is None:
        return None, "invalid thread"

    return (access_type, pointer, size, thread), None


def ratio(part: int, total: int) -> float:
    return round(100 * part / total, 2) if total else 0.0


def update_thread_state(states: dict[int, int], pointer: int, thread_id: int) -> tuple[bool, int]:
    state = states.get(pointer)

    if state is None:
        states[pointer] = thread_id
        return False, 0

    if state == MULTI_THREAD:
        return False, 1

    if state == thread_id:
        return False, 0

    states[pointer] = MULTI_THREAD
    return True, 2


def print_byte_stats_skipped() -> None:
    print()
    print("Unique addresses (byte):   skipped")
    print("Accesses (byte):           skipped")
    print()
    print("Addresses with multi-threaded access (byte):   skipped")
    print("Multi-threaded accesses (byte):                skipped")


def print_trace_accounting(access_total: int, trace_lines: int, malformed_trace_lines: int) -> None:
    valid_trace_lines = trace_lines - malformed_trace_lines
    access_delta = access_total - valid_trace_lines
    trace_delta = trace_lines - (valid_trace_lines + malformed_trace_lines)

    print("Valid trace lines:         " + str(valid_trace_lines))
    print("Rejected trace lines:      " + str(malformed_trace_lines))

    if access_delta == 0:
        print("Access accounting:         ok (Accesses == valid trace lines)")
    else:
        print(f"Access accounting:         mismatch (Accesses - valid trace lines = {access_delta})")

    if trace_delta == 0:
        print("Trace line accounting:     ok (seen == valid + rejected)")
    else:
        print(f"Trace line accounting:     mismatch (seen - (valid + rejected) = {trace_delta})")


def print_malformed_line_stats(
    total_lines: int,
    trace_lines: int,
    non_trace_lines: int,
    malformed_trace_lines: int,
    malformed_reasons: Counter[str],
    malformed_examples: list[tuple[int, str, str]],
) -> None:
    print()
    print("Input lines:                " + str(total_lines))
    print("Trace lines seen:           " + str(trace_lines))
    print("Ignored non-trace lines:    " + str(non_trace_lines))

    malformed_ratio = ratio(malformed_trace_lines, trace_lines)
    print(f"Malformed trace lines:      {str(malformed_trace_lines).ljust(10)} ({malformed_ratio}% of trace lines)")

    if not malformed_trace_lines:
        return

    print()
    print("Malformed trace line reasons:")
    for reason, count in malformed_reasons.most_common():
        print(f"  - {reason}: {count}")

    if not malformed_examples:
        return

    print()
    print("Malformed trace line examples:")
    for line_number, reason, example in malformed_examples:
        print(f"  - line {line_number} ({reason}): {example}")


def main() -> None:

    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in (BYTE_STATS_FLAG, SKIP_BYTE_STATS_FLAG)):
        print(f"Usage: trace-analyze2.py <file> [{BYTE_STATS_FLAG}|{SKIP_BYTE_STATS_FLAG}]")
        exit(1)

    log_file = sys.argv[1]
    byte_stats_enabled = len(sys.argv) == 3 and sys.argv[2] == BYTE_STATS_FLAG

    print("Analyzing " + log_file)

    access_types = set()
    pointer_states: dict[int, int] = {}
    byte_pointer_states: dict[int, int] | None = {} if byte_stats_enabled else None
    thread_ids: dict[int, int] = {}

    access_multi = 0
    access_total = 0
    pointers_multi = 0

    access_multi_byte = 0
    access_total_byte = 0
    pointers_multi_byte = 0

    total_lines = 0
    trace_lines = 0
    non_trace_lines = 0
    malformed_trace_lines = 0
    malformed_reasons: Counter[str] = Counter()
    malformed_examples: list[tuple[int, str, str]] = []

    with open(log_file, encoding="utf-8", errors="replace") as log:
        for line_number, line in enumerate(log, start=1):
            total_lines += 1

            if not line.startswith(" > "):
                non_trace_lines += 1
                continue

            trace_lines += 1

            parsed, error = parse_trace_line(line)
            if parsed is None:
                malformed_trace_lines += 1
                malformed_reasons[error or "unknown parse error"] += 1

                if len(malformed_examples) < MALFORMED_LINE_EXAMPLES_LIMIT:
                    malformed_examples.append((line_number, error or "unknown parse error", line.rstrip()))

                continue

            access_type, pointer, size, thread = parsed

            access_types.add(access_type)

            thread_id = thread_ids.get(thread)
            if thread_id is None:
                thread_id = len(thread_ids) + 1
                thread_ids[thread] = thread_id

            became_multi, multi_increment = update_thread_state(pointer_states, pointer, thread_id)
            if became_multi:
                pointers_multi += 1
            access_multi += multi_increment
            access_total += 1

            if byte_pointer_states is not None:
                access_total_byte += size

                for byte_pointer in range(pointer, pointer + size):
                    became_multi_byte, multi_increment_byte = update_thread_state(byte_pointer_states, byte_pointer, thread_id)
                    if became_multi_byte:
                        pointers_multi_byte += 1
                    access_multi_byte += multi_increment_byte

    print()
    print("Access types:              " + " ".join(sorted(access_types)))
    print("Threads:                   " + str(len(thread_ids)))
    print()
    print("Unique addresses:          " + str(len(pointer_states)))
    print("Accesses:                  " + str(access_total))
    print_trace_accounting(access_total, trace_lines, malformed_trace_lines)

    if byte_pointer_states is not None:
        print()
        print("Unique addresses (byte):   " + str(len(byte_pointer_states)))
        print("Accesses (byte):           " + str(access_total_byte))

    pointers_multi_ratio = ratio(pointers_multi, len(pointer_states))
    access_multi_ratio = ratio(access_multi, access_total)

    print()
    print(f"Addresses with multi-threaded access:          {str(pointers_multi).ljust(10)} ({pointers_multi_ratio}% of total)")
    print(f"Multi-threaded accesses:                       {str(access_multi).ljust(10)} ({access_multi_ratio}% of total)")

    print_malformed_line_stats(
        total_lines,
        trace_lines,
        non_trace_lines,
        malformed_trace_lines,
        malformed_reasons,
        malformed_examples,
    )

    if byte_pointer_states is None:
        print_byte_stats_skipped()
        return

    pointers_multi_byte_ratio = ratio(pointers_multi_byte, len(byte_pointer_states))
    access_multi_byte_ratio = ratio(access_multi_byte, access_total_byte)

    print()
    print(f"Addresses with multi-threaded access (byte):   {str(pointers_multi_byte).ljust(10)} ({pointers_multi_byte_ratio}% of total)")
    print(f"Multi-threaded accesses (byte):                {str(access_multi_byte).ljust(10)} ({access_multi_byte_ratio}% of total)")


if __name__ == "__main__":
    main()
