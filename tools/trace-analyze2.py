#!/usr/bin/env python3

import sys


def parse_trace_line(line: str):
    parts = line.split()

    if len(parts) == 5 and parts[0] == ">":
        _, pointer, size, access_type, thread = parts
        return access_type, pointer, int(size), thread

    if len(parts) == 6:
        _, operation, pointer, size, thread, _ = parts
        return operation, pointer, int(size), thread

    return None


def ratio(part: int, total: int) -> float:
    return round(100 * part / total, 2) if total else 0.0


def main() -> None:

    if len(sys.argv) != 2:
        print("Usage: trace-analyze.py <file>")
        exit(1)

    log_file = sys.argv[1]

    print("Analyzing " + log_file)

    access_types     = set()
    pointers         = {}        # Key is a set of threads
    pointers_byte    = {}        # Same as pointers, but every byte of access is tracked
    threads          = set()

    access_multi = 0        # Count of accesses from different threads
    access_total = 0        # Total count of accesses

    access_multi_byte = 0   # Same as access_multi, but taking every byte of range to account
    access_total_byte = 0   # Same as access_total, but taking every byte of range to account

    with open(log_file) as log:

        line = log.readline()

        while line:

            if line.startswith(" > "):

                parsed = parse_trace_line(line)
                if parsed is None:
                    line = log.readline()
                    continue

                access_type, pointer, size, thread = parsed

                # Push operation/type to found operations
                access_types.add(access_type)

                # Add pointer and associated thread
                if pointer not in pointers:
                    pointers[pointer] = set()

                if thread not in pointers[pointer] and len(pointers[pointer]) == 1:
                    access_multi += 1   # Accounting first access

                pointers[pointer].add(thread)

                # Increase count of multithreaded accesses
                if len(pointers[pointer]) > 1:
                    access_multi += 1

                access_total += 1

                start_pointer = int(pointer, 16)

                # Add pointer and associated thread for every byte of access region
                for byte_pointer in range(start_pointer, start_pointer + size):

                    byte_pointer_hex = hex(byte_pointer)

                    # Add pointer and associated thread
                    if byte_pointer_hex not in pointers_byte:
                        pointers_byte[byte_pointer_hex] = set()

                    if thread not in pointers_byte[byte_pointer_hex] and len(pointers_byte[byte_pointer_hex]) == 1:
                        access_multi_byte += 1   # Accounting first access

                    pointers_byte[byte_pointer_hex].add(thread)

                    # Increase count of multithreaded accesses
                    if len(pointers_byte[byte_pointer_hex]) > 1:
                        access_multi_byte += 1

                    access_total_byte += 1

                threads.add(thread)

            line = log.readline()

    print()
    print("Access types:              " + " ".join(sorted(access_types)))
    print("Threads:                   " + str(len(threads)))
    print()
    print("Unique addresses:          " + str(len(pointers)))
    print("Accesses:                  " + str(access_total))
    print()
    print("Unique addresses (byte):   " + str(len(pointers_byte)))
    print("Accesses (byte):           " + str(access_total_byte))

    pointers_multi = 0

    for pointer in pointers:
        if len(pointers[pointer]) > 1:
            pointers_multi += 1

    pointers_multi_ratio = ratio(pointers_multi, len(pointers))
    access_multi_ratio = ratio(access_multi, access_total)

    print()
    print(f"Addresses with multi-threaded access:          {str(pointers_multi).ljust(10)} ({pointers_multi_ratio}% of total)")
    print(f"Multi-threaded accesses:                       {str(access_multi).ljust(10)} ({access_multi_ratio}% of total)")

    pointers_multi_byte = 0

    for pointer in pointers_byte:
        if len(pointers_byte[pointer]) > 1:
            pointers_multi_byte += 1

    pointers_multi_byte_ratio = ratio(pointers_multi_byte, len(pointers_byte))
    access_multi_byte_ratio = ratio(access_multi_byte, access_total_byte)

    print()
    print(f"Addresses with multi-threaded access (byte):   {str(pointers_multi_byte).ljust(10)} ({pointers_multi_byte_ratio}% of total)")
    print(f"Multi-threaded accesses (byte):                {str(access_multi_byte).ljust(10)} ({access_multi_byte_ratio}% of total)")


if __name__ == "__main__":
    main()
