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
	"unsafe"
)

import "parsefuse"

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

func shortread() {
	log.Fatal("Read: short read")
}

func read(f *os.File, buf []byte) bool {
	for bo := 0; bo < len(buf); {
		n, err := f.Read(buf[bo:])
		switch err {
		case io.EOF:
			if bo == 0 {
				return false
			}
			shortread()
		case nil:
			bo += n
		default:
			log.Fatal("Read: ", err)
		}
	}
	return true
}

const usage = `fusedump disector

%s [options] [<fusedump>]
options:
`

func main() {
	var inh *parsefuse.InHeader
	var ouh *parsefuse.OutHeader

	insize := int(unsafe.Sizeof(*inh))
	outsize := int(unsafe.Sizeof(*ouh))
	if insize <= outsize {
		panic("header size assertion fails")
	}

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, usage, filepath.Base(os.Args[0]))
		flag.PrintDefaults()
	}
	lim := flag.Int("lim", 512, "truncate output data to this size")
	format := flag.String("format", "fmt", "output format (fmt or json)")
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
	default:
		flag.Usage()
		os.Exit(1)
	}

	hbuf := make([]byte, 1+insize)
	dbuf := make([]byte, 0, 4096)

	umap := make(map[uint64]int)
	var body []interface{}

	for {
		if !read(fi, hbuf[:1+outsize]) {
			os.Exit(0)
		}
		switch hbuf[0] {
		case 'R':
			if !read(fi, hbuf[1+outsize:]) {
				shortread()
			}
			inh = (*parsefuse.InHeader)(unsafe.Pointer(&hbuf[1]))
			dlen := int(inh.Len) - insize
			if cap(dbuf) < dlen {
				dbuf = make([]byte, dlen)
			}
			dbuf = dbuf[:dlen]
			if !read(fi, dbuf) {
				shortread()
			}
			opname := ""
			if int(inh.Opcode) < len(parsefuse.FuseOpnames) {
				opname = parsefuse.FuseOpnames[inh.Opcode]
			}
			if opname == "" {
				opname = fmt.Sprintf("OP#%d", inh.Opcode)
			}
			body = parsefuse.HandleR(inh.Opcode, dbuf)
			formatter(*lim, opname, *inh, body)
			// special handling for some ops
			switch inh.Opcode {
			case parsefuse.LISTXATTR, parsefuse.GETXATTR:
				// for 0 sized query answer will be GetxattrOut,
				// otherwise blob; former case marked with negative sign
				if body[0].(parsefuse.GetxattrIn).Size == 0 {
					umap[inh.Unique] = -int(inh.Opcode)
				} else {
					umap[inh.Unique] = int(inh.Opcode)
				}
			case parsefuse.FORGET:
				// forget FORGET, as it entails no response
			default:
				umap[inh.Unique] = int(inh.Opcode)
			}
		case 'W':
			ouh = (*parsefuse.OutHeader)(unsafe.Pointer(&hbuf[1]))
			dlen := int(ouh.Len) - outsize
			if cap(dbuf) < dlen {
				dbuf = make([]byte, dlen)
			}
			dbuf = dbuf[:dlen]
			if !read(fi, dbuf) {
				shortread()
			}
			if opcode, ok := umap[ouh.Unique]; ok {
				delete(umap, ouh.Unique)
				var gxo *parsefuse.GetxattrOut
				if opcode < 0 {
					if len(dbuf) == int(unsafe.Sizeof(*gxo)) {
						body = []interface{}{
							*(*parsefuse.GetxattrOut)(unsafe.Pointer(&dbuf[0])),
						}
					} else {
						opcode *= -1
					}
				}
				if opcode >= 0 {
					if uint32(opcode) == parsefuse.LISTXATTR {
						nama := strings.Split(string(dbuf), "\x00")
						body = []interface{}{nama[:len(nama)-1]}
					} else {
						body = parsefuse.HandleW(uint32(opcode), dbuf)
					}
				}
				formatter(*lim, *ouh, body)
			} else {
				formatter(*lim, *ouh, dbuf)
			}
		default:
			log.Fatalf("unknown direction %q", hbuf[0])
		}
	}
}
