# Parsefuse utilities

This directory contains utils that help
working with fusedumps.

Follwing utils are provided:

## fusedumppairup

A filter for fusedumps to transform them to
a layout that's more convenient for line
oriented text processing (grep, sed, awk, etc.).

```
$ ./fusedumppairup.rb -h
Usage: ./fusedumppairup.rb [< <STDIN>|<FILE>]

Takes a fusedump in JSON stream format and combines incoming messages
into request + response pairs.

Output is JSON stream (one object per line) with scheme

{"UNIQUE":<UNIQUE>,"OP":<OP NAME>, "REQUEST":<REQUEST MSG>, "RESPONSE":<RESPONSE MSG>}
```
