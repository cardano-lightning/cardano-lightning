#!/usr/bin/env bash

while true; do
    inotifywait -e modify components-3.0.puml
    echo "Detected changes in components-3.0.puml..."
    plantuml -tsvg components-3.0.puml
    echo "Generating SVG file..."
    firefox components-3.0.svg &
done

