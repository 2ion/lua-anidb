doc:
	test -d ./doc || mkdir ./doc
	luadoc --noindexpage -d doc api/udp.lua
.PHONY: doc
