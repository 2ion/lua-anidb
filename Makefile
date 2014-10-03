doc:
	test -d ./doc || mkdir ./doc
	luadoc --noindexpage -d doc api/http.lua api/udp.lua 
.PHONY: doc
