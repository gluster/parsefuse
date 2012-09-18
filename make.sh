#!/bin/sh -e

cd "`dirname $0`"
export GOPATH="$PWD/go"
parsefusedir="$GOPATH/src/parsefuse"

mkdir -p "$parsefusedir"

ruby -I. gogen.rb $* | gofmt > "$parsefusedir/parsefuse.go"

go install pfu
