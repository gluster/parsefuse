#!/bin/sh -e

cd "`dirname $0`"
export GOPATH="$PWD/go"
protogendir="$GOPATH/src/parsefuse/protogen"

mkdir -p "$protogendir"

ruby -Iruby ruby/gauguin.rb -m messages.yaml $* < protogen.erb | gofmt > "$protogendir/protogen.go"

go install parsefuse
