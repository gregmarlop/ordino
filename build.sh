#!/bin/bash

echo "🔨 Building Ordino..."

mkdir -p Ordino.app/Contents/MacOS
cp Info.plist Ordino.app/Contents/
swiftc -o Ordino.app/Contents/MacOS/Ordino -framework Cocoa ordino.swift

if [ $? -eq 0 ]; then
    echo "✅ Done!"
    echo ""
    echo "To run: open Ordino.app"
    echo ""
    echo "To install: cp -r Ordino.app /Applications/"
else
    echo "❌ Build failed"
fi
