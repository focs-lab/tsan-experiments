
[ ! -f "mysql-8.0.39.tar.gz" ] && wget https://github.com/mysql/mysql-server/archive/refs/tags/mysql-8.0.39.tar.gz

[ -d "mysql-server-mysql-8.0.39" ] && echo "Directory 'mysql-server-mysql-8.0.39' already exists." && exit 1

tar -xzf mysql-8.0.39.tar.gz
cd mysql-server-mysql-8.0.39
