#!/bin/bash

for i in basic_race*.out; do
	echo $i
	./$i 2>&1 | grep --color=always "SUMMARY: ThreadSanitizer: "
	echo
done
