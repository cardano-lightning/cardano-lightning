#!/usr/bin/env bash

while true; do
    inotifywait -e modify components-2.0.puml
    echo "Detected changes in components-2.0.puml..."
    plantuml -tsvg components-2.0.puml
    echo "Generating SVG file..."
    firefox components-2.0.svg &
done

