#!/bin/sh

set -eu

library_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
library_path="$library_dir/libidevice_ffi.a"
expected_sha256="2cc3d23eea9bbc01b479c2e9fbf4f06630ed50e486da1bc3ffb34cccc93482dc"

if [ -f "$library_path" ] && [ "$(shasum -a 256 "$library_path" | awk '{print $1}')" = "$expected_sha256" ]; then
  exit 0
fi

temporary_path="$library_path.rebuild"
cat "$library_dir/libidevice_ffi.a.part-00" "$library_dir/libidevice_ffi.a.part-01" > "$temporary_path"

if [ "$(shasum -a 256 "$temporary_path" | awk '{print $1}')" != "$expected_sha256" ]; then
  echo "idevice library checksum verification failed" >&2
  exit 1
fi

mv "$temporary_path" "$library_path"
