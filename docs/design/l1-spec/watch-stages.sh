#!/usr/bin/env bash

while true; do
    inotifywait -e modify stages.puml
    echo "Detected changes in stages.puml..."
    plantuml -tsvg stages.puml
    echo "Generating SVG file..."
    # firefox stages.svg &
done

