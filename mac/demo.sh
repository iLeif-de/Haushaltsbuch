#!/bin/zsh
# Frische Demodatenbank anlegen und das Programm damit öffnen. Aufruf im Ordner
# mac mit ./demo.sh, oder ./demo.sh <pfad> für einen anderen Ort. So prüft der
# Nutzer jede Änderung, siehe CLAUDE.md, Abschnitt Prüfen.
#
# Die Demodatenbank wird bei jedem Aufruf neu angelegt, eine alte am selben Ort
# wird überschrieben. Die echte Datenbank fasst das Werkzeug nie an.
set -e
cd "$(dirname "$0")"

DB="${1:-/tmp/haushalt_demo/haushaltsbuch.sqlite}"
BAU=/tmp/haushalt-bau

echo "Bauen"
xcodegen generate > /dev/null
xcodebuild build -project Haushaltsbuch.xcodeproj -scheme Demodaten \
  -derivedDataPath "$BAU" -quiet 2>&1 | grep -v "Using the first of multiple\|platform:macOS\|^{" || true
xcodebuild build -project Haushaltsbuch.xcodeproj -scheme Haushaltsbuch \
  -derivedDataPath "$BAU" -quiet 2>&1 | grep -v "Using the first of multiple\|platform:macOS\|^{" || true

"$BAU/Build/Products/Debug/Demodaten.app/Contents/MacOS/Demodaten" --ersetzen "$DB"

# open statt direkt starten, dann ist es ein gewöhnlicher Start mit Symbol im
# Dock. Die Datenbank kommt über die Umgebung, nie über den echten Ort.
open -n --env HAUSHALT_DB="$DB" "$BAU/Build/Products/Debug/Haushaltsbuch.app"
