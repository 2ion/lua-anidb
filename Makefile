doc: 
	test -d ./doc || mkdir ./doc
	luadoc -d doc api/http.lua api/udp.lua 
.PHONY: doc
