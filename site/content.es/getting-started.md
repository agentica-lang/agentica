---
title: Primeros pasos
weight: 1
description: Instala Agentica, ejecuta tu primer programa y compruébalo.
source_hash: "a63ab4186c96"
---

## Instalar {#install}

{{% release %}}

Descarga el archivo comprimido de tu sistema, compruébalo con `SHA256SUMS`, descomprímelo donde quieras (los espacios y las letras no ASCII están bien) y pon su carpeta `bin` en tu `PATH`. Contiene un solo programa y no necesita ninguna otra biblioteca.

| Sistema | Archivo | Mínimo |
|---|---|---|
| Linux x86-64 | `agentica-VERSION-linux-x86_64.tar.gz` | glibc 2.28 |
| Linux ARM64 | `agentica-VERSION-linux-arm64.tar.gz` | glibc 2.28 |
| macOS Intel | `agentica-VERSION-macos-x86_64.tar.gz` | macOS 12 |
| macOS Apple silicon | `agentica-VERSION-macos-arm64.tar.gz` | macOS 12, nativo (sin Rosetta) |
| Windows x86-64 | `agentica-VERSION-windows-x86_64.zip` | Windows 10 (DLL del sistema y UCRT; sin MSYS2 ni el redistribuible de Visual C++) |

```sh
sha256sum -c --ignore-missing SHA256SUMS   # macOS: shasum -a 256 -c ... ; Windows: Get-FileHash
tar -xzf agentica-VERSION-linux-x86_64.tar.gz   # Windows: Expand-Archive
```

- Los archivos comprimidos no están firmados por el desarrollador ni notarizados (los programas de macOS solo llevan la firma ad hoc que exige Apple silicon). `SHA256SUMS` es la única prueba de origen.
- macOS bloquea una descarga desde el navegador: ejecuta `xattr -d com.apple.quarantine bin/agentica` (una descarga con `curl` no tiene esa marca). SmartScreen de Windows puede mostrar una advertencia una vez.
- `TCP`, `TLS` y `std/http` funcionan y están probados en Linux, macOS y Windows.

### Instalar con Nix {#install-with-nix}

Necesita tener activados los flakes (`experimental-features = nix-command flakes` en `nix.conf`). Guárdalo como `flake.nix` en tu proyecto:

```nix
{
  description = "Agentica development environment using precompiled releases";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      version = "0.35.0";
      releases = {
        x86_64-linux = {
          platform = "linux-x86_64";
          hash = "sha256-N5sElLhMibEh0In6ubIYeek5pN1+iWYfa+NOcPE/YyI=";
        };
        aarch64-linux = {
          platform = "linux-arm64";
          hash = "sha256-uHlLH4bsmXfAlZlJ5cybFm6hqx5KhSw216y2H7EwTh4=";
        };
        aarch64-darwin = {
          platform = "macos-arm64";
          hash = "sha256-aL4I0DdxBvFUxEnFON26NR+Z1b0nVgpHsUPikKyl/VY=";
        };
        x86_64-darwin = {
          platform = "macos-x86_64";
          hash = "sha256-ka0br1IHcGIS8X1sQy8Wqelcx1yVQcVK+NWaVt2Nj9A=";
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

`nix develop` abre un shell con `agentica` en el `PATH`, y `nix build` escribe `./result/bin/agentica`. El flake cubre Linux x86-64 y ARM64, y macOS Intel y Apple silicon; Windows no está incluido.

Para pasar a una release más nueva, cambia `version` y cada `hash`. `nix store prefetch-file --json <archive URL>` imprime el `hash` en la forma que necesita el flake (`nix-prefetch-url` imprime un hash en base32).

### Instálalo con tu agente de programación {#install-it-with-your-coding-agent}

Pega este prompt en un agente de programación (Claude Code, Codex, OpenCode, pi...) para instalar la última release y su skill `agentica-programming` para tu usuario, sin `sudo`.

```prompt
Install the latest Agentica release for this machine at ~/.local/bin/agentica. From https://github.com/agentica-lang/agentica/releases/latest, download the archive for this OS and CPU and the SHA256SUMS file. Check the archive's SHA-256 against SHA256SUMS and stop if it does not match. Unpack it into ~/.local/share/agentica/ and link ~/.local/bin/agentica to the bin/agentica inside the unpacked folder. Do not use sudo. Run `agentica --version`, and tell me if ~/.local/bin is not on my PATH. Then install the `agentica-programming` skill of the same release: get the folder .agents/skills/agentica-programming/ (SKILL.md and references/) from the source archive https://github.com/agentica-lang/agentica/archive/refs/tags/TAG.tar.gz, with TAG the release tag (or from a sparse git clone at that tag), and copy the whole folder into your own skills folder (for example ~/.claude/skills/ for Claude Code), replacing any older copy.
```

En Windows, dile al agente que use `%LOCALAPPDATA%\Programs\agentica` y que añada su carpeta `bin` al `PATH` del usuario.

### Compilar desde el código fuente {#build-from-source}

Necesita un compilador de C11 y `make`; en Linux, también `libssl-dev`, `libgc-dev`, `zlib1g-dev` y `pkg-config` (OpenSSL 3, libgc 8.2 o más reciente, zlib). La compilación parte de `bootstrap/stage0.agcb`, que viene en el repositorio, y no necesita otra herramienta. También funciona en macOS (las herramientas de línea de comandos de Xcode) y en Windows (MSYS2 UCRT64 con GCC).

```sh
git clone https://github.com/agentica-lang/agentica.git
cd agentica
git submodule update --init
make    # writes dist/agentica
```

Una compilación predeterminada enlaza el OpenSSL del sistema, así que `dist/agentica` solo funciona donde OpenSSL esté instalado; el archivo de la release es portátil. `AGENTICA_GC=vendored`, `AGENTICA_OPENSSL=vendored` y `AGENTICA_ZLIB=vendored` compilan las copias incluidas, cada una por separado (solo OpenSSL necesita Perl 5 y unos minutos). Pásalas a cada comando `make`, o expórtalas.

## Hola, mundo {#hello-world}

```agentica
def main() -> Void # every program starts at main
  puts("Hello, world!")
end
```

Guárdalo como `hello.agc` y ejecútalo:

```sh
agentica hello.agc
```

```output
Hello, world!
```

## Comprobar {#check}

`agentica check hello.agc` comprueba los tipos sin ejecutar el programa e imprime `check ok`, o un error con un código estable, como `CHECK-TYPE-MISMATCH` ([Comprobar y errores](/cli/#check-and-errors)).

## Siguiente {#next}

Haz el [tour del lenguaje](/tour/) y luego consulta las funciones integradas en la [biblioteca](/library/).
