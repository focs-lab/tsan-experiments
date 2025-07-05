#!/usr/bin/env python3

import sys


def main() -> None:

    if len(sys.argv) != 2:
        print("Usage: trace-analyze.py <file>")
        exit(1)

    log_file = sys.argv[1]

    print("Analyzing " + log_file)

    operations      = set()
    pointers        = {}        # Key is a set of threads
    pointers_byte   = {}        # Same as pointers, but every byte of access is tracked
    threads         = set()

    access_multi = 0        # Count of accesses from different threads
    access_total = 0        # Total count of accesses

    access_multi_byte = 0   # Same as access_multi, but taking every byte of range to account
    access_total_byte = 0   # Same as access_total, but taking every byte of range to account

    with open(log_file) as log:

        line = log.readline()

        while line:

            if line.startswith(" > "):

                # Parse string
                signature, operation, pointer, size, thread, source = line.split()

                # Push operation to found operations
                operations.add(operation)

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

                # Add pointer and associated thread for every byte of access region
                for pointer in range(int(pointer[2:], 16), int(pointer[2:], 16) + int(size)):

                    pointer = hex(pointer)

                    # Add pointer and associated thread
                    if pointer not in pointers_byte:
                        pointers_byte[pointer] = set()

                    if thread not in pointers_byte[pointer] and len(pointers_byte[pointer]) == 1:
                        access_multi_byte += 1   # Accounting first access

                    pointers_byte[pointer].add(thread)

                    # Increase count of multithreaded accesses
                    if len(pointers_byte[pointer]) > 1:
                        access_multi_byte += 1

                    access_total_byte += 1

                threads.add(thread)

            line = log.readline()

    print()
    print("Operations:                " + " ".join(sorted(operations)))
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

    pointers_multi_ratio = round(100 * pointers_multi / len(pointers), 2)
    access_multi_ratio = round(100 * access_multi / access_total, 2)

    print()
    print(f"Addresses with multi-threaded access:          {str(pointers_multi).ljust(10)} ({pointers_multi_ratio}% of total)")
    print(f"Multi-threaded accesses:                       {str(access_multi).ljust(10)} ({access_multi_ratio}% of total)")

    pointers_multi_byte = 0

    for pointer in pointers_byte:
        if len(pointers_byte[pointer]) > 1:
            pointers_multi_byte += 1

    pointers_multi_byte_ratio = round(100 * pointers_multi_byte / len(pointers_byte), 2)
    access_multi_byte_ratio = round(100 * access_multi_byte / access_total_byte, 2)

    print()
    print(f"Addresses with multi-threaded access (byte):   {str(pointers_multi_byte).ljust(10)} ({pointers_multi_byte_ratio}% of total)")
    print(f"Multi-threaded accesses (byte):                {str(access_multi_byte).ljust(10)} ({access_multi_byte_ratio}% of total)")


if __name__ == "__main__":
    main()
