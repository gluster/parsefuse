package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

import "parsefuse/protogen"

//
// formatting routines
//

func formatFmt_i(w *os.File, lim int, a ...interface{}) {
	var err error
	for _, x := range a {
		switch t := x.(type) {
		case string:
			_, err = fmt.Fprint(w, t, " ")
		case []interface{}:
			formatFmt_i(w, lim, t...)
		case []byte:
			tail := ""
			if len(t) > lim && lim > 0 {
				tail = fmt.Sprintf("... %d", len(t))
				t = t[:lim]
			}
			_, err = fmt.Fprintf(w, "%q%s ", t, tail)
		default:
			_, err = fmt.Fprintf(w, "%+v ", t)
		}
		if err != nil {
			log.Fatal("Fprintf: ", err)
		}
	}
}

func formatFmt(w *os.File, lim int, a ...interface{}) {
	formatFmt_i(w, lim, a...)
	w.Write([]byte{'\n'})
}

func truncate(lim int, a []interface{}) (truncated bool) {
	for i, x := range a {
		switch t := x.(type) {
		case []byte:
			if len(t) > lim {
				a[i] = t[:lim]
				truncated = true
			}
		case []interface{}:
			truncated = truncated || truncate(lim, t)
		}
	}
	return
}

type jrec struct {
	Truncated bool
	Msg       []interface{}
}

func formatJson(jw *json.Encoder, lim int, a ...interface{}) {
	var jr jrec
	if lim > 0 {
		jr.Truncated = truncate(lim, a)
	}
	jr.Msg = a
	err := jw.Encode(jr)
	if err != nil {
		log.Fatal("json.Encode: ", err)
	}
}

//
// I/O routines
//

const iobase = 1 << 16

func iosize(f *os.File) int {
	fin, err := f.Stat()
	if err != nil {
		log.Fatal(err)
	}
	st := fin.Sys().(*syscall.Stat_t)
	if st.Blksize > iobase {
		return int(st.Blksize)
	}
	return iobase
}

func shortread() {
	log.Fatal("Read: short read")
}

const leadup = 1 + int(unsafe.Sizeof(uint32(0)))

type FUSEReader struct {
	*os.File
	buf []byte
	off int
}

func NewFUSEReader(f *os.File) *FUSEReader {
	fr := &FUSEReader{File: f}
	fr.buf = make([]byte, 0, iosize(f))
	fr.off = 0
	return fr
}

// rawread attempts to read at least req bytes to
// the reader's buffer. If already at EOF, it returns
// false; if succeeded, returns true; in all other
// cases the program is terminated. On success, the
// length of the reader's buffer is adjusted to mark
// the region of read data.
func (fr *FUSEReader) rawread(req int) bool {
	buf := fr.buf[len(fr.buf):cap(fr.buf)]
	if req > len(buf) {
		panic("required more bytes than buffer size")
	}
	n := 0
	for n < req {
		r, err := fr.File.Read(buf[n:])
		switch err {
		case io.EOF:
			if n == 0 {
				return false
			}
			shortread()
		case nil:
			n += r
		default:
			log.Fatal(err)
		}
	}
	fr.buf = fr.buf[:len(fr.buf)+n]
	return true
}

func (fr *FUSEReader) rewind() {
	copy(fr.buf, fr.buf[fr.off:])
	fr.buf = fr.buf[:len(fr.buf)-fr.off]
	fr.off = 0
}

func (fr *FUSEReader) extend(n int) {
	fr.buf = append(fr.buf[:cap(fr.buf)], make([]byte, n-cap(fr.buf))...)[:len(fr.buf)]
}

// read attempts to return a FUSE message (either from buffer space or freshly
// read in). If no partial message is stored and we are already at EOF,
// returns nil; if suceeded, returns a byte array containing the message; in
// all other case, the program is terminated.  On success, the length of the
// reader's buffer is adjusted to mark the region of read data, and reader's
// offset is adjusted to the end of the message.
func (fr *FUSEReader) read() []byte {
	fresh := len(fr.buf) - fr.off
	if
	// no unconsumed data, we can rewind for free
	fresh == 0 ||
		// not enough space in buffer tail,
		// rewind to get space
		fr.off+leadup > cap(fr.buf) {
		fr.rewind()
	}
	if fresh < leadup {
		if !fr.rawread(leadup - fresh) {
			if fresh == 0 {
				return nil
			} else {
				shortread()
			}
		}
		fresh = len(fr.buf) - fr.off
	}

	mlen := 1 + int(*(*uint32)(unsafe.Pointer(&fr.buf[fr.off+1])))
	if fr.off+mlen > cap(fr.buf) {
		fr.rewind()
		if mlen > cap(fr.buf) {
			fr.extend(mlen)
		}
	}
	if fresh < mlen && !fr.rawread(mlen-fresh) {
		shortread()
	}

	buf := fr.buf[fr.off:][:mlen]
	fr.off += mlen
	return buf
}

//
// special parsing support routines
//

const direntSize = int(unsafe.Sizeof(protogen.Dirent{}))

func parsedir(data []byte) ([][]interface{}, []byte) {
	dea := make([][]interface{}, 0, len(data)/(direntSize+10))

	for len(data) >= direntSize {
		dex := make([]interface{}, 2)
		de := *(*protogen.Dirent)(unsafe.Pointer(&data[0]))
		dex[0] = de
		nlen := int(de.Namelen)
		recordsize := direntSize + nlen + ((8 - nlen&7) & 7)
		if len(data) < recordsize {
			// cannot parse
			break
		}
		dex[1] = string(data[direntSize:][:nlen])
		dea = append(dea, dex)
		data = data[recordsize:]
	}

	return dea, data
}

//
// main
//

const usage = `fusedump disector
FUSE version: %d.%d

%s [options] [<fusedump>]
options:
`

func main() {
	insize := int(unsafe.Sizeof(protogen.InHeader{}))
	outsize := int(unsafe.Sizeof(protogen.OutHeader{}))
	if insize <= outsize {
		panic("header size assertion fails")
	}

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, usage, protogen.FuseMajor, protogen.FuseMinor,
			filepath.Base(os.Args[0]))
		flag.PrintDefaults()
	}
	lim := flag.Int("lim", 512, "truncate output data to this size")
	format := flag.String("format", "fmt", "output format (fmt, json or null)")
	fopath := flag.String("o", "-", "output file")
	flag.Parse()

	var fi *os.File
	var err error
	switch flag.NArg() {
	case 0:
		fi = os.Stdin
	case 1:
		fi, err = os.Open(flag.Arg(0))
		if err != nil {
			log.Fatalf("Open %s: %s", flag.Arg(0), err)
		}
	default:
		flag.Usage()
		os.Exit(1)
	}

	var fo *os.File
	switch *fopath {
	case "-":
		fo = os.Stdout
	default:
		fo, err = os.OpenFile(*fopath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0644)
		if err != nil {
			log.Fatalf("Open %s: %s", fopath, err)
		}
	}

	var formatter func(lim int, a ...interface{})
	switch *format {
	case "fmt":
		formatter = func(lim int, a ...interface{}) {
			formatFmt(fo, lim, a...)
		}
	case "json":
		jw := json.NewEncoder(fo)
		formatter = func(lim int, a ...interface{}) {
			formatJson(jw, lim, a...)
		}
	case "null":
		formatter = func(lim int, a ...interface{}) {
		}
	default:
		flag.Usage()
		os.Exit(1)
	}

	fr := NewFUSEReader(fi)
	umap := make(map[uint64]int)
	for {
		var body []interface{}
		var dir byte

		buf := fr.read()
		if buf == nil {
			break
		}
		dir, buf = buf[0], buf[1:]

		switch dir {
		case 'R':
			inh := (*protogen.InHeader)(unsafe.Pointer(&buf[0]))
			opname := ""
			if int(inh.Opcode) < len(protogen.FuseOpnames) {
				opname = protogen.FuseOpnames[inh.Opcode]
			}
			if opname == "" {
				opname = fmt.Sprintf("OP#%d", inh.Opcode)
			}
			body = protogen.ParseR(inh.Opcode, buf[insize:])
			formatter(*lim, opname, *inh, body)
			// special handling for some ops
			switch inh.Opcode {
			case protogen.LISTXATTR, protogen.GETXATTR:
				// for 0 sized query answer will be GetxattrOut,
				// otherwise blob; former case marked with negative sign
				if body[0].(protogen.GetxattrIn).Size == 0 {
					umap[inh.Unique] = -int(inh.Opcode)
				} else {
					umap[inh.Unique] = int(inh.Opcode)
				}
			case protogen.FORGET:
				// forget FORGET, as it entails no response
			default:
				umap[inh.Unique] = int(inh.Opcode)
			}
		case 'W':
			ouh := (*protogen.OutHeader)(unsafe.Pointer(&buf[0]))
			buf = buf[outsize:]
			if opcode, ok := umap[ouh.Unique]; ok {
				delete(umap, ouh.Unique)
				if opcode < 0 {
					if len(buf) == int(unsafe.Sizeof(protogen.GetxattrOut{})) {
						body = []interface{}{
							*(*protogen.GetxattrOut)(unsafe.Pointer(&buf[0])),
						}
					} else {
						opcode *= -1
					}
				}
				if opcode >= 0 {
					switch uint32(opcode) {
					case protogen.READDIR:
						body = make([]interface{}, 0, 1)
						dea, data := parsedir(buf)
						if len(dea) > 0 {
							body = append(body, dea)
						}
						if len(data) > 0 {
							body = append(body, data)
						}
					case protogen.LISTXATTR:
						nama := strings.Split(string(buf), "\x00")
						body = []interface{}{nama[:len(nama)-1]}
					default:
						body = protogen.ParseW(uint32(opcode), buf)
					}
				}
				formatter(*lim, *ouh, body)
			} else {
				formatter(*lim, *ouh, buf)
			}
		default:
			log.Fatalf("unknown direction %q", dir)
		}
	}
}
