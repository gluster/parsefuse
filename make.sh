#!/bin/sh -e

cd "`dirname $0`"
export GOPATH="$PWD/go"
protogendir="$GOPATH/src/parsefuse/protogen"

mkdir -p "$protogendir"

ruby -I. gauguin.rb -m messages.json $* < protogen.erb | gofmt > "$protogendir/protogen.go"

go install parsefuse
