{ ... }:
{
  # The head-end binary answers GET /api/version out of three package-level
  # variables, and the Go linker drops an `-X` naming a symbol it cannot find
  # without a word: a stamp whose name is not one of upstream's builds green and
  # ships a binary reporting `version: 0, commit: abcd1234` — the defaults its
  # source declares. So this asserts that every symbol the build stamps is a
  # variable the pinned upstream source declares, read off that source, because
  # a second list of the names in this repo would be a third thing free to
  # disagree with the binary.
  #
  # A green run does not claim the running pod answers with those values. That
  # stays a deploy-time check:
  #   kubectl -n default exec deploy/swap-head-end -- wget -qO- http://127.0.0.1:8080/api/version
  perSystem =
    { pkgs, lib, ... }:
    let
      headEnd = pkgs.callPackage ./hosts/mjolnir/_swapk8s.nix { };
      llamaSwap = headEnd.passthru.llamaSwap;

      # The linker flags and the source tree of the derivation that builds the
      # binary, both taken from that derivation: the check carries no copy of
      # either, so neither can drift from what the pod runs.
      ldflags = builtins.toFile "llama-swap-ldflags" (lib.concatStringsSep "\n" llamaSwap.ldflags + "\n");

      # Indented with spaces rather than gofmt's tabs: nix strips an indented
      # string by its least-indented line and a tab counts as no indentation at
      # all, so a tab-indented file would be written out still carrying this
      # file's own leading whitespace.
      stampCheck = builtins.toFile "stamp-check.go" ''
        // Reports whether every `-X main.<symbol>` in a linker flag list names a
        // package-level variable of the package being linked. The Go linker drops an
        // -X naming a symbol it cannot find without a word, so a flag list can be
        // green while the binary answers with the defaults its own source declares.
        package main

        import (
            "bufio"
            "fmt"
            "go/ast"
            "go/build"
            "go/parser"
            "go/token"
            "os"
            "path/filepath"
            "sort"
            "strings"
        )

        func main() {
            if len(os.Args) != 5 {
                fatal(fmt.Errorf("usage: %s <source-dir> <ldflags-file> <goos> <goarch>", filepath.Base(os.Args[0])))
            }
            dir, flagsFile, goos, goarch := os.Args[1], os.Args[2], os.Args[3], os.Args[4]

            stamped, err := stamped(flagsFile)
            if err != nil {
                fatal(err)
            }
            if len(stamped) == 0 {
                fatal(fmt.Errorf("%s stamps no -X main.<symbol>, so the binary reports the defaults its source declares", flagsFile))
            }

            declared, err := declared(dir, goos, goarch)
            if err != nil {
                fatal(err)
            }

            var missing []string
            for _, symbol := range stamped {
                if !declared[symbol] {
                    missing = append(missing, symbol)
                }
            }
            if len(missing) > 0 {
                fatal(fmt.Errorf("the build stamps %s, which package main in %s does not declare; the linker drops it silently\n  declared by package main: %s",
                    strings.Join(missing, ", "), dir, strings.Join(names(declared), ", ")))
            }

            fmt.Printf("stamped %s: package main declares each of them\n", strings.Join(stamped, ", "))
        }

        // stamped returns the symbol half of every `-X main.<symbol>=<value>` in a
        // file holding one linker flag per line.
        func stamped(flagsFile string) ([]string, error) {
            file, err := os.Open(flagsFile)
            if err != nil {
                return nil, err
            }
            defer file.Close()

            var symbols []string
            seen := map[string]bool{}
            lines := bufio.NewScanner(file)
            for lines.Scan() {
                spec, isStamp := strings.CutPrefix(strings.TrimSpace(lines.Text()), "-X")
                if !isStamp {
                    continue
                }
                // The linker takes both `main.version=264` and `main.version 264`.
                fields := strings.Fields(strings.ReplaceAll(spec, "=", " "))
                if len(fields) == 0 {
                    continue
                }
                pkg, symbol, named := strings.Cut(fields[0], ".")
                if !named || pkg != "main" || symbol == "" || seen[symbol] {
                    continue
                }
                seen[symbol] = true
                symbols = append(symbols, symbol)
            }
            return symbols, lines.Err()
        }

        // declared returns every package-level `var` of the files the named target
        // builds from dir: the file set the linker sees, with build constraints and
        // test files settled by go/build rather than by a pattern matched here.
        func declared(dir, goos, goarch string) (map[string]bool, error) {
            ctx := build.Default
            ctx.GOOS = goos
            ctx.GOARCH = goarch

            pkg, err := ctx.ImportDir(dir, 0)
            if err != nil {
                return nil, fmt.Errorf("reading the package in %s: %w", dir, err)
            }
            if pkg.Name != "main" {
                return nil, fmt.Errorf("%s is package %s, not main: no -X main.<symbol> names anything in it", dir, pkg.Name)
            }
            if len(pkg.InvalidGoFiles) > 0 {
                return nil, fmt.Errorf("go/build could not classify %s in %s, so what it declares is unknown", strings.Join(pkg.InvalidGoFiles, ", "), dir)
            }

            vars := map[string]bool{}
            fset := token.NewFileSet()
            for _, file := range pkg.GoFiles {
                parsed, err := parser.ParseFile(fset, filepath.Join(dir, file), nil, parser.SkipObjectResolution)
                if err != nil {
                    return nil, fmt.Errorf("parsing %s: %w", file, err)
                }
                for _, decl := range parsed.Decls {
                    group, isVarBlock := decl.(*ast.GenDecl)
                    if !isVarBlock || group.Tok != token.VAR {
                        continue
                    }
                    for _, spec := range group.Specs {
                        value, isVar := spec.(*ast.ValueSpec)
                        if !isVar {
                            continue
                        }
                        for _, ident := range value.Names {
                            if ident.Name != "_" {
                                vars[ident.Name] = true
                            }
                        }
                    }
                }
            }
            return vars, nil
        }

        func names(set map[string]bool) []string {
            var sorted []string
            for name := range set {
                sorted = append(sorted, name)
            }
            sort.Strings(sorted)
            return sorted
        }

        func fatal(err error) {
            fmt.Fprintf(os.Stderr, "error: %v\n", err)
            os.Exit(1)
        }
      '';
    in
    {
      checks.swap-head-end-version-stamp =
        pkgs.runCommand "swap-head-end-version-stamp"
          {
            inherit ldflags stampCheck;
            src = llamaSwap.src;
            nativeBuildInputs = [ pkgs.go ];
          }
          ''
            # `go run` compiles into GOCACHE and reads its config from HOME, and the
            # sandbox offers neither; the proxy and toolchain are switched off
            # because a standard-library program needs no module of anything, and
            # cgo because it needs no C toolchain and reads a source tree the
            # package itself compiles with cgo off.
            export HOME="$TMPDIR" GOCACHE="$TMPDIR/go-build" GOPATH="$TMPDIR/go" GOWORK=off GOPROXY=off GOTOOLCHAIN=local CGO_ENABLED=0

            # The target the package is built for, read off its own derivation: the
            # file set the linker sees, and so the names a stamp can name, is that
            # target's.
            go run "$stampCheck" "$src" "$ldflags" ${lib.escapeShellArg llamaSwap.drvAttrs.GOOS} ${lib.escapeShellArg llamaSwap.drvAttrs.GOARCH}

            touch "$out"
          '';
    };
}
