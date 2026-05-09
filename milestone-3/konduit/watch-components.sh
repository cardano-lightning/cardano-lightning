#!/usr/bin/env bash

while true; do
    inotifywait -e modify components.puml
    echo "Detected changes in components.puml..."
    plantuml -tsvg components.puml
    echo "Generating SVG file..."
    firefox components.svg &
done

