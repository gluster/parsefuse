This is a program to present fusedumps
(binary dumps of FUSE traffic) in a human
readable or standard machine processable (JSON)
format.

You can get fusedumps with:

-   glusterfs, with `--dump-fuse=<PATH>` option;
-   tracing a FUSE server with a 
    [hacked strace](https://github.com/csabahenk/strace-fusedump),
    with `-efuse=<PATH>` option.

To build it, you need the following software installed:

-   ruby,
-   go,
-   [cast](https://github.com/oggy/cast), which you can get with `gem install cast`;

and the kernel header file which defines the FUSE data structures,
available in the source of the linux kernel and in various userspace
C codebases that implement a FUSE server from scratch; so for example:

-   [Linux 3.16, _include/uapi/linux/fuse.h_](https://github.com/torvalds/linux/blob/v3.16/include/uapi/linux/fuse.h)
-   [FUSE 2.9.2, _include/fuse_kernel.h_](http://sourceforge.net/p/fuse/fuse/ci/fuse_2_9_2/tree/include/fuse_kernel.h)
-   [GlusterFS 3.5.2, _contrib/fuse-include/fuse_kernel.h_](https://github.com/gluster/glusterfs/blob/v3.5.2/contrib/fuse-include/fuse_kernel.h)

As a thumb of rule, you should use the same header file with
which the producer of the fusedumps to dissect was built with.

Once you have this, build _parsefuse_ with the following command:

```sh
./make.sh -p <path-to-fuse-header>
```

After a succesful build you will have the binary at _go/bin/parsefuse_.
