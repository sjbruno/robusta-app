#!/bin/sh
# Grava /etc/sudoers.d/robusta. Roda como root UMA vez, pela janela de senha do
# macOS (botão "Autorizar…" do app). Valida com visudo antes de copiar.
# Uso: sh authorize.sh <usuário>
set -eu

USER_NAME="${1:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$DIR/robusta.sudoers.template"

# Só nomes de usuário simples e que existem no Mac.
case "$USER_NAME" in
    '' | *[!A-Za-z0-9._-]*) echo "robusta: usuário inválido" >&2; exit 64 ;;
esac
/usr/bin/id -u "$USER_NAME" >/dev/null 2>&1 || { echo "robusta: usuário inexistente" >&2; exit 64; }
[ "$(/usr/bin/id -u)" = 0 ] || { echo "robusta: precisa rodar como administrador" >&2; exit 77; }

TMP="$(/usr/bin/mktemp /tmp/robusta.sudoers.XXXXXX)"
trap '/bin/rm -f "$TMP"' EXIT
/usr/bin/sed "s/__USER__/$USER_NAME/" "$TEMPLATE" > "$TMP"
/usr/sbin/visudo -cf "$TMP" >/dev/null
/usr/bin/install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/robusta
echo "robusta: autorização gravada em /etc/sudoers.d/robusta"
