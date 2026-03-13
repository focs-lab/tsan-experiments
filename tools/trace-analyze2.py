#!/usr/bin/env python3

import sys

MULTI_THREAD = -1
BYTE_STATS_FLAG = "--byte-stats"
SKIP_BYTE_STATS_FLAG = "--skip-byte-stats"


def parse_trace_line(line: str):
    parts = line.split()

    if len(parts) == 5 and parts[0] == ">":
        _, pointer, size, access_type, thread = parts
        return access_type, int(pointer, 16), int(size), thread

    if len(parts) == 6:
        _, operation, pointer, size, thread, _ = parts
        return operation, int(pointer, 16), int(size), thread

    return None


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


def main() -> None:

    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in (BYTE_STATS_FLAG, SKIP_BYTE_STATS_FLAG)):
        print(f"Usage: trace-analyze2.py <file> [{BYTE_STATS_FLAG}]")
        exit(1)

    log_file = sys.argv[1]
    byte_stats_enabled = len(sys.argv) == 3 and sys.argv[2] == BYTE_STATS_FLAG

    print("Analyzing " + log_file)

    access_types = set()
    pointer_states: dict[int, int] = {}
    byte_pointer_states: dict[int, int] | None = {} if byte_stats_enabled else None
    thread_ids: dict[str, int] = {}

    access_multi = 0
    access_total = 0
    pointers_multi = 0

    access_multi_byte = 0
    access_total_byte = 0
    pointers_multi_byte = 0

    with open(log_file) as log:
        for line in log:
            if not line.startswith(" > "):
                continue

            parsed = parse_trace_line(line)
            if parsed is None:
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

    if byte_pointer_states is not None:
        print()
        print("Unique addresses (byte):   " + str(len(byte_pointer_states)))
        print("Accesses (byte):           " + str(access_total_byte))

    pointers_multi_ratio = ratio(pointers_multi, len(pointer_states))
    access_multi_ratio = ratio(access_multi, access_total)

    print()
    print(f"Addresses with multi-threaded access:          {str(pointers_multi).ljust(10)} ({pointers_multi_ratio}% of total)")
    print(f"Multi-threaded accesses:                       {str(access_multi).ljust(10)} ({access_multi_ratio}% of total)")

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
