#!/bin/sh
# Atualiza App/Localizable.xcstrings com os textos que o compilador extraiu no último build.
# O Xcode faz isso sozinho; com xcodebuild, rode depois de compilar:
#   xcodebuild … build && sh Tools/sync-strings.sh
set -eu
DERIVED="${1:-build/dd}"
FILES=$(find "$DERIVED/Build/Intermediates.noindex/Robusta.build" -path "*/Robusta.build/Objects-normal/*" -name "*.stringsdata")
[ -n "$FILES" ] || { echo "nenhum .stringsdata: compile antes" >&2; exit 1; }
ARGS=""
for f in $FILES; do ARGS="$ARGS --stringsdata $f"; done
# shellcheck disable=SC2086
xcrun xcstringstool sync App/Localizable.xcstrings $ARGS
echo "chaves: $(xcrun xcstringstool print App/Localizable.xcstrings | grep -c '^')"
