#!/bin/bash

[[ "$1" == "" || "$1" == "-h" || "$1" == "--help" ]] && {
	echo "Simple script to build <TYPE>s of binary and IR for <FILE>."
	echo "Also creates a file named \"./FILE-_check.sh\" to primitively check all artifacts for data races."
	echo 
	echo "Usage: $0 FILENAME [BUILD_TYPE]"
	echo 
	echo "FILENAME should be any of *.c, *.cpp, *.cxx and *.cc"
	echo
	echo "Default BUILD_TYPE: \"all\"."
	echo
	echo "Available default build types (comma-separated): "
	echo "    capture-tracker escape-analysis ownership swmr single-threaded"
	echo
	echo "Available special build types: "
	echo "    all          Alias to capture-tracker,escape-analysis,ownership,swmr,single-threaded."
	echo "    orig         Build original binary/IR without TSan."
	echo "    mllvm-debug  Enables \"-passes=<type> -mllvm -debug-only=<type>\" for selected types."
	echo "    rawflags     Overrides all other types. \"Free build mode\", passing raw \$CFLAGS or \$CXXFLAGS."
	echo
	echo "Examples: "
	echo "   $0 $(ls *.c | head -n1) capture-tracker,ownership,mllvm-debug"
	echo "   CFLAGS="-O3" $0 $(ls *.c | head -n1) rawflags"

	exit 1
}

SRCFILE="$1"

[ ! -f "$SRCFILE" ] && echo "No file \"$SRCFILE\"." && exit 1


# Build mode selection (no arg == all):
BUILD_TYPE="$2"

[[ "$BUILD_TYPE" == *"mllvm-debug"* ]] && BUILD_TYPE_MLLVM_DEBUG_PASSES="1"

[[ "$BUILD_TYPE" == "" || "$BUILD_TYPE" == "mllvm-debug" || "$BUILD_TYPE" == *"all"* ]] && BUILD_TYPE="all"

: '
if [ -z "$2" ] || [ "$2" == "all" ]; then
	BUILD_TYPE=""

else
	BUILD_TYPE="${2##tsan-use-}"

	case "$BUILD_TYPE" in
		"no"|"")
			BUILD_TYPE=""
		;;
		"ct"|"capture-tracker")
			BUILD_TYPE="capture-tracker"
		;;
		"ea"|"escape-analysis")
			BUILD_TYPE="escape-analysis"
		;;
		"ipa"|"gea"|"eag"|"escape-analysis-global")
			BUILD_TYPE="ipa"
		;;
		"ow"|"own"|"ownership")
			BUILD_TYPE="ownership"
		;;
		"st"|"single-thread"|"single-threaded")
			BUILD_TYPE="single-threaded"
		;;
		"swmr")
			BUILD_TYPE="swmr"
		;;
		*) echo "Wrong mode \"$BUILD_TYPE\""
			exit 2
		;;
	esac
fi
'


set -e

# Compiler selection:

if [[ $SRCFILE == *.c ]]; then
	COMPILER_BIN="clang"
	COMPILER_FLAGS="$CFLAGS"

elif [[ $SRCFILE == *.cxx || "$SRCFILE" == *.cpp || "$SRCFILE" == *.cc ]]; then
	COMPILER_BIN="clang++"
	COMPILER_FLAGS="$CXXFLAGS"

else
	echo "File \"$SRCFILE\" is not *.c nor *.cpp source."
	exit 2
fi


printinfo() {
	echo -e "\e[36m$1\e[0m"
}

printerr() {
	printinfo "\e[93m$1"
	exit 1
}

OUTFILEPREFIX="${SRCFILE%.*}"


[ -z "$LLVM_ROOT_PATH" ] && LLVM_ROOT_PATH="/home/mcm/univ/DiplomaMag/llvm-builds/llvm_tsan-with-ea-IPA_6532d1ce1f" && printinfo "Using default LLVM root path \"$LLVM_ROOT_PATH\"."
LLVM_BIN_PATH="$LLVM_ROOT_PATH/bin"
LLVM_LIB_PATH="$LLVM_ROOT_PATH/lib"


COMPILER_BIN="$LLVM_BIN_PATH/$COMPILER_BIN"
[ ! -f $COMPILER_BIN ] && echo "No compiler \"$COMPILER_BIN\" found." && exit 2

printinfo "\e[37mCompiler: $COMPILER_BIN"
printinfo "\e[37m    File: $SRCFILE"


COMPILER_FLAGS="$COMPILER_FLAGS -g"
COMPILER_FLAGS_TO_IR="-S -emit-llvm"
COMPILER_FLAGS_TSAN="-fsanitize=thread"


get_filename_bin() {
	[ -z "$OUTFILEPREFIX" ] && echo "$(caller). No prefix for file." && exit 1

	echo "${OUTFILEPREFIX}${OUTFILESUFFIX}.out"
}

get_filename_ir() {
	[ -z "$OUTFILEPREFIX" ] && echo "$(caller). No prefix for file." && exit 1

	echo "${OUTFILEPREFIX}${OUTFILESUFFIX}.ll"
}


build_common() {
	[ -z "$BUILDFLAGS" ] && echo "$(caller). No flags!" && exit 3
	[ -n "$1" ] && OUTFILESUFFIX="-$1" || OUTFILESUFFIX=""

	printinfo " Building: \e[37m$BUILDFLAGS"
	$COMPILER_BIN $BUILDFLAGS $SRCFILE -o "$(get_filename_ir)" $COMPILER_FLAGS_TO_IR
	$COMPILER_BIN $BUILDFLAGS $SRCFILE -o "$(get_filename_bin)"

	printinfo "  Success: \e[32m$(get_filename_bin)\n"
	BUILDFLAGS=""
}


if [[ "$BUILD_TYPE" == "rawflags" ]]; then
	printinfo " Free build mode. \e[37m \$COMPILER_FLAGS = $COMPILER_FLAGS"

	$COMPILER_BIN $COMPILER_FLAGS $SRCFILE -o "$(get_filename_bin)"
	exit 0
fi


if [[ "$BUILD_TYPE" == *"orig"* ]]; then
	BUILDFLAGS="$COMPILER_FLAGS"

	build_common "orig"
fi

if [[ "$BUILD_TYPE" == *"capture-tracker"* || "$BUILD_TYPE" == "all" ]]; then
	BUILDFLAGS="$COMPILER_FLAGS $COMPILER_FLAGS_TSAN"

	build_common "ct"
fi

if [[ "$BUILD_TYPE" == *"escape-analysis"* || "$BUILD_TYPE" == "all" ]]; then
	BUILDFLAGS="$COMPILER_FLAGS $COMPILER_FLAGS_TSAN -mllvm -tsan-use-escape-analysis-global"
	[ -n "$BUILD_TYPE_MLLVM_DEBUG_PASSES" ] && BUILDFLAGS="$BUILDFLAGS -mllvm -debug-only=escape-analysis"

	build_common "ea"
fi

if [[ "$BUILD_TYPE" == *"ownership"* || "$BUILD_TYPE" == "all" ]]; then
	BUILDFLAGS="$COMPILER_FLAGS $COMPILER_FLAGS_TSAN -mllvm -tsan-use-lock-ownership"
	[ -n "$BUILD_TYPE_MLLVM_DEBUG_PASSES" ] && BUILDFLAGS="$BUILDFLAGS -mllvm -debug-only=lock-ownership"

	build_common "own"
fi

if [[ "$BUILD_TYPE" == *"swmr"* || "$BUILD_TYPE" == "all" ]]; then
	BUILDFLAGS="$COMPILER_FLAGS $COMPILER_FLAGS_TSAN -mllvm -tsan-use-swmr"
	[ -n "$BUILD_TYPE_MLLVM_DEBUG_PASSES" ] && BUILDFLAGS="$BUILDFLAGS -mllvm -debug-only=swmr"

	build_common "swmr"
fi


if [[ "$BUILD_TYPE" == *"single-threaded"* || "$BUILD_TYPE" == "all" ]]; then
	printinfo " Building: \e[37mSingle-threaded"

	[ -f "st_summary.txt" ] && rm st_summary.txt

	OUTFILESUFFIX="-st-link"
	SRCLL_LINKED="$(get_filename_ir)"
	SRCLL_LINKED_TMP="${SRCLL_LINKED}-tmp"

	COMPILER_FLAGS_TSAN_ST="-mllvm -tsan-use-escape-analysis-global -mllvm -tsan-use-single-threaded -mllvm -debug-only=tsan"


	# To default LL:
	$COMPILER_BIN $BUILDFLAGS $SRCFILE $COMPILER_FLAGS_TSAN_ST $COMPILER_FLAGS_TO_IR -o "$SRCLL_LINKED_TMP"

	# To optimized LL:
	[ -n "$BUILD_TYPE_MLLVM_DEBUG_PASSES" ] && OPTDEBUGFLAGS="-passes=print<single-threaded> -debug-only=single-threaded" || OPTDEBUGFLAGS=""

	$LLVM_BIN_PATH/llvm-link -S "$SRCLL_LINKED_TMP" > "$SRCLL_LINKED"
	echo $LLVM_BIN_PATH/opt -S "$SRCLL_LINKED" $OPTDEBUGFLAGS -disable-output
	$LLVM_BIN_PATH/opt -S "$SRCLL_LINKED" $OPTDEBUGFLAGS -disable-output

	# To bin:
	$COMPILER_BIN $COMPILER_FLAGS $COMPILER_FLAGS_TSAN "$SRCLL_LINKED" -o $(get_filename_bin)

	LINK_FLAGS="-levent -lm $LLVM_LIB_PATH/clang/19/lib/x86_64-unknown-linux-gnu/libclang_rt.tsan.a"
	$COMPILER_BIN $COMPILER_FLAGS $LINK_FLAGS $COMPILER_FLAGS_TSAN_ST "$SRCLL_LINKED" -o "$(get_filename_bin)-librt.out"

	# Finalization:
	rm "$SRCLL_LINKED_TMP"

	printinfo "  Success: \e[32m$(get_filename_bin)\n"
fi




# Create an integrity check script:

OUT_CHAIN_CHECK_SCRIPT=${OUTFILEPREFIX}-_check.sh

cat <<EOF > "$OUT_CHAIN_CHECK_SCRIPT"
#!/bin/bash

for i in $OUTFILEPREFIX*.out; do
	echo \$i
	./\$i 2>&1 | grep --color=always "SUMMARY: ThreadSanitizer: "
	echo
done
EOF

chmod +x "$OUT_CHAIN_CHECK_SCRIPT"
