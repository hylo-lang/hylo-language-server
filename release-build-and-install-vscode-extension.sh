#!/bin/bash

set -ex

DIST_DIR=vscode-hylo/dist
rm -rf $DIST_DIR
cd vscode-hylo
npm install
npm run package:vsix
VERSION=$(cat package.json | jq -r ".version")
code --install-extension hylo-vscode-$VERSION.vsix
