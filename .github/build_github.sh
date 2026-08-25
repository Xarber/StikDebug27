#!/bin/sh
set -eu

app_path="$archive_path.xcarchive/Products/Applications/$scheme.app"

test -d "$app_path"
rm -rf Payload "$scheme.ipa"
mkdir Payload
cp -R "$app_path" Payload/
zip -qry "$scheme.ipa" Payload -x '._*' -x '.DS_Store' -x '__MACOSX'
