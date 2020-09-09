This is a program to present fusedumps
(binary dumps of FUSE traffic) in a human
readable or standard machine processable (JSON)
format.

You can get fusedumps with:

-   glusterfs, with `--dump-fuse=<PATH>` option;
-   tracing a FUSE server with a
    [hacked strace](https://github.com/csabahenk/strace-fusedump),
    with `-efuse=<PATH>` option.

To build it, you need the following artifacts:

-   ruby,
-   go,
-   [cast](https://github.com/oggy/cast), which you can get with `gem install cast`;
-   the header file which defines the FUSE data structures, usually
    called _fuse.h_ or _fuse_kernel.h_.

Where to find this header file, which variant to use?

-   **The general case:** this header is available in the source of the
    linux kernel and in various userspace C codebases that implement a FUSE
    server from scratch; so for example:

    -   [Linux 3.16, _include/uapi/linux/fuse.h_](https://github.com/torvalds/linux/blob/v3.16/include/uapi/linux/fuse.h)
    -   [FUSE 2.9.2, _include/fuse_kernel.h_](http://sourceforge.net/p/fuse/fuse/ci/fuse_2_9_2/tree/include/fuse_kernel.h)
    -   [GlusterFS 3.5.2, _contrib/fuse-include/fuse_kernel.h_](https://github.com/gluster/glusterfs/blob/v3.5.2/contrib/fuse-include/fuse_kernel.h)

    The header to use depends on two things:

    -   the fuse server producing the fuse dump
    -   the kernel on which the dumped session ran.

    You should identify the header files that were used to build these two.
    Of the two header files, you should use the older one (which has the lower value
    of the _(`FUSE_KERNEL_VERSION`, `FUSE_KERNEL_MINOR_VERSION`)_ pair).

    So you will not obtain a one-fits-all _parsefuse_ binary, it has to built specifically
    with the appropriate header.

    It might happen that the right header cannot be identified or an earlier _parsefuse_ build is
    reused and thus the header used to build _parsefuse_ does not match the scenario. It's not
    fatal issue — some messages will fail to parse and will be shown as raw binary dump, but the
    rest will be shown properly dissected.

-   **When building to use with dumps created by Glusterfs:**
    this being the main use case of the tool, we concretize the
    above general rule for this use case.

    - On RHEL/CentOS 7 or Fedora 24 or older distros, use
      _/usr/include/linux/fuse.h_ (provided by the kernel-headers package).

    - On RHEL/CentOS 8 or Fedora 25 or newer distros, use
     _contrib/fuse-include/fuse_kernel.h_ from the Glusterfs source tree.

    - On other distros: Glusterfs uses FUSE 7.24, so if the kerrnel's FUSE version
      is higher than this, then use the header in the Glusterfs source tree; else
      use the kernel's version.

Once you located the appropriate header file, build _parsefuse_ with the following command:

```sh
./make.sh <path-to-fuse-header>
```

After a succesful build you will have the binary at _go/bin/parsefuse_.
