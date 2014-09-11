doc:
	test -d ./doc || mkdir ./doc
	luadoc --noindexpage -d doc anidb0.lua

.PHONY: doc
