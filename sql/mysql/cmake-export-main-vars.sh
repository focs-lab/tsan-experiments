# A small "library" for cmake-* in MySQL build dir.

[ -z "$1" ] && echo "No build name (arg 1 in $0)." && exit 1


# Special LLVM clang path:
if [ -n "$LLVM_ROOT_PATH" ]; then
	# A temporal crutch.
	[ ! -d "$LLVM_ROOT_PATH/.git" ] && export LLVM_ROOT_PATH="/home/all/src/llvm-project-mcm"

	if [ -n "$COMPILERS_PATH" ]; then
		export CC="$COMPILERS_PATH/bin/clang"
		export CXX="$COMPILERS_PATH/bin/clang++"
	else
		export CC="$LLVM_ROOT_PATH/bin/clang"
		export CXX="$LLVM_ROOT_PATH/bin/clang++"
	fi

	# Check for compilers existance:
	"$CC" --version > /dev/null && "$CXX" --version > /dev/null || exit 1
else
	echo "No LLVM_ROOT_PATH!"
	exit 1
fi

LLVM_COMMIT=`$COMPILERS_PATH/bin/clang --version | head -n1 | sed "s/.\+\s\([[:xdigit:]]\+\))/\1/g"` || exit 1
LLVM_BRANCH=`git -C $LLVM_ROOT_PATH branch --points-at $LLVM_COMMIT | head -n 1 | sed -e "s/^[* ]\+//g" -e "s=origin/==g" | xargs`

#echo Commit $LLVM_COMMIT, branch $LLVM_BRANCH.
#exit 2


# General constants:
if [ -f "CMakeLists.txt" ]; then
	export SOURCE_DIR="."

elif [ -n "$(ls mysql-server-mysql-*)" ]; then
	export SOURCE_DIR="$(ls -d mysql-server-mysql-* | head -n1)"

elif [ -n "${SOURCE_DIR+exists}" ]; then
	echo "No source directory found!"
	exit 1
fi


if [ -n "$LLVM_BRANCH" ]; then
	export BUILD_DIR_ROOT="/dev/shm/mysql-build_$LLVM_BRANCH-`git -C $LLVM_ROOT_PATH rev-parse --short $LLVM_COMMIT`"
else
	export BUILD_DIR_ROOT="/dev/shm/mysql-build_$LLVM_COMMIT"
fi


# Automatic constants:
if [ -z "$BUILD_EXTRA_SUFFIX" ]; then
	export BUILD_DIR="$BUILD_DIR_ROOT/build-$1"
	export INSTALL_PREFIX="$BUILD_DIR_ROOT/install-$1"
else
	export BUILD_DIR="$BUILD_DIR_ROOT/build-${1}_$BUILD_EXTRA_SUFFIX"
	export INSTALL_PREFIX="$BUILD_DIR_ROOT/install-${1}_$BUILD_EXTRA_SUFFIX"
fi

export BUILD_NPROC="$(( $(nproc) / 4 * 3 ))"
