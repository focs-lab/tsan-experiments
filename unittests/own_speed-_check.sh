#!/bin/bash

for i in own_speed*.out; do
	echo $i
	./$i 2>&1 | grep --color=always "SUMMARY: ThreadSanitizer: "
	echo
done
