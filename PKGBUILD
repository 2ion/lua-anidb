# Maintainer: 2ion <dev@2ion.de>
pkgname=lua-anidb-git
pkgver=0.1
pkgrel=1
pkgdesc="Client library and command line client for the AniDB.net HTTP API"
arch=('any')
url="https://github.com/2ion/lua-anidb"
license=('GPL3')
depends=('lua' 'lua-posix-git' 'lua-penlight' 'lua-socket' 'lua-zlib')
makedepends=('git')
provides=("${pkgname%-git}")
conflicts=("${pkgname%-git}")
source=('git+https://github.com/2ion/lua-anidb.git#branch=master')
md5sums=('SKIP')

pkgver() {
	cd "$srcdir/${pkgname%-git}"
	printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

prepare(){
  cd "$srcdir/${pkgname%-git}"
  cat > _anic <<EOF
#!/bin/sh
/usr/bin/env lua /usr/share/lua/5.2/anidb/anic
EOF
}

package() {
	cd "$srcdir/${pkgname%-git}"
  install -m755 -d "$pkgdir"/usr/share/lua/5.2/anidb/api
  install -Tm755 api/http.lua "$pkgdir"/usr/share/lua/5.2/anidb/api/http.lua
  install -Dm755 anic "$pkgdir"/usr/share/lua/5.2/anidb/anic
  install -Dm755 _anic "$pkgdir"/usr/bin/anic
}
