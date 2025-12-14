#!/bin/bash

set -ex

swift build -c release
BUILD_DIR=$(swift build -c release --show-bin-path)
DIST_DIR=vscode-hylo/dist
rm -rf $DIST_DIR
mkdir -p $DIST_DIR
# cp -Rp hylo-new/StandardLibrary/Sources $DIST_DIR/hylo-stdlib
mkdir -p $DIST_DIR/bin/
cp -fv $BUILD_DIR/hylo-language-server $DIST_DIR/bin/
cp -a $BUILD_DIR/Hylo_StandardLibrary.resources $DIST_DIR/bin/Hylo_StandardLibrary.resources
PUBLISHED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "{\"name\": \"dev\", \"id\": 0, \"published_at\": \"$PUBLISHED_AT\"}" > $DIST_DIR/manifest.json
cd vscode-hylo
npm install
npm run package:vsix
VERSION=$(cat package.json | jq -r ".version")
code --install-extension hylo-vscode-$VERSION.vsix
