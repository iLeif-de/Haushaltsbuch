#!/bin/zsh
# Baut Haushaltsbuch.app, Fassung 2.1, aus dem Programm in Swift. Aufruf im
# Projektordner mit ./bauen.sh. Das Ergebnis liegt danach in dist, als
# Haushaltsbuch.app und als Haushaltsbuch.zip für die Webseite. Nach web/assets im Begleitordner kopiert wird nicht von
# selbst, das Veröffentlichen bleibt ein eigener Schritt.
set -e
cd "$(dirname "$0")"

FASSUNG="2.1.0"
# Die Buildnummer unterscheidet einzelne Bauten derselben Fassung. macOS nutzt
# sie, um eine ersetzte App als neu zu erkennen, und zeigt sie in der About Box
# hinter der Fassung. Zeitstempel statt Zähler, wie beim Programm in Python.
BUILD="$(date +%Y%m%d.%H%M)"
# Gut hundert Megabyte Zwischenstand, die haben im Projektordner in iCloud
# nichts zu suchen
BAU=/tmp/haushalt-release

echo "Projekt erzeugen"
xcodegen generate > /dev/null

echo "Prüfungen"
xcodebuild test -project Haushaltsbuch.xcodeproj -scheme Haushaltsbuch \
  -derivedDataPath "$BAU" -quiet

echo "App bauen, Fassung $FASSUNG, Build $BUILD"
xcodebuild build -project Haushaltsbuch.xcodeproj -scheme Haushaltsbuch \
  -configuration Release -derivedDataPath "$BAU" \
  MARKETING_VERSION="$FASSUNG" CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates -quiet

rm -rf dist
mkdir dist
cp -R "$BAU/Build/Products/Release/Haushaltsbuch.app" dist/
# Xcode signiert mit dem Personal Team, siehe project.yml. Nicht mehr ad hoc
# darüber signieren, ohne Team ID liefert das System keine Aktion für
# Kurzbefehle und Spotlight aus (2026-09-27).
if ! codesign -dv dist/Haushaltsbuch.app 2>&1 | grep -q "^TeamIdentifier=[A-Z0-9]"; then
  echo "Die App trägt keine Team ID. Ist die Apple ID in Xcode unter Accounts angemeldet?" >&2
  exit 1
fi
# ditto packt wie der Finder, mit Rechten und Symbol und ohne ._ Dateien
ditto -c -k --keepParent dist/Haushaltsbuch.app dist/Haushaltsbuch.zip

echo
echo "Fertig, dist/Haushaltsbuch.app und Haushaltsbuch.zip, Fassung $FASSUNG, Build $BUILD"
echo "Zum Benutzen nach /Applications ziehen und Haushalt.app, Fassung 1.2, löschen."
