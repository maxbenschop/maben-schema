#!/bin/sh
# Checks the Astah export against Astah itself: exports diagrams, has your copy of Astah Professional open each
# file (through its API, no window), and compares what Astah found with what was in the diagram, line by line.
# Astah then validates each file, changes it and saves it again, and draws it as a PNG to look at.
#
#   Resources/astah/check.sh                 the sample in each notation and level of detail, and a diagram
#                                            with one of everything (subtypes, indexes, kinds, domains, counts)
#   Resources/astah/check.sh my.mschema …    your own diagrams (or .sql files) as well
#
# Needs Astah Professional (the 20-day trial will do). It is found in /Applications, or set ASTAH_APP to the
# "astah professional.app" to use. Nothing here runs in CI: Astah isn't there.
set -e
cd "$(dirname "$0")/../.."
APP=${ASTAH_APP:-"/Applications/astah professional/astah professional.app"}
[ -d "$APP" ] || APP="/Applications/astah professional.app"
[ -d "$APP/Contents/Java" ] || { echo "Astah Professional not found. Set ASTAH_APP=/path/to/astah professional.app"; exit 2; }
JAVA="$APP/Contents/runtime/Contents/Home/bin"
CP="$APP/Contents/Java/astah-api.jar:$APP/Contents/Java/astah-pro.jar:$APP/Contents/Java/lib/*:$APP/Contents/Java/lib/batik/*:$APP/Contents/Java/lib/gvml/*"
OUT=${ASTAH_OUT:-$(mktemp -d)}
mkdir -p "$OUT/classes"
rm -f "$OUT/classes/AstahCheck.class"
"$JAVA/javac" -nowarn -d "$OUT/classes" -cp "$APP/Contents/Java/astah-api.jar" Resources/astah/AstahCheck.java 2>&1 | grep -v "^Note:" || true
[ -f "$OUT/classes/AstahCheck.class" ] || { echo "AstahCheck.java didn't compile against this Astah."; exit 2; }
swift build --product Schema >/dev/null
BIN="$(swift build --show-bin-path)/Schema"
quiet() { grep -v -E "^[0-9]{4}-[0-9]{2}-[0-9]{2} .*<(INFO|WARN)>" || true; }
failed=0

# check <name> <flags for Schema…>
check() {
    name=$1; shift
    "$BIN" "$@" --export="$OUT/$name.asta" >/dev/null
    "$BIN" "$@" --export="$OUT/$name.astalist" >/dev/null
    "$JAVA/java" -Djava.awt.headless=true -cp "$OUT/classes:$CP" AstahCheck "$OUT/$name.asta" "$OUT/$name.astah.txt" "$OUT/$name.resaved.asta" 2>&1 | quiet
    if diff "$OUT/$name.astalist" "$OUT/$name.astah.txt" >"$OUT/$name.diff"; then
        echo "ok    $name: Astah shows the same $(grep -c "^ENTITY" "$OUT/$name.astalist") entities, $(grep -c "^ATTR" "$OUT/$name.astalist") attributes and $(grep -c "^REL" "$OUT/$name.astalist") relationships"
    else
        echo "FAIL  $name: Astah shows something else (< the diagram, > Astah):"; head -20 "$OUT/$name.diff"; failed=1
    fi
    "$JAVA/java" -Djava.awt.headless=true -cp "$CP" com.change_vision.jude.cmdline.JudeCommandRunner -image er -f "$OUT/$name.asta" -t png -o "$OUT/pictures" 2>&1 | quiet
}

check sample
check sample-idef1x --notation=idef1x
check sample-physical --names=physical
check sample-keys --detail=keys
check sample-names --detail=namesOnly
check features --features
check features-idef1x --features --notation=idef1x
check empty --empty
n=0
for file in "$@"; do
    n=$((n + 1))
    case "$file" in
        *.sql) check "file-$n" --from-sql="$file" ;;
        *) check "file-$n" --open="$file" ;;
    esac
done
echo "Files and pictures are in $OUT"
exit $failed
