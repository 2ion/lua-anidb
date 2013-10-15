pack.so:
	make -C lpack
	cp lpack/pack.so .

doc:
	test -d ./doc || mkdir ./doc
	luadoc --noindexpage -d doc anidb0.lua

.PHONY: doc
