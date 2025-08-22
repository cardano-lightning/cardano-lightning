#!/usr/bin/env bash

while true; do
    inotifywait -e modify stages-impl.puml
    echo "Detected changes in stages-impl.puml..."
    plantuml -tsvg stages-impl.puml
    echo "Generating SVG file..."
    firefox stages-impl.svg &
done

