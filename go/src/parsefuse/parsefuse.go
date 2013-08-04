package main

import (
	"encoding/binary"
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

import (
	"parsefuse/protogen"
)

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

const(
	sizeu32 = int(unsafe.Sizeof(uint32(0)))
	sizeu64 = int(unsafe.Sizeof(uint64(0)))
)

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
//
// leadup specifies the offset of the integer which specifies the size of the
// particular packet.
func (fr *FUSEReader) read(leadup int) []byte {
	fresh := len(fr.buf) - fr.off
	if
	// no unconsumed data, we can rewind for free
	fresh == 0 ||
		// not enough space in buffer tail,
		// rewind to get space
		fr.off+leadup+sizeu32 > cap(fr.buf) {
		fr.rewind()
	}
	if fresh < leadup+sizeu32 {
		if !fr.rawread(leadup+sizeu32 - fresh) {
			if fresh == 0 {
				return nil
			} else {
				shortread()
			}
		}
		fresh = len(fr.buf) - fr.off
	}

	mlen := leadup + int(datacaster.AsUint32(fr.buf[fr.off+leadup:]))
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

// FUSEMsgReader is an interface that is to be implemented
// for each format version.
//
// readmsg returns a message deooded to the degree general
// (opcode-independent) decoding is possible: returning
// dir, the direction of the message (read/written),
// meta, format version specific metainformation, and
// the undecoded message buffer.
type FUSEMsgReader interface {
	readmsg() (dir byte, meta []interface{}, buf []byte)
}


type FUSEMsgReader10 struct {
	*FUSEReader
}

func (fmr *FUSEMsgReader10) readmsg() (dir byte, meta []interface{}, buf []byte) {
	buf = fmr.read(1)
	if buf == nil {
		return
	}
	dir, buf = buf[0], buf[1:]
	return
}


type FUSEMsgReader20 struct {
	*FUSEMsgReader10
}

type Time [2]uint64

func (fmr *FUSEMsgReader20) readmsg() (dir byte, meta []interface{}, buf []byte) {
	dir, meta, buf = fmr.FUSEMsgReader10.readmsg()
	if len(buf) >= sizeu32 + sizeu64 + sizeu32 {
		meta = []interface{} { Time{datacaster.AsUint64(buf[sizeu32:]),
			   uint64(datacaster.AsUint32(buf[sizeu32+sizeu64:]))} }
	}
	if len(buf) > sizeu32 + sizeu64 + sizeu32 {
		meta = append(meta, buf[sizeu32 + sizeu64 + sizeu32:])
	}
	buf = fmr.read(0)
	return
}


//
// special parsing support routines
//

const (
	direntSize = int(unsafe.Sizeof(protogen.Dirent{}))
	entryoutSize = int(unsafe.Sizeof(protogen.EntryOut{}))
)

func parsedir(data []byte, opcode uint32) ([][]interface{}, []byte) {
	plussiz := 0
	if opcode == protogen.READDIRPLUS {
		plussiz = entryoutSize
	}
	dea := make([][]interface{}, 0, len(data)/(plussiz + direntSize+10))

	for len(data) >= direntSize {
		nmemb := 2
		if opcode == protogen.READDIRPLUS {
			nmemb++
		}
		dex := make([]interface{}, nmemb)
		i := 0
		if opcode == protogen.READDIRPLUS {
			dex[i] = *datacaster.AsEntryOut(data)
			i++
			data = data[entryoutSize:]
		}
		de := *datacaster.AsDirent(data)
		dex[i] = de
		i++
		nlen := int(de.Namelen)
		recordsize := direntSize + nlen + ((8 - nlen&7) & 7)
		if len(data) < recordsize {
			// cannot parse
			break
		}
		dex[i] = string(data[direntSize:][:nlen])
		i++
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
var datacaster protogen.DataCaster = protogen.NativeDataCaster

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
	bytesexspec := flag.String("bytesex", "native", "endianness of data")
	fopath := flag.String("o", "-", "output file")
	dumpfmt := flag.Float64("dumpformat", 1, "version of dump format")
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

	var frm FUSEMsgReader
	fr := NewFUSEReader(fi)
	frm10 := &FUSEMsgReader10{ fr }
	switch *dumpfmt {
	case 1.0:
		frm = frm10
	case 2.0:
		frm = &FUSEMsgReader20{ frm10 }
	default:
		log.Fatalf("unknown fusedump format version %.2f", *dumpfmt)
	}

	host_bytesex := getBytesex()
	var data_bytesex binary.ByteOrder
	switch *bytesexspec {
	case "native":
		data_bytesex = host_bytesex
	case "le":
		data_bytesex = binary.LittleEndian
	case "be":
		data_bytesex = binary.BigEndian
	default:
		log.Fatalf("unknown bytesex %s", *bytesexspec)
	}
	switch data_bytesex {
	case host_bytesex:
	case binary.LittleEndian:
		datacaster = protogen.LeDataCaster
	case binary.BigEndian:
		datacaster = protogen.BeDataCaster
	default:
		panic("should not be here")
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

	umap := make(map[uint64]int)
	for {
		var body []interface{}
		var dir byte

		dir, meta, buf := frm.readmsg()
		if buf == nil {
			break
		}

		switch dir {
		case 'R':
			inh := datacaster.AsInHeader(buf)
			opname := ""
			if int(inh.Opcode) < len(protogen.FuseOpnames) {
				opname = protogen.FuseOpnames[inh.Opcode]
			}
			if opname == "" {
				opname = fmt.Sprintf("OP#%d", inh.Opcode)
			}
			body = protogen.ParseR(datacaster, inh.Opcode, buf[insize:])
			formatter(*lim, meta, opname, *inh, body)
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
			ouh := datacaster.AsOutHeader(buf)
			buf = buf[outsize:]
			if opcode, ok := umap[ouh.Unique]; ok {
				delete(umap, ouh.Unique)
				if opcode < 0 {
					if len(buf) == int(unsafe.Sizeof(protogen.GetxattrOut{})) {
						body = []interface{}{
							*datacaster.AsGetxattrOut(buf),
						}
					} else {
						opcode *= -1
					}
				}
				if opcode >= 0 {
					uopcode := uint32(opcode)
					switch uopcode {
					case protogen.READDIR, protogen.READDIRPLUS:
						body = make([]interface{}, 0, 1)
						dea, data := parsedir(buf, uopcode)
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
						body = protogen.ParseW(datacaster, uint32(opcode), buf)
					}
				}
				formatter(*lim, meta, *ouh, body)
			} else {
				formatter(*lim, meta, *ouh, buf)
			}
		default:
			log.Fatalf("unknown direction %q", dir)
		}
	}
}
