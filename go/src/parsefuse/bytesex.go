package main

import (
	"encoding/binary"
	"unsafe"
)

func getBytesex() (ord binary.ByteOrder) {
	ord = binary.LittleEndian
	if *(*uint32)(unsafe.Pointer(&[]byte{1, 0, 0, 0}[0])) != 1 {
		ord = binary.BigEndian
	}

	return
}
