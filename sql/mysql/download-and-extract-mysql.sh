
[ ! -f "mysql-8.0.39.tar.gz" ] && wget https://github.com/mysql/mysql-server/archive/refs/tags/mysql-8.0.39.tar.gz

[ -d "mysql-server-mysql-8.0.39" ] && echo "Directory 'mysql-server-mysql-8.0.39' already exists." && exit 1

# refuse to unpack an archive whose sha256 is not the pinned one (tools/source_archives.sha256)
VERIFY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../../tools/verify_archive.sh"
"$VERIFY" mysql-8.0.39.tar.gz || exit 1
tar -xzf mysql-8.0.39.tar.gz
cd mysql-server-mysql-8.0.39
