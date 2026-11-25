#!/bin/sh
# Remove /etc/sudoers.d/robusta. Roda como root, pela janela de senha do macOS.
# Os agendamentos já criados continuam no pmset até vencerem ou serem cancelados.
set -eu
[ "$(/usr/bin/id -u)" = 0 ] || { echo "robusta: precisa rodar como administrador" >&2; exit 77; }
/bin/rm -f /etc/sudoers.d/robusta
echo "robusta: autorização removida"
