#!/bin/sh -e

cd "`dirname $0`"
export GOPATH="$PWD/go"
export GO111MODULE=off
protogendir="$GOPATH/src/parsefuse/protogen"

if ! [ $# -eq 1 ]; then
    echo "Usage: $0 <path-to-fuse-header>"
    exit 1
fi
if ! [ -f "$1" ]; then
    echo "$1 is not a regular file"
    exit 1
fi

mkdir -p "$protogendir"

ruby -Iruby ruby/gauguin.rb -m messages.yaml -p "$1" < protogen.erb | gofmt > "$protogendir/protogen.go"

go get github.com/ugorji/go/codec
go install parsefuse
