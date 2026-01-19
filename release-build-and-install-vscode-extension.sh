#!/bin/bash

set -ex

swift build -c release
BUILD_DIR=$(swift build -c release --show-bin-path)
DIST_DIR=vscode-hylo/dist
rm -rf $DIST_DIR
mkdir -p $DIST_DIR
cd vscode-hylo
npm install
npm run package:vsix
VERSION=$(cat package.json | jq -r ".version")
code --install-extension hylo-vscode-$VERSION.vsix
