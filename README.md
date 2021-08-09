`ghcup` makes it easy to install specific versions of `ghc` on GNU/Linux,
macOS (aka Darwin), FreeBSD and Windows and can also bootstrap a fresh Haskell developer environment from scratch.
It follows the unix UNIX philosophy of [do one thing and do it well](https://en.wikipedia.org/wiki/Unix_philosophy#Do_One_Thing_and_Do_It_Well).

Similar in scope to [rustup](https://github.com/rust-lang-nursery/rustup.rs), [pyenv](https://github.com/pyenv/pyenv) and [jenv](http://www.jenv.be).

## Table of Contents

   * [Installation](#installation)
     * [Simple bootstrap](#simple-bootstrap)
     * [Manual install](#manual-install)
     * [Vim integration](#vim-integration)
   * [Usage](#usage)
     * [Configuration](#configuration)
     * [Manpages](#manpages)
     * [Shell-completion](#shell-completion)
     * [Cross support](#cross-support)
     * [XDG support](#xdg-support)
     * [Env variables](#env-variables)
     * [Installing custom bindists](#installing-custom-bindists)
     * [Tips and tricks](#tips-and-tricks)
     * [Stack hooks](#stack-hooks)
     * [Sharing MSys2 between stack and ghcup](#sharing-msys2-between-stack-and-ghcup)
   * [Design goals](#design-goals)
   * [How](#how)
   * [Known users](#known-users)
   * [Known problems](#known-problems)
   * [FAQ](#faq)

## Installation

### Simple bootstrap

Follow the instructions at [https://www.haskell.org/ghcup/](https://www.haskell.org/ghcup/)

### Manual install

Download the binary for your platform at [https://downloads.haskell.org/~ghcup/](https://downloads.haskell.org/~ghcup/)
and place it into your `PATH` anywhere.

Then adjust your `PATH` in `~/.bashrc` (or similar, depending on your shell) like so:

```sh
export PATH="$HOME/.cabal/bin:$HOME/.ghcup/bin:$PATH"
```

### Vim integration

See [ghcup.vim](https://github.com/hasufell/ghcup.vim).

## Usage

See `ghcup --help`.

For the simple interactive TUI, run:

```sh
ghcup tui
```

For the full functionality via cli:

```sh
# list available ghc/cabal versions
ghcup list

# install the recommended GHC version
ghcup install ghc

# install a specific GHC version
ghcup install ghc 8.2.2

# set the currently "active" GHC version
ghcup set ghc 8.4.4

# install cabal-install
ghcup install cabal

# update ghcup itself
ghcup upgrade
```

GHCup works very well with [`cabal-install`](https://hackage.haskell.org/package/cabal-install), which
handles your haskell packages and can demand that [a specific version](https://cabal.readthedocs.io/en/latest/nix-local-build.html#cfg-flag---with-compiler)  of `ghc` is available, which `ghcup` can do.

### Configuration

A configuration file can be put in `~/.ghcup/config.yaml`. The default config file
explaining all possible configurations can be found in this repo: [config.yaml](./config.yaml).

Partial configuration is fine. Command line options always override the config file settings.

### Manpages

For man pages to work you need [man-db](http://man-db.nongnu.org/) as your `man` provider, then issue `man ghc`. Manpages only work for the currently set ghc.
`MANPATH` may be required to be unset.

### Shell-completion

Shell completions are in `shell-completions`.

For bash: install `shell-completions/bash`
as e.g. `/etc/bash_completion.d/ghcup` (depending on distro)
and make sure your bashrc sources the startup script
(`/usr/share/bash-completion/bash_completion` on some distros).

### Cross support

ghcup can compile and install a cross GHC for any target. However, this
requires that the build host has a complete cross toolchain and various
libraries installed for the target platform.

Consult the GHC documentation on the [prerequisites](https://gitlab.haskell.org/ghc/ghc/-/wikis/building/cross-compiling#tools-to-install).
For distributions with non-standard locations of cross toolchain and
libraries, this may need some tweaking of `build.mk` or configure args.
See `ghcup compile ghc --help` for further information.

### XDG support

To enable XDG style directories, set the environment variable `GHCUP_USE_XDG_DIRS` to anything.

Then you can control the locations via XDG environment variables as such:

* `XDG_DATA_HOME`: GHCs will be unpacked in `ghcup/ghc` subdir (default: `~/.local/share`)
* `XDG_CACHE_HOME`: logs and download files will be stored in `ghcup` subdir (default: `~/.cache`)
* `XDG_BIN_HOME`: binaries end up here (default: `~/.local/bin`)
* `XDG_CONFIG_HOME`: the config file is stored in `ghcup` subdir as `config.yaml` (default: `~/.config`)

**Note that `ghcup` makes some assumptions about structure of files in `XDG_BIN_HOME`. So if you have other tools
installing e.g. stack/cabal/ghc into it, this will likely clash. In that case consider disabling XDG support.**

### Env variables

This is the complete list of env variables that change GHCup behavior:

* `GHCUP_USE_XDG_DIRS`: see [XDG support](#xdg-support) above
* `TMPDIR`: where ghcup does the work (unpacking, building, ...)
* `GHCUP_INSTALL_BASE_PREFIX`: the base of ghcup (default: `$HOME`)
* `GHCUP_CURL_OPTS`: additional options that can be passed to curl
* `GHCUP_WGET_OPTS`: additional options that can be passed to wget
* `GHCUP_SKIP_UPDATE_CHECK`: Skip the (possibly annoying) update check when you run a command
* `CC`/`LD` etc.: full environment is passed to the build system when compiling GHC via GHCup

On windows, there are additional variables:

* `GHCUP_MSYS2`: where to find msys2, so we can invoke shells and other cool stuff

### Installing custom bindists

There are a couple of good use cases to install custom bindists:

1. manually built bindists (e.g. with patches)
  - example: `ghcup install ghc -u 'file:///home/mearwald/tmp/ghc-eff-patches/ghc-8.10.2-x86_64-deb10-linux.tar.xz' 8.10.2-eff`
2. GHC head CI bindists
  - example: `ghcup install ghc -u 'https://gitlab.haskell.org/api/v4/projects/1/jobs/artifacts/master/raw/ghc-x86_64-fedora27-linux.tar.xz?job=validate-x86_64-linux-fedora27' head`
3. DWARF bindists
  - example: `ghcup install ghc -u 'https://downloads.haskell.org/~ghc/8.10.2/ghc-8.10.2-x86_64-deb10-linux-dwarf.tar.xz' 8.10.2-dwarf`

Since the version parser is pretty lax, `8.10.2-eff` and `head` are both valid versions
and produce the binaries `ghc-8.10.2-eff` and `ghc-head` respectively.
GHCup always needs to know which version the bindist corresponds to (this is not automatically
detected).

### Tips and tricks

#### with_ghc wrapper (e.g. for HLS)

Due to some HLS [bugs](https://github.com/mpickering/hie-bios/issues/194) it's necessary that the `ghc` in PATH
is the one defined in `cabal.project`. With some simple shell functions, we can start our editor with the appropriate
path prepended.

For bash, in e.g. `~/.bashrc` define:

```sh
with_ghc() {
  local np=$(ghcup --offline whereis -d ghc $1 || { ghcup --cache install ghc $1 && ghcup whereis -d ghc $1 ;})
  if [ -e "${np}" ] ; then
    shift
    PATH="$np:$PATH" "$@"
  else
    >&2 echo "Cannot find or install GHC version $1"
    return 1
  fi
}
```

For fish shell, in e.g. `~/.config/fish/config.fish` define:

```fish
function with_ghc
  set --local np (ghcup --offline whereis -d ghc $argv[1] ; or begin ghcup --cache install ghc $argv[1] ; and ghcup whereis -d ghc $argv[1] ; end)
  if test -e "$np"
    PATH="$np:$PATH" $argv[2..-1]
  else
    echo "Cannot find or install GHC version $argv[1]" 1>&2
    return 1
  end
end
```

Then start a new shell and issue:

```sh
# replace 'code' with your editor
with_ghc 8.10.5 code path/to/haskell/source
```

Cabal and HLS will now see `8.10.5` as the primary GHC, without the need to
run `ghcup set` all the time when switching between projects.

### Stack hooks

GHCup distributes a patched Stack, which has support for custom installation hooks, see:

* https://github.com/commercialhaskell/stack/pull/5585

Usually, the bootstrap script will already install a hook for you. If not,
download it [here](https://gitlab.haskell.org/haskell/ghcup-hs/-/tree/master/hooks/stack/ghc-install.sh),
place it in `~/.stack/hooks/ghc-install.sh` and make sure it's executable.

Hooks aren't run when `system-ghc: true` is set in `stack.yaml`. If you want stack
to never fall back to its own installation logic if ghcup fails, run the following command:

```sh
stack config set install-ghc false --global
```

### Sharing MSys2 between stack and ghcup

You can tell stack to use GHCup's MSys2 installation. Add the following lines to `~/.stack/config.yaml`:

```yml
skip-msys: true
extra-path:
  - "C:\\ghcup\\msys64\\usr\\bin"
  - "C:\\ghcup\\msys64\\mingw64\\bin"
extra-include-dirs: "C:\\ghcup\\msys64\\mingw64\\include"
extra-lib-dirs: "C:\\ghcup\\msys64\\mingw64\\lib"
```

## Design goals

1. simplicity
2. non-interactive
3. portable (eh)
4. do one thing and do it well (UNIX philosophy)

### Non-goals

1. invoking `sudo`, `apt-get` or *any* package manager
2. handling system packages
3. handling cabal projects
4. being a stack alternative

## How

Installs a specified GHC version into `~/.ghcup/ghc/<ver>`, and places `ghc-<ver>` symlinks in `~/.ghcup/bin/`.

Optionally, an unversioned `ghc` link can point to a default version of your choice.

This uses precompiled GHC binaries that have been compiled on fedora/debian by [upstream GHC](https://www.haskell.org/ghc/download_ghc_8_6_1.html#binaries).

Alternatively, you can also tell it to compile from source (note that this might fail due to missing requirements).

In addition this script can also install `cabal-install`.

## Known users

* Github action [haskell/actions/setup](https://github.com/haskell/actions/tree/main/setup)
* [vabal](https://github.com/Franciman/vabal)

## Known problems

### Custom ghc version names

When installing ghc bindists with custom version names as outlined in
[installing custom bindists](#installing-custom-bindists), then cabal might
be unable to find the correct `ghc-pkg` (also see [#73](https://gitlab.haskell.org/haskell/ghcup-hs/-/issues/73))
if you use `cabal build --with-compiler=ghc-foo`. Instead, point it to the full path, such as:
`cabal build --with-compiler=$HOME/.ghcup/ghc/<version-name>/bin/ghc` or set that GHC version
as the current one via: `ghcup set ghc <version-name>`.

This problem doesn't exist for regularly installed GHC versions.

### Limited distributions supported

Currently only GNU/Linux distributions compatible with the [upstream GHC](https://www.haskell.org/ghc/download_ghc_8_6_1.html#binaries) binaries are supported.

### Precompiled binaries

Since this uses precompiled binaries you may run into
several problems.

#### Missing libtinfo (ncurses)

You may run into problems with *ncurses* and **missing libtinfo**, in case
your distribution doesn't use the legacy way of building
ncurses and has no compatibility symlinks in place.

Ask your distributor on how to solve this or
try to compile from source via `ghcup compile <version>`.

#### Libnuma required

This was a [bug](https://ghc.haskell.org/trac/ghc/ticket/15688) in the build system of some GHC versions that lead to
unconditionally enabled libnuma support. To mitigate this you might have to install the libnuma
package of your distribution. See [here](https://gitlab.haskell.org/haskell/ghcup/issues/58) for a discussion.

### Compilation

Although this script can compile GHC for you, it's just a very thin
wrapper around the build system. It makes no effort in trying
to figure out whether you have the correct toolchain and
the correct dependencies. Refer to [the official docs](https://ghc.haskell.org/trac/ghc/wiki/Building/Preparation/Linux)
on how to prepare your environment for building GHC.

### Windows support

Windows support is in early stages. Since windows doesn't support symbolic links properly,
ghcup uses a [shimgen wrapper](https://github.com/71/scoop-better-shimexe). It seems to work
well, but there may be unknown issues with that approach.

Windows 7 and Powershell 2.0 aren't well supported at the moment, also see:

- https://gitlab.haskell.org/haskell/ghcup-hs/-/issues/140
- https://gitlab.haskell.org/haskell/ghcup-hs/-/issues/197

## FAQ

### Why reimplement stack?

GHCup is not a reimplementation of stack. The only common part is automatic installation of GHC,
but even that differs in scope and design.

### Why should I use ghcup over stack?

GHCup is not a replacement for stack. Instead, it supports installing and managing stack versions.
It does the same for cabal, GHC and HLS. As such, It doesn't make a workflow choice for you.

### Why should I let ghcup manage stack?

You don't need to. However, some users seem to prefer to have a central tool that manages cabal and stack
at the same time. Additionally, it can allow better sharing of GHC installation across these tools.
Also see:

* https://docs.haskellstack.org/en/stable/yaml_configuration/#system-ghc
* https://github.com/commercialhaskell/stack/pull/5585

### Why does ghcup not use stack code?

Oddly, this question has been asked a couple of times. For the curious, here are a few reasons:

1. GHCup started as a shell script. At the time of rewriting it in Haskell, the authors didn't even know that stack exposes *some* of its [installation API](https://hackage.haskell.org/package/stack-2.5.1.1/docs/Stack-Setup.html)
2. Even if they did, it doesn't seem it would have satisfied their needs
	  - it didn't support cabal installation, which was the main motivation behind GHCup back then
	  - depending on a codebase as big as stack for a central part of one's application without having a short contribution pipeline would likely have caused stagnation or resulted in simply copy-pasting the relevant code in order to adjust it
	  - it's not clear how GHCup would have been implemented with the provided API. It seems the codebases are fairly different. GHCup does a lot of symlink handling to expose a central `bin/` directory that users can easily put in PATH, without having to worry about anything more. It also provides explicit removal functionality, GHC cross-compilation, a TUI, etc etc.
3. GHCup is built around unix principles and supposed to be simple.

### Why not unify...

#### ...stack and Cabal and do away with standalone installers

GHCup is not involved in such decisions. cabal-install and stack might have a
sufficiently different user experience to warrant having a choice.

#### ...installer implementations and have a common library

This sounds like an interesting goal. However, GHC installation isn't a hard engineering problem
and the shared code wouldn't be too exciting. For such an effort to make sense, all involved
parties would need to collaborate and have a short pipeline to get patches in.

It's true this would solve the integration problem, but following unix principles, we can
do similar via **hooks**. Both cabal and stack can support installation hooks. These hooks
can then call into ghcup or anything else, also see:

* https://github.com/haskell/cabal/issues/7394
* https://github.com/commercialhaskell/stack/pull/5585

#### ...installers (like, all of it)

So far, there hasn't been an **open** discussion about this. Is this even a good idea?
Sometimes projects converge eventually if their overlap is big enough, sometimes they don't.

While unification sounds like a simplification of the ecosystem, it also takes away choice.
Take `curl` and `wget` as an example.

How bad do we need this?

### Why not support windows?

Windows is supported since GHCup version 0.1.15.1.

### Why the haskell reimplementation?

GHCup started as a portable posix shell script of maybe 50 LOC. GHC installation itself can be carried out in
about ~3 lines of shell code (download, unpack , configure+make install). However, much convenient functionality
has been added since, as well as ensuring that all operations are safe and correct. The shell script ended up with
over 2k LOC, which was very hard to maintain.

The main concern when switching from a portable shell script to haskell was platform/architecture support.
However, ghcup now re-uses GHCs CI infrastructure and as such is perfectly in sync with all platforms that
GHC supports.

### Is GHCup affiliated with the Haskell Foundation?

There has been some collaboration: Windows and Stack support were mainly requested by the Haskell Foundation
and those seemed interesting features to add.

Other than that, GHCup is dedicated only to its users and is supported by haskell.org through hosting and CI
infrastructure.
