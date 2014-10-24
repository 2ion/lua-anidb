CC = gcc
LUA = 5.2

CFLAGS = -O3 -Wall $(shell pkg-config --cflags lua$(LUA))
LDFLAGS = $(shell pkg-config --libs lua$(LUA)) -lreadline

shell: shell.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	strip $@
