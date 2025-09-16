#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

BASEDIR="$(dirname "$(dirname "$0")")"

mkdir -vp $BASEDIR/_site/root $BASEDIR/_site/registrars

$BASEDIR/bin/registrars.pl $BASEDIR/_site/registrars
exit

$BASEDIR/bin/root.pl > $BASEDIR/_site/root/_all.json
