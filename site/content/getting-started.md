---
title: Getting started
weight: 1
description: Install Agentica, run your first program and check it.
---

## Install

{{% release %}}

Download the archive of your system, check it against `SHA256SUMS`, unpack it anywhere (spaces and non-ASCII letters are fine) and put its `bin` folder on your `PATH`. It holds one program and needs no other library.

| System | Archive | Minimum |
|---|---|---|
| Linux x86-64 | `agentica-VERSION-linux-x86_64.tar.gz` | glibc 2.28 |
| Linux ARM64 | `agentica-VERSION-linux-arm64.tar.gz` | glibc 2.28 |
| macOS Intel | `agentica-VERSION-macos-x86_64.tar.gz` | macOS 12 |
| macOS Apple silicon | `agentica-VERSION-macos-arm64.tar.gz` | macOS 12, native (no Rosetta) |
| Windows x86-64 | `agentica-VERSION-windows-x86_64.zip` | Windows 10 (system DLLs and the UCRT; no MSYS2 or Visual C++ redistributable) |

```sh
sha256sum -c --ignore-missing SHA256SUMS   # macOS: shasum -a 256 -c ... ; Windows: Get-FileHash
tar -xzf agentica-VERSION-linux-x86_64.tar.gz   # Windows: Expand-Archive
```

- The archives are not developer-signed or notarized (macOS programs carry only the ad hoc signature Apple silicon requires). `SHA256SUMS` is the only proof of origin.
- macOS blocks a browser download: run `xattr -d com.apple.quarantine bin/agentica` (a `curl` download has no mark). Windows SmartScreen may warn once.
- `TCP`, `TLS` and `std/http` run and are tested on Linux, macOS and Windows.

### Install with Nix

Needs flakes enabled (`experimental-features = nix-command flakes` in `nix.conf`). Save this as `flake.nix` in your project:

```nix
{
  description = "Agentica development environment using precompiled releases";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      version = "0.38.0";
      releases = {
        x86_64-linux = {
          platform = "linux-x86_64";
          hash = "sha256-40Uq3BxwQjlwKE4p+Q6lS2iQATfaXYDxZQwkO1aMVGQ=";
        };
        aarch64-linux = {
          platform = "linux-arm64";
          hash = "sha256-hO+qvPIatXhAeknp4P21ZDFsK6YP7T3LKuuBaIBPmFU=";
        };
        aarch64-darwin = {
          platform = "macos-arm64";
          hash = "sha256-lQwaOLyLWxqSISRTrUCe3n1hYcSawwczEBd4ieal/Ic=";
        };
        x86_64-darwin = {
          platform = "macos-x86_64";
          hash = "sha256-VzJpw8jWO2rd2azNhmd15NsoBcZmqCWAFmuAw+aNoPY=";
        };
      };
      forAllSystems = nixpkgs.lib.genAttrs (builtins.attrNames releases);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          release = releases.${system};
        in
        rec {
          agentica = pkgs.stdenvNoCC.mkDerivation {
            pname = "agentica";
            inherit version;
            src = pkgs.fetchurl {
              url = "https://github.com/agentica-lang/agentica/releases/download/${version}/agentica-${version}-${release.platform}.tar.gz";
              inherit (release) hash;
            };
            nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
            dontConfigure = true;
            dontBuild = true;
            dontStrip = true;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r bin include LICENSE NOTICE licenses "$out/"
              runHook postInstall
            '';
            meta = {
              description = "Agentica programming language";
              homepage = "https://www.agentica-lang.com/agentica/";
              platforms = builtins.attrNames releases;
              mainProgram = "agentica";
            };
          };
          default = agentica;
        });
      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShellNoCC {
          packages = [ self.packages.${system}.agentica ];
        };
      });
    };
}
```

`nix develop` opens a shell with `agentica` on the `PATH`, and `nix build` writes `./result/bin/agentica`. The flake covers Linux x86-64 and ARM64, and macOS Intel and Apple silicon; Windows is not covered.

To move to a newer release, change `version` and each `hash`. `nix store prefetch-file --json <archive URL>` prints the `hash` in the form the flake needs (`nix-prefetch-url` prints a base32 hash instead).

### Install it with your coding agent

Paste this prompt into a coding agent (Claude Code, Codex, OpenCode, pi...) to install the latest release and its `agentica-programming` skill for your user, with no `sudo`.

```prompt
Install the latest Agentica release for this machine at ~/.local/bin/agentica. From https://github.com/agentica-lang/agentica/releases/latest, download the archive for this OS and CPU and the SHA256SUMS file. Check the archive's SHA-256 against SHA256SUMS and stop if it does not match. Unpack it into ~/.local/share/agentica/ and link ~/.local/bin/agentica to the bin/agentica inside the unpacked folder. Do not use sudo. Run `agentica --version`, and tell me if ~/.local/bin is not on my PATH. Then install the `agentica-programming` skill of the same release: get the folder .agents/skills/agentica-programming/ (SKILL.md and references/) from the source archive https://github.com/agentica-lang/agentica/archive/refs/tags/TAG.tar.gz, with TAG the release tag (or from a sparse git clone at that tag), and copy the whole folder into your own skills folder (for example ~/.claude/skills/ for Claude Code), replacing any older copy.
```

On Windows, tell the agent to use `%LOCALAPPDATA%\Programs\agentica` and to add its `bin` folder to the user `PATH`.

### Build from source

Needs a C11 compiler and `make`; on Linux also `libssl-dev`, `libgc-dev`, `zlib1g-dev` and `pkg-config` (OpenSSL 3, libgc 8.2 or newer, zlib). The build starts from the checked-in `bootstrap/stage0.agcb` and needs no other tool. It also runs on macOS (Xcode command line tools) and Windows (MSYS2 UCRT64 with GCC).

```sh
git clone https://github.com/agentica-lang/agentica.git
cd agentica
git submodule update --init
make    # writes dist/agentica
```

A default build links the system OpenSSL, so `dist/agentica` runs only where it is installed; the release archive is portable. `AGENTICA_GC=vendored`, `AGENTICA_OPENSSL=vendored` and `AGENTICA_ZLIB=vendored` build the bundled copies, each on its own (only OpenSSL needs Perl 5 and a few minutes). Pass them to every `make` command, or export them.

## Hello, world

```agentica
def main() -> Void # every program starts at main
  puts("Hello, world!")
end
```

Save it as `hello.agc` and run it:

```sh
agentica hello.agc
```

```output
Hello, world!
```

## Check

`agentica check hello.agc` checks types without running and prints `check ok`, or an error with a stable code such as `CHECK-TYPE-MISMATCH` ([Check and errors](/cli/#check-and-errors)).

## Next

Take the [language tour](/tour/), then look up the builtins in the [library](/library/).
