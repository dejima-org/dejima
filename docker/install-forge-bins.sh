#!/bin/bash
# Installs each forge's CLIs into /usr/local/bin, from the `install` list in
# that forge's manifest rather than from whatever happens to sit under its
# bin/ directory.
#
# The declaration is the point. forges/ is inside the audit's TCB, so an
# operator reading forges/<name>/forge.conf is entitled to conclude that a
# forge with `install =` empty puts nothing executable in the image. A copy
# keyed on directory layout instead would make that reading false: any file
# added under any forges/*/bin/ would ship into /usr/local/bin of every image
# with no declaration to review and no error to notice.
#
# So the two halves are checked against each other and a mismatch fails the
# build, in either direction: a declared file that is missing, and a file
# present under a bin/ that no manifest declares. Failing here is loud and at
# build time; the alternative is a silent difference between what the manifest
# says ships and what does.
#
# A manifest is data, parsed the way dejima-provider-lib.sh parses it and for
# the same reason - forges/ can be the mounted workspace when dejima sandboxes
# its own checkout, so a manifest that was sourced would mean a session could
# run code in the next image build. Only the `install` key is read here, and
# each element is re-checked against the relpath shape the manifest schema
# already requires, because this parser runs where that one does not.
set -euo pipefail

root="${1:?usage: install-forge-bins.sh <forges-dir> <real-dir> <bin-dir>}"
real="${2:?usage: install-forge-bins.sh <forges-dir> <real-dir> <bin-dir>}"
dest="${3:?usage: install-forge-bins.sh <forges-dir> <real-dir> <bin-dir>}"

# The real CLI goes in <real-dir> and <bin-dir> gets a symlink to it. That
# indirection is what lets entrypoint.sh replace the symlink with
# docker/forge-guard.sh for whichever command a workflow blocks, while the
# guard still has a fixed path to exec the real one through. A forge with
# nothing blocked keeps the symlink and pays nothing.
mkdir -p "$real" "$dest"

declared_any=0
for conf in "$root"/*/forge.conf; do
    [ -f "$conf" ] || continue
    forge_dir="${conf%/forge.conf}"
    forge="${forge_dir##*/}"

    # The `install = ...` line alone. Last assignment wins, matching the
    # manifest parser, and a line naming no key is ignored the same way.
    value=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in ''|'#'*|';'*) continue ;; *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [ "$key" = install ] || continue
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
    done < "$conf"

    declared=""
    for rel in $value; do
        # "system:<name>" is a CLI the image already provides - `gh`, which
        # comes from a package rather than from this repo. It still has to sit
        # behind the shadow, because that is the fixed path forge-guard.sh
        # execs the real command through, and a forge whose CLI never gets
        # there has a merge block the entrypoint cannot enforce. A symlink
        # rather than a copy: it is not ours, and it can be large.
        case "$rel" in
            system:*)
                name="${rel#system:}"
                case "$name" in
                    ''|*/*|*..*)
                        echo "forge $forge declares a bad system command: $rel" >&2
                        exit 1 ;;
                esac
                # Resolved now rather than trusted: a name that is not in the
                # image yet would otherwise become a dangling symlink, and the
                # first sign of it would be the guard exiting 127 mid-session.
                path="$(command -v "$name" 2>/dev/null || true)"
                if [ -z "$path" ]; then
                    echo "forge $forge declares $rel, which this image does not provide" >&2
                    exit 1
                fi
                ln -sf "$path" "$real/$name"
                ln -sf "$real/$name" "$dest/$name"
                declared="$declared $name"
                declared_any=1
                continue ;;
            /*|*..*|"")
                echo "forge $forge declares an out-of-tree install path: $rel" >&2
                exit 1 ;;
        esac
        if [ ! -f "$forge_dir/$rel" ]; then
            echo "forge $forge declares $rel, which it does not ship" >&2
            exit 1
        fi
        install -m 755 "$forge_dir/$rel" "$real/"
        ln -sf "$real/${rel##*/}" "$dest/${rel##*/}"
        declared="$declared ${rel##*/}"
        declared_any=1
    done

    # The other direction: anything executable-shaped this forge ships but did
    # not declare. Undeclared means it does not ship, and the build says so.
    if [ -d "$forge_dir/bin" ]; then
        for f in "$forge_dir"/bin/*; do
            [ -f "$f" ] || continue
            case " $declared " in
                *" ${f##*/} "*) ;;
                *)  echo "forge $forge ships ${f#"$forge_dir/"} but its manifest does not declare it" >&2
                    exit 1 ;;
            esac
        done
    fi
done

[ "$declared_any" = 1 ] || echo "no forge declared any CLI to install" >&2
