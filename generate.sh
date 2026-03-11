#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --name \"My App\" --slug my-app"
  echo ""
  echo "Creates a new HA-Laravel addon instance by copying the template"
  echo "directory and stamping the slug/name into config.json."
  exit 1
}

NAME=""
SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)  NAME="$2"; shift 2 ;;
    --slug)  SLUG="$2"; shift 2 ;;
    *)       usage ;;
  esac
done

if [[ -z "$NAME" || -z "$SLUG" ]]; then
  usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/template"
TARGET_DIR="$SCRIPT_DIR/$SLUG"

if [[ -d "$TARGET_DIR" ]]; then
  echo "Error: directory '$SLUG' already exists."
  exit 1
fi

if [[ ! -d "$TEMPLATE_DIR" ]]; then
  echo "Error: template/ directory not found."
  exit 1
fi

cp -r "$TEMPLATE_DIR" "$TARGET_DIR"

# Stamp placeholders in the config template
sed "s/%%SLUG%%/$SLUG/g; s/%%NAME%%/$NAME/g" \
  "$TARGET_DIR/config.json.tpl" > "$TARGET_DIR/config.json"

rm "$TARGET_DIR/config.json.tpl"

# Stamp the addon name into Dockerfile labels
sed -i "s/%%NAME%%/$NAME/g" "$TARGET_DIR/Dockerfile"

echo "Created addon '$NAME' at ./$SLUG/"
echo "Next steps:"
echo "  1. Add this repository to Home Assistant"
echo "  2. Install the '$NAME' addon"
echo "  3. Configure git_url and other options in the addon settings"
